//! File and block-device backend: vectored IO through the queue
//! thread's io_uring, O_DIRECT on a backing store whose alignment our
//! ring payloads meet, buffered (`RWF_DONTCACHE`) otherwise.
//!
//! One implementation serves both regular files and block devices
//! (geometry probing differs; the IO path is identical), mirroring how
//! little actually differs in userspace — unlike kernel nvmet's
//! bio-vs-kiocb split.
//!
//! A single fd is opened `O_DIRECT`; whether O_DIRECT is *used* is decided
//! once, at open. The decision depends on whether the zero-copy recv ring is
//! enabled (see [`FileBackend::open`]'s `ring_enabled`):
//!
//! - **Ring off (the default).** The backend only ever sees page-aligned pool
//!   buffers, which satisfy any DIO alignment a store can demand, so O_DIRECT
//!   is kept whenever the kernel opened the `O_DIRECT` fd — no `statx` gate.
//! - **Ring on.** Write payloads can live in ring memory at only **dword/PDO
//!   (4-byte) alignment**, not page alignment, so O_DIRECT is usable only when
//!   the store's `statx STATX_DIOALIGN` reports a memory alignment no coarser
//!   than 4 bytes (`stx_dio_mem_align <= 4`) and an offset alignment no coarser
//!   than our logical block. NVMe-class block devices (and filesystems on them)
//!   report a 4-byte DIO memory alignment, so the dword-aligned ring payloads
//!   DMA straight from ring memory.
//!
//! When O_DIRECT is rejected — a too-coarse DIO alignment under the ring, a
//! store where the kernel can't report DIOALIGN (e.g. tmpfs), or a store that
//! refuses `O_DIRECT` at open — the backend falls back to a buffered fd with
//! `RWF_DONTCACHE` (self-correcting to plain buffered on the first
//! `EOPNOTSUPP`/`EINVAL`, for pre-6.14 kernels and filesystems without
//! DONTCACHE).

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use ioutgt_core::pool::{MAX_SEGS, Seg};
use ioutgt_core::{Backend, BackendError, LbaRange, Topology};
use ioutgt_uring::ops;

/// Backing kind, decided by `fstat` at open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Regular,
    Block,
}

const EMPTY_IOVEC: libc::iovec = libc::iovec {
    iov_base: std::ptr::null_mut(),
    iov_len: 0,
};

/// File/bdev backend issuing vectored IO; O_DIRECT or buffered+DONTCACHE,
/// decided at open from `statx STATX_DIOALIGN`. See module docs.
pub struct FileBackend {
    /// O_DIRECT when the store's DIO alignment fits our 4-byte ring
    /// payloads, else a plain buffered fd.
    fd: OwnedFd,
    kind: Kind,
    block_shift: u8,
    nr_blocks: u64,
    /// O_DIRECT is in effect (false ⇒ the store's DIO alignment was too
    /// coarse or unavailable, IO is buffered with `RWF_DONTCACHE`).
    direct: bool,
    /// `RWF_DONTCACHE` usable on the buffered fd. Optimistically true;
    /// self-corrects to false on the first `EOPNOTSUPP`/`EINVAL`.
    dontcache: AtomicBool,
    /// Block-device IO topology (default for regular files).
    topology: Topology,
}

/// Query DIO alignment via `statx(STATX_DIOALIGN)`. Returns
/// `(stx_dio_mem_align, stx_dio_offset_align)`, or `(0, 0)` when the kernel
/// can't report it (pre-6.1, or a backing store without DIO support).
fn query_dioalign(fd: RawFd) -> (u32, u32) {
    // SAFETY: statx writes the struct on success; zeroed is a valid init.
    let mut stx: libc::statx = unsafe { std::mem::zeroed() };
    // SAFETY: empty path + AT_EMPTY_PATH targets `fd`; out-pointer valid.
    let r = unsafe {
        libc::statx(
            fd,
            c"".as_ptr(),
            libc::AT_EMPTY_PATH,
            libc::STATX_DIOALIGN,
            &raw mut stx,
        )
    };
    if r < 0 || stx.stx_mask & libc::STATX_DIOALIGN == 0 {
        return (0, 0);
    }
    (stx.stx_dio_mem_align, stx.stx_dio_offset_align)
}

/// A block device's IO topology: the `BLKPBSZGET`/`BLKIOMIN`/`BLKIOOPT`
/// ioctls, plus `queue/discard_granularity` from sysfs (it has no ioctl),
/// reached through the device number. A partition's sysfs node has no
/// `queue/` of its own — the ioctls answer for it, but the granularity
/// lives one level up, in the disk's — so `../queue/` is the fallback,
/// as `bdev_discard_granularity()` reads the disk's queue for a partition
/// too. Best effort: anything unreadable stays 0 (= unknown) and the
/// corresponding Identify NS hint is omitted.
fn block_topology(fd: RawFd, rdev: libc::dev_t) -> Topology {
    // _IO(0x12, 123) / _IO(0x12, 120) / _IO(0x12, 121)
    const BLKPBSZGET: libc::c_ulong = 0x127B;
    const BLKIOMIN: libc::c_ulong = 0x1278;
    const BLKIOOPT: libc::c_ulong = 0x1279;
    let ioctl_u32 = |req: libc::c_ulong| -> u32 {
        let mut v: libc::c_uint = 0;
        // SAFETY: valid fd; each of these ioctls writes an unsigned int.
        if unsafe { libc::ioctl(fd, req, &raw mut v) } < 0 {
            return 0;
        }
        v
    };
    let major = libc::major(rdev);
    let minor = libc::minor(rdev);
    let node = format!("/sys/dev/block/{major}:{minor}");
    let discard_granularity = [
        format!("{node}/queue/discard_granularity"),
        format!("{node}/../queue/discard_granularity"),
    ]
    .iter()
    .find_map(|path| std::fs::read_to_string(path).ok())
    .and_then(|s| s.trim().parse::<u32>().ok())
    .unwrap_or(0);
    Topology {
        physical_block: ioctl_u32(BLKPBSZGET),
        io_min: ioctl_u32(BLKIOMIN),
        io_opt: ioctl_u32(BLKIOOPT),
        discard_granularity,
    }
}

/// LBA size (as a shift) for a store whose IO unit is `align` bytes
/// (0 = unreported): the smallest power of two ≥ `align`, floored at 512 B.
/// A block device's logical sector is taken as is (nvmet:
/// `blksize_bits(bdev_logical_block_size())`, uncapped — LBS drives have
/// 8–64 KiB sectors); a file's alignment is capped at 4 KiB (nvmet:
/// `min(i_blkbits, 12)`).
fn block_shift_for(kind: Kind, align: u32) -> u8 {
    let shift = align.max(512).next_power_of_two().trailing_zeros();
    let shift = match kind {
        Kind::Block => shift,
        Kind::Regular => shift.min(12),
    };
    #[allow(clippy::cast_possible_truncation)]
    let shift = shift as u8;
    shift
}

/// Deallocate is a hint, so two outcomes count as "honoured by doing
/// nothing", like nvmet's file path (`-EOPNOTSUPP` only) and its bdev path
/// (which never checks): `EOPNOTSUPP` — the store cannot unmap (no discard
/// support, or no `uring_cmd` on this fd/kernel) — and `EBUSY` — a
/// buffered bdev's page-cache invalidation lost a race with a host write.
/// Anything else (`EINVAL` = misaligned/empty range, `EIO`, `ENOSPC`) is a
/// real error the host must see.
fn unmap_hint_declined(errno: Option<i32>) -> bool {
    matches!(errno, Some(libc::EOPNOTSUPP | libc::EBUSY))
}

/// In the write-zeroes chain (`ZERO_RANGE` → `PUNCH_HOLE` → zero writes)
/// only a mode the store lacks moves on to the next; a real error is the
/// answer and is not retried through a slower path (nvmet issues one op
/// per kind and returns its status).
fn fallocate_mode_unsupported(errno: Option<i32>) -> bool {
    errno == Some(libc::EOPNOTSUPP)
}

/// Whether to keep the opened `O_DIRECT` fd, given the store's `statx
/// STATX_DIOALIGN` and whether the recv ring is enabled (see module docs for
/// the ring-off vs ring-on rule).
fn direct_usable(ring_enabled: bool, dio_mem: u32, dio_off: u32, block_shift: u8) -> bool {
    if !ring_enabled {
        return true;
    }
    dio_mem != 0 && dio_mem <= 4 && dio_off != 0 && u64::from(dio_off) <= (1u64 << block_shift)
}

/// Fill `iovs` from `segs`, clamping the total to `total` bytes; returns
/// the number of iovec entries used.
fn fill_iovecs(iovs: &mut [libc::iovec], segs: &[Seg], total: usize) -> usize {
    let mut remaining = total;
    let mut n = 0;
    for seg in segs {
        if remaining == 0 {
            break;
        }
        let take = remaining.min(seg.len);
        iovs[n] = libc::iovec {
            iov_base: seg.ptr.cast(),
            iov_len: take,
        };
        n += 1;
        remaining -= take;
    }
    n
}

/// Advance `iovs[idx..]` past `n` transferred bytes (short-IO resume).
fn advance_iovecs(iovs: &mut [libc::iovec], idx: &mut usize, mut n: usize) {
    while n > 0 {
        let v = &mut iovs[*idx];
        if v.iov_len <= n {
            n -= v.iov_len;
            *idx += 1;
        } else {
            // SAFETY: advancing within the current iovec's own buffer.
            v.iov_base = unsafe { v.iov_base.cast::<u8>().add(n).cast() };
            v.iov_len -= n;
            n = 0;
        }
    }
}

impl FileBackend {
    /// Open `path` (regular file or block device), probing the LBA size from
    /// the store — a block device's logical sector (`BLKSSZGET`, uncapped),
    /// a file's `statx STATX_DIOALIGN` offset alignment or, where the
    /// filesystem does not report one (btrfs), its `st_blksize`, capped at
    /// 4 KiB — floored at 512 B; see [`block_shift_for`]. Tries `O_DIRECT`,
    /// keeping it or falling back to a buffered (`RWF_DONTCACHE`) fd per the
    /// ring-gated rule in the module docs.
    pub fn open(path: &Path, ring_enabled: bool) -> io::Result<FileBackend> {
        use std::os::unix::ffi::OsStrExt;
        let cpath = std::ffi::CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"))?;
        let open_flags = |flags: libc::c_int| -> io::Result<OwnedFd> {
            // SAFETY: valid NUL-terminated path; flags are plain constants.
            let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDWR | flags) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: fresh fd, exclusively owned.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        };

        // Try O_DIRECT first; a store that refuses it outright (e.g. tmpfs)
        // gets a buffered fd. Whether a *granted* O_DIRECT fd is kept is
        // decided below, once the store's alignment is known.
        let (fd, mut direct) = match open_flags(libc::O_DIRECT) {
            Ok(fd) => (fd, true),
            Err(e) if matches!(e.raw_os_error(), Some(libc::EINVAL | libc::EOPNOTSUPP)) => {
                (open_flags(0)?, false)
            }
            Err(e) => return Err(e),
        };

        // SAFETY: stat is written by the kernel on success.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        if unsafe { libc::fstat(fd.as_raw_fd(), &raw mut stat) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let (dio_mem, dio_off) = query_dioalign(fd.as_raw_fd());
        let mut topology = Topology::default();
        let (kind, size_bytes, align) = if stat.st_mode & libc::S_IFMT == libc::S_IFBLK {
            let mut size: u64 = 0;
            // BLKGETSIZE64 = _IOR(0x12, 114, size_t)
            const BLKGETSIZE64: libc::c_ulong = 0x8008_1272;
            // SAFETY: valid fd; the ioctl writes a u64.
            if unsafe { libc::ioctl(fd.as_raw_fd(), BLKGETSIZE64, &raw mut size) } < 0 {
                return Err(io::Error::last_os_error());
            }
            // BLKSSZGET = _IO(0x12, 104): logical sector size, the unit every
            // O_DIRECT/discard/zeroout range on the device must respect.
            const BLKSSZGET: libc::c_ulong = 0x1268;
            let mut lbs: libc::c_int = 0;
            // SAFETY: valid fd; the ioctl writes an int.
            if unsafe { libc::ioctl(fd.as_raw_fd(), BLKSSZGET, &raw mut lbs) } < 0 {
                return Err(io::Error::last_os_error());
            }
            topology = block_topology(fd.as_raw_fd(), stat.st_rdev);
            (Kind::Block, size, u32::try_from(lbs).unwrap_or(0))
        } else if stat.st_mode & libc::S_IFMT == libc::S_IFREG {
            // The DIO offset alignment is the O_DIRECT unit; a filesystem
            // that does not report it (btrfs) still refuses sub-block
            // direct IO, so its block size (nvmet's i_blkbits) stands in.
            #[allow(clippy::cast_sign_loss)]
            let align = if dio_off != 0 {
                dio_off
            } else {
                u32::try_from(stat.st_blksize.max(0)).unwrap_or(0)
            };
            #[allow(clippy::cast_sign_loss)]
            (Kind::Regular, stat.st_size.max(0) as u64, align)
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "not a file or block device",
            ));
        };
        let block_shift = block_shift_for(kind, align);

        // Keep O_DIRECT only if direct_usable() (see module docs); else
        // reopen buffered.
        let fd = if direct && !direct_usable(ring_enabled, dio_mem, dio_off, block_shift) {
            drop(fd);
            direct = false;
            open_flags(0)?
        } else {
            fd
        };

        let nr_blocks = size_bytes >> block_shift;
        if nr_blocks == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "backing store too small",
            ));
        }

        Ok(FileBackend {
            fd,
            kind,
            block_shift,
            nr_blocks,
            direct,
            dontcache: AtomicBool::new(true),
            topology,
        })
    }

    /// O_DIRECT is in effect for this backend's IO (decided at open).
    pub fn is_direct(&self) -> bool {
        self.direct
    }

    fn offset(&self, slba: u64) -> u64 {
        slba << self.block_shift
    }

    /// The op target for this backend's fd: a registered fixed-file index when
    /// the reactor accepted one (skips the kernel's per-IO fd lookup), else the
    /// raw fd. Best-effort and per-thread, mirroring the fixed-buffer fallback.
    fn backend_fd(&self) -> ops::BackendFd {
        let fd = self.fd.as_raw_fd();
        match ioutgt_uring::fixed_file_index(fd) {
            Some(idx) => ops::BackendFd::Fixed(idx),
            None => ops::BackendFd::Raw(fd),
        }
    }

    /// Issue one vectored read/write on the backend fd (O_DIRECT or
    /// buffered+DONTCACHE, fixed at open), resuming across short transfers. When
    /// `buf_index` is `Some`, the iovecs point into that registered pool
    /// buffer and the op is `READV_FIXED`/`WRITEV_FIXED` — the kernel reuses
    /// the pre-pinned mapping instead of mapping the pages every IO.
    async fn rwv(
        &self,
        write: bool,
        slba: u64,
        iovs: &mut [libc::iovec],
        total: usize,
        buf_index: Option<u16>,
    ) -> Result<(), BackendError> {
        if total == 0 {
            return Ok(());
        }
        self.check_range(slba, (total as u64) >> self.block_shift)?;
        let base_off = self.offset(slba);
        let file = self.backend_fd();

        let mut done = 0usize;
        let mut idx = 0usize;
        while done < total {
            let off = base_off + done as u64;
            // Buffered IO drops the page cache via RWF_DONTCACHE (close to
            // DIO without alignment constraints); O_DIRECT needs no flag.
            // The flag self-corrects off on the first EOPNOTSUPP/EINVAL.
            let use_dc = !self.direct && self.dontcache.load(Ordering::Relaxed);
            let flags = if use_dc { libc::RWF_DONTCACHE } else { 0 };
            let ptr = iovs[idx..].as_ptr();
            #[allow(clippy::cast_possible_truncation)]
            let cnt = (iovs.len() - idx) as u32;
            // SAFETY: `iovs` and every buffer they point at outlive this
            // awaited op — `iovs` lives in the caller's frame (held across
            // the await) and the segment buffers are the caller's slot
            // memory, valid while the slot is Executing. The reactor's
            // orphan protocol holds the op entry to its terminal CQE on
            // whole-future drop, the same envelope as the other raw ops.
            // For the fixed variants the buffers additionally fall within the
            // registered arena `buf_index`, which is unregistered only after
            // the op drain at teardown.
            let res = unsafe {
                match (write, buf_index) {
                    (true, Some(bi)) => ops::writev_fixed_at_raw(file, ptr, cnt, off, bi, flags),
                    (false, Some(bi)) => ops::readv_fixed_at_raw(file, ptr, cnt, off, bi, flags),
                    (true, None) => ops::writev_at_raw(file, ptr, cnt, off, flags),
                    (false, None) => ops::readv_at_raw(file, ptr, cnt, off, flags),
                }
            };
            let op = res.map_err(|e| BackendError::Io(e.raw_os_error().unwrap_or(libc::EIO)))?;
            match op.await {
                Ok(0) => return Err(BackendError::Io(libc::EIO)),
                Ok(n) => {
                    let n = n as usize;
                    advance_iovecs(iovs, &mut idx, n);
                    done += n;
                }
                Err(e) => {
                    let code = e.raw_os_error().unwrap_or(libc::EIO);
                    // RWF_DONTCACHE unsupported (pre-6.14 or this fs): drop
                    // the flag for good and retry the same offset buffered.
                    if use_dc && matches!(code, libc::EOPNOTSUPP | libc::EINVAL) {
                        self.dontcache.store(false, Ordering::Relaxed);
                        continue;
                    }
                    return Err(map_errno(code));
                }
            }
        }
        Ok(())
    }
}

fn map_errno(err: i32) -> BackendError {
    match err {
        libc::ENOSPC => BackendError::NoSpace,
        libc::EOPNOTSUPP | libc::EINVAL => BackendError::Unsupported,
        other => BackendError::Io(other),
    }
}

impl Backend for FileBackend {
    fn block_shift(&self) -> u8 {
        self.block_shift
    }

    fn nr_blocks(&self) -> u64 {
        self.nr_blocks
    }

    fn topology(&self) -> Topology {
        self.topology
    }

    async fn read(&self, slba: u64, buf: &mut [u8]) -> Result<(), BackendError> {
        let mut iovs = [libc::iovec {
            iov_base: buf.as_mut_ptr().cast(),
            iov_len: buf.len(),
        }];
        self.rwv(false, slba, &mut iovs, buf.len(), None).await
    }

    async fn write(&self, slba: u64, buf: &[u8]) -> Result<(), BackendError> {
        let mut iovs = [libc::iovec {
            iov_base: buf.as_ptr().cast_mut().cast(),
            iov_len: buf.len(),
        }];
        self.rwv(true, slba, &mut iovs, buf.len(), None).await
    }

    async fn read_segs(
        &self,
        slba: u64,
        segs: &[Seg],
        total: usize,
        buf_index: Option<u16>,
    ) -> Result<(), BackendError> {
        let mut iovs = [EMPTY_IOVEC; MAX_SEGS];
        let n = fill_iovecs(&mut iovs, segs, total);
        self.rwv(false, slba, &mut iovs[..n], total, buf_index)
            .await
    }

    async fn write_segs(
        &self,
        slba: u64,
        segs: &[Seg],
        total: usize,
        buf_index: Option<u16>,
    ) -> Result<(), BackendError> {
        let mut iovs = [EMPTY_IOVEC; MAX_SEGS];
        let n = fill_iovecs(&mut iovs, segs, total);
        self.rwv(true, slba, &mut iovs[..n], total, buf_index).await
    }

    async fn flush(&self) -> Result<(), BackendError> {
        ops::fsync(self.backend_fd(), true)
            .map_err(|e| BackendError::Io(e.raw_os_error().unwrap_or(libc::EIO)))?
            .await
            .map(|_| ())
            .map_err(|e| map_errno(e.raw_os_error().unwrap_or(libc::EIO)))
    }

    async fn discard(&self, ranges: &[LbaRange]) -> Result<(), BackendError> {
        // Deallocate is a hint: a store that cannot unmap (no discard
        // support, a kernel without BLOCK_URING_CMD_DISCARD) succeeds
        // without touching the data, as nvmet's bdev path does for IDR/IDW.
        // A store that *can* unmap and fails mid-way is a real IO error.
        for range in ranges {
            if self.check_range(range.slba, u64::from(range.nlb)).is_err() {
                return Err(BackendError::OutOfRange);
            }
            let off = self.offset(range.slba);
            let len = u64::from(range.nlb) << self.block_shift;
            let op = match self.kind {
                Kind::Regular => {
                    let mode = libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE;
                    ops::fallocate(self.backend_fd(), mode, off, len)
                }
                Kind::Block => ops::block_discard(self.backend_fd(), off, len),
            }
            .map_err(|e| BackendError::Io(e.raw_os_error().unwrap_or(libc::EIO)))?;
            match op.await {
                Ok(_) => {}
                Err(e) if unmap_hint_declined(e.raw_os_error()) => {}
                Err(e) => return Err(map_errno(e.raw_os_error().unwrap_or(libc::EIO))),
            }
        }
        Ok(())
    }

    async fn write_zeroes(&self, range: LbaRange) -> Result<(), BackendError> {
        self.check_range(range.slba, u64::from(range.nlb))?;
        let len = u64::from(range.nlb) << self.block_shift;
        // On a block device `blkdev_fallocate` turns ZERO_RANGE into
        // `blkdev_issue_zeroout` — device Write Zeroes with the kernel's own
        // zero-fill fallback, the bios nvmet's write_zeroes submits — so it
        // is the one op; a failure there is the device's answer. A regular
        // file gets PUNCH_HOLE as a second mode (tmpfs lacks ZERO_RANGE) and
        // then plain zero writes; only EOPNOTSUPP advances the chain.
        let modes: &[libc::c_int] = match self.kind {
            Kind::Block => &[libc::FALLOC_FL_ZERO_RANGE | libc::FALLOC_FL_KEEP_SIZE],
            Kind::Regular => &[
                libc::FALLOC_FL_ZERO_RANGE,
                libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE,
            ],
        };
        for &mode in modes {
            let op = ops::fallocate(self.backend_fd(), mode, self.offset(range.slba), len)
                .map_err(|e| BackendError::Io(e.raw_os_error().unwrap_or(libc::EIO)))?;
            match op.await {
                Ok(_) => return Ok(()),
                Err(e) if fallocate_mode_unsupported(e.raw_os_error()) => {}
                Err(e) => return Err(map_errno(e.raw_os_error().unwrap_or(libc::EIO))),
            }
        }
        // Every mode unsupported: write zero chunks through the fd.
        let chunk = ioutgt_core::buf::AlignedBuf::zeroed(64 * 1024);
        let mut remaining = len;
        let mut off = self.offset(range.slba);
        while remaining > 0 {
            let want = u32::try_from(remaining.min(chunk.len() as u64)).expect("chunk-bounded");
            // SAFETY: chunk is alive across the await; read-only for the
            // kernel.
            let n = unsafe { ops::write_at_raw(self.backend_fd(), chunk.as_ptr(), want, off) }
                .map_err(|e| BackendError::Io(e.raw_os_error().unwrap_or(libc::EIO)))?
                .await
                .map_err(|e| map_errno(e.raw_os_error().unwrap_or(libc::EIO)))?;
            if n == 0 {
                return Err(BackendError::Io(libc::EIO));
            }
            remaining -= u64::from(n);
            off += u64::from(n);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{block_shift_for, direct_usable, fallocate_mode_unsupported, unmap_hint_declined};

    #[test]
    fn block_shift_follows_the_store_alignment() {
        // The advertised LBA must be a multiple of the store's IO unit: a
        // block device's logical sector, uncapped (nvmet: blksize_bits of
        // bdev_logical_block_size); a file's alignment capped at 4 KiB
        // (nvmet: min(i_blkbits, 12)). Floored at 512 B for both.
        use super::Kind::{Block, Regular};
        assert_eq!(block_shift_for(Regular, 0), 9, "unreported -> 512");
        assert_eq!(block_shift_for(Regular, 1), 9, "byte-aligned store -> 512");
        assert_eq!(block_shift_for(Regular, 256), 9, "sub-sector -> 512");
        assert_eq!(block_shift_for(Regular, 512), 9);
        assert_eq!(block_shift_for(Regular, 1024), 10);
        assert_eq!(block_shift_for(Regular, 4096), 12, "4K fs block");
        assert_eq!(block_shift_for(Regular, 8192), 12, "files capped at 4K");
        assert_eq!(
            block_shift_for(Regular, 3072),
            12,
            "non-power-of-two rounds up"
        );
        assert_eq!(block_shift_for(Block, 512), 9, "512e bdev");
        assert_eq!(block_shift_for(Block, 4096), 12, "4Kn bdev");
        assert_eq!(block_shift_for(Block, 8192), 13, "LBS bdev: not capped");
        assert_eq!(block_shift_for(Block, 65536), 16, "BLK_MAX_BLOCK_SIZE bdev");
    }

    #[test]
    fn unmap_errors_are_classified_like_nvmet() {
        // Deallocate is a hint. Only "the store cannot unmap" (EOPNOTSUPP:
        // no discard support, no uring_cmd on this fd/kernel) and "the store
        // declined right now" (EBUSY: bdev page-cache invalidation lost a
        // race with a host write) are swallowed. EINVAL is a misaligned or
        // empty range — a geometry bug that must surface, never a no-op.
        assert!(unmap_hint_declined(Some(libc::EOPNOTSUPP)));
        assert!(unmap_hint_declined(Some(libc::EBUSY)));
        assert!(!unmap_hint_declined(Some(libc::EINVAL)));
        assert!(!unmap_hint_declined(Some(libc::EIO)));
        assert!(!unmap_hint_declined(Some(libc::ENOSPC)));
        assert!(!unmap_hint_declined(None));
    }

    #[test]
    fn only_unsupported_mode_advances_the_zeroing_chain() {
        // ZERO_RANGE -> PUNCH_HOLE -> zero writes: a mode the store lacks
        // (tmpfs has no ZERO_RANGE) moves on; a real error (EIO, ENOSPC,
        // EINVAL) is the answer and must not be retried through a slower path.
        assert!(fallocate_mode_unsupported(Some(libc::EOPNOTSUPP)));
        assert!(!fallocate_mode_unsupported(Some(libc::EIO)));
        assert!(!fallocate_mode_unsupported(Some(libc::ENOSPC)));
        assert!(!fallocate_mode_unsupported(Some(libc::EINVAL)));
        assert!(!fallocate_mode_unsupported(None));
    }

    #[test]
    fn ring_off_keeps_direct_regardless_of_dio_alignment() {
        // The default (ring off) path only writes from page-aligned pool
        // buffers, so O_DIRECT is kept whatever the store reports — including a
        // `dio_mem > 4` device (the case the statx gate used to pessimize into
        // buffered+RWF_DONTCACHE) and a store that can't report DIOALIGN (0, 0).
        for (dio_mem, dio_off) in [(512u32, 512u32), (4096, 4096), (8, 8), (0, 0)] {
            assert!(
                direct_usable(false, dio_mem, dio_off, 9),
                "ring off must keep O_DIRECT (dio_mem={dio_mem}, dio_off={dio_off})"
            );
        }
    }

    #[test]
    fn ring_on_gates_direct_on_dword_alignment() {
        // Ring on: payloads may be 4-byte-aligned ring memory. Keep O_DIRECT
        // only for NVMe-class stores (mem align <= 4, offset align <= block).
        assert!(
            direct_usable(true, 4, 512, 9),
            "NVMe-class: 4-byte mem, 512 off"
        );
        assert!(direct_usable(true, 1, 1, 9), "byte-aligned store");
        assert!(
            !direct_usable(true, 512, 512, 9),
            "512-byte mem align too coarse"
        );
        assert!(
            !direct_usable(true, 4096, 4096, 12),
            "4K mem align too coarse"
        );
        assert!(
            !direct_usable(true, 0, 0, 9),
            "unreportable DIOALIGN -> buffered"
        );
        // Offset alignment coarser than the logical block is unusable.
        assert!(
            !direct_usable(true, 4, 8192, 9),
            "8K offset align > 512 block"
        );
        assert!(
            direct_usable(true, 4, 4096, 12),
            "4K offset align == 4K block ok"
        );
    }
}
