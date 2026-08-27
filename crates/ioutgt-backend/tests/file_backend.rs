//! FileBackend unit tests: O_DIRECT roundtrip, write-zeroes, discard.
//!
//! Backed by a file under `target/` (a real filesystem — /tmp is tmpfs
//! here and refuses O_DIRECT, which would exercise only the buffered
//! fallback).

use ioutgt_backend::FileBackend;
use ioutgt_core::buf::AlignedBuf;
use ioutgt_core::pool::Seg;
use ioutgt_core::{Backend, BackendError, LbaRange};
use ioutgt_uring::{QueueRuntime, RingConfig};

fn scratch_file(name: &str, size: u64) -> std::path::PathBuf {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    std::fs::create_dir_all(dir).unwrap();
    let path = dir.join(name);
    let file = std::fs::File::create(&path).unwrap();
    file.set_len(size).unwrap();
    path
}

#[test]
fn direct_write_read_roundtrip() {
    let path = scratch_file("fb-roundtrip", 8 << 20);
    let rt = QueueRuntime::new(RingConfig::default()).unwrap();
    let be = FileBackend::open(&path, false).unwrap();
    eprintln!("O_DIRECT active: {}", be.is_direct());
    // Geometry is probed from the store (512 B..4 KiB for a file), so every
    // LBA below is expressed through the shift rather than assumed 512 B.
    let shift = be.block_shift();
    let bs = 1u64 << shift;
    assert_eq!(be.nr_blocks(), (8u64 << 20) >> shift);
    // 128 KiB region starting 32 KiB in; zero the first 8 KiB of it.
    let base = (32 << 10) / bs;
    #[allow(clippy::cast_possible_truncation)]
    let eight_k = (8192 / bs) as u32;

    rt.block_on(async move {
        let mut buf = AlignedBuf::zeroed(128 * 1024);
        #[allow(clippy::cast_possible_truncation)]
        buf.iter_mut()
            .enumerate()
            .for_each(|(i, b)| *b = (i % 251) as u8);
        let pattern = buf.to_vec();

        be.write(base, &buf[..128 * 1024]).await.unwrap();
        be.flush().await.unwrap();

        let mut out = AlignedBuf::zeroed(128 * 1024);
        be.read(base, &mut out[..128 * 1024]).await.unwrap();
        assert_eq!(&out[..], &pattern[..], "128K roundtrip");

        // Write-zeroes the first 8K of the range and re-check.
        be.write_zeroes(LbaRange {
            slba: base,
            nlb: eight_k,
        })
        .await
        .unwrap();
        be.read(base, &mut out[..128 * 1024]).await.unwrap();
        assert!(out[..8192].iter().all(|&b| b == 0), "zeroed range");
        assert_eq!(&out[8192..], &pattern[8192..], "rest untouched");

        // Discard is a hint: must succeed; reads stay readable.
        be.discard(&[LbaRange {
            slba: base,
            nlb: eight_k * 16,
        }])
        .await
        .unwrap();
        be.read(base, &mut out[..4096]).await.unwrap();

        // Out-of-range rejected.
        #[allow(clippy::cast_possible_truncation)]
        let one = bs as usize;
        let err = be.read(be.nr_blocks(), &mut out[..one]).await.unwrap_err();
        assert_eq!(err, BackendError::OutOfRange);
    });
}

#[test]
fn scattered_write_matches_contiguous() {
    // A two-segment vectored write must land byte-identically to one
    // contiguous write of the concatenation.
    let path = scratch_file("fb-scatter", 8 << 20);
    let rt = QueueRuntime::new(RingConfig::default()).unwrap();
    let be = FileBackend::open(&path, false).unwrap(); // any probed geometry: 12288 B is a multiple of 512 B..4 KiB

    rt.block_on(async move {
        // Two separate page-aligned buffers (non-adjacent in memory).
        let mut a = AlignedBuf::zeroed(8192);
        let mut b = AlignedBuf::zeroed(4096);
        a.iter_mut().for_each(|x| *x = 0xAB);
        b.iter_mut().for_each(|x| *x = 0xCD);
        let segs = [
            Seg {
                ptr: a.as_ptr().cast_mut(),
                len: 8192,
            },
            Seg {
                ptr: b.as_ptr().cast_mut(),
                len: 4096,
            },
        ];
        be.write_segs(0, &segs, 12288, None).await.unwrap();
        be.flush().await.unwrap();

        // Read it back vectored into fresh buffers and check the seam.
        let r = AlignedBuf::zeroed(12288);
        let rsegs = [Seg {
            ptr: r.as_ptr().cast_mut(),
            len: 12288,
        }];
        be.read_segs(0, &rsegs, 12288, None).await.unwrap();
        assert!(r[..8192].iter().all(|&x| x == 0xAB), "first segment");
        assert!(r[8192..].iter().all(|&x| x == 0xCD), "second segment");
    });
}

#[test]
fn temp_dir_roundtrip_either_path() {
    // temp_dir may be tmpfs (no O_DIRECT → buffered/DONTCACHE path) or a
    // real fs (O_DIRECT path); the backend must open and round-trip on
    // whichever it is.
    let dir = std::env::temp_dir().join(format!("ioutgt-fb-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("img");
    std::fs::File::create(&path)
        .unwrap()
        .set_len(1 << 20)
        .unwrap();

    let rt = QueueRuntime::new(RingConfig::default()).unwrap();
    let be = FileBackend::open(&path, false).unwrap();
    eprintln!("temp_dir O_DIRECT active: {}", be.is_direct());
    rt.block_on(async move {
        let mut buf = AlignedBuf::zeroed(4096);
        buf.iter_mut().for_each(|x| *x = 0x5A);
        let pattern = buf.to_vec();
        // 4 KiB at byte 32 KiB, whatever LBA size the store yielded.
        let lba = (32u64 << 10) >> be.block_shift();
        be.write(lba, &buf[..4096]).await.unwrap();
        let mut out = AlignedBuf::zeroed(4096);
        be.read(lba, &mut out[..4096]).await.unwrap();
        assert_eq!(&out[..], &pattern[..]);
    });
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn ring_off_keeps_direct_on_real_fs() {
    // The scratch file lives under target/ (a real filesystem per this
    // module's docs), which supports O_DIRECT. With the recv ring OFF (the
    // default), O_DIRECT must be kept even though such a store typically
    // reports a `dio_mem` of 512 (> 4) — the gate the ring needs must not
    // pessimize the default page-aligned-buffer path into buffered IO.
    let path = scratch_file("fb-ring-off-direct", 8 << 20);
    let be_off = FileBackend::open(&path, false).unwrap();
    assert!(
        be_off.is_direct(),
        "ring off on a real fs must keep O_DIRECT"
    );

    // Ring on is never *more* permissive than ring off: if it kept O_DIRECT,
    // ring off must have too.
    let be_on = FileBackend::open(&path, true).unwrap();
    assert!(
        be_off.is_direct() || !be_on.is_direct(),
        "ring off must be at least as direct as ring on"
    );
}

#[test]
fn open_rejects_missing_and_tiny() {
    assert!(FileBackend::open(std::path::Path::new("/nonexistent/x"), false).is_err());
    let path = scratch_file("fb-tiny", 256); // < one block
    assert!(FileBackend::open(&path, false).is_err());
}

#[test]
fn advertised_block_is_dio_aligned() {
    // The LBA size a namespace advertises is probed from the store, not
    // assumed: whatever `statx STATX_DIOALIGN` reports as the offset
    // alignment, one block must be a multiple of it — otherwise a host
    // issuing legal single-LBA O_DIRECT IO gets EINVAL from the kernel.
    let path = scratch_file("fb-probe", 8 << 20);
    let be = FileBackend::open(&path, false).unwrap();
    let shift = be.block_shift();
    assert!(
        (9..=12).contains(&shift),
        "block shift {shift} outside 512B..4K"
    );

    let file = std::fs::File::open(&path).unwrap();
    // SAFETY: statx writes the struct on success; zeroed is a valid init.
    let mut stx: libc::statx = unsafe { std::mem::zeroed() };
    // SAFETY: empty path + AT_EMPTY_PATH targets the fd; out-pointer valid.
    let r = unsafe {
        libc::statx(
            std::os::fd::AsRawFd::as_raw_fd(&file),
            c"".as_ptr(),
            libc::AT_EMPTY_PATH,
            libc::STATX_DIOALIGN,
            &raw mut stx,
        )
    };
    if r == 0 && stx.stx_mask & libc::STATX_DIOALIGN != 0 && stx.stx_dio_offset_align != 0 {
        let align = u64::from(stx.stx_dio_offset_align);
        assert_eq!(
            (1u64 << shift) % align,
            0,
            "block {} not a multiple of DIO offset alignment {align}",
            1u64 << shift
        );
    } else {
        // No DIOALIGN (btrfs): the filesystem block size stands in, as
        // nvmet's i_blkbits does — 512 B..4 KiB.
        let blk = u64::from(stx.stx_blksize)
            .clamp(512, 4096)
            .next_power_of_two();
        assert_eq!(
            1u64 << shift,
            blk,
            "unreported alignment must follow st_blksize"
        );
    }
    assert_eq!(be.nr_blocks(), (8u64 << 20) >> shift);
}
