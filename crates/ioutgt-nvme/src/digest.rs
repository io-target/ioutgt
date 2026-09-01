//! NVMe/TCP header and data digests: CRC32C (Castagnoli), little-endian
//! on the wire, computed incrementally for streamed payloads.
//!
//! DDGST is the only place the target touches every payload byte, so the
//! digest is backed by `crc-fast`, which folds with pclmulqdq/vpclmulqdq
//! where the `crc32c` crate drives the scalar crc32 instruction: ~1.6x at
//! 4 KiB against a `+sse4.2` crc32c (187 -> 116 ns), ~1.9x against one built
//! at the plain x86-64 baseline, where crc32c cannot inline its own
//! `#[target_feature]` leaves and pays a call/ret per 8 bytes. Folding still
//! loses at 512-byte windows and is a wash at 1 KiB; recv windows are far
//! above both. Header digests are 24-72 bytes and never mattered either way.
//!
//! Which kernel folds is a runtime choice ([`CrcKernel`], `--crc-kernel`).
//! `crc-fast` special-cases CRC-32/ISCSI to a "fusion" kernel alongside its
//! generic folding calculator; both dispatch over the same tiers at runtime,
//! and which is faster is a property of the microarchitecture rather than of
//! any one feature bit. Measured:
//!
//!   - EPYC 9124 (Zen 4, `avx512vl`): fusion wins at every size -- 3.2-4.5x
//!     at 512 B, 1.14-1.33x at 4 KiB, ~1.02x at 64 KiB.
//!   - Core Ultra 9 285H (no `avx512vl`), P-cores: generic wins 1.28-1.43x
//!     from 4 KiB up. Its E-cores invert again above 16 KiB, which is why
//!     `auto` is a starting point and not an answer.
//!
//! [`CrcKernel::Auto`] takes the first of those, since `avx512vl` is the
//! cheapest available proxy for "this is the server case". Settle it for a
//! given deployment with `cargo run --release -p ioutgt-nvme --example
//! crc_bench`, pinned to the cores the IO threads will use.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};

use crc_fast::{CrcAlgorithm, CrcParams, Digest};

/// NVMe/TCP digests are CRC-32/ISCSI (Castagnoli), fixed by RFC 3720.
const ALGORITHM: CrcAlgorithm = CrcAlgorithm::Crc32Iscsi;

/// Which `crc-fast` kernel folds the payload. Same digest either way; see
/// the module docs for why the faster one depends on the CPU.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CrcKernel {
    /// Resolve from the CPU: fusion where `avx512vl` says server, generic
    /// otherwise. See the module docs for what that is measured on.
    #[default]
    Auto,
    /// `crc-fast`'s CRC-32/ISCSI special case (crc32 instruction +
    /// pclmulqdq). Needs no setup, so it is what an unconfigured process
    /// gets -- see [`select_kernel`].
    Fusion,
    /// `crc-fast`'s generic carry-less folding calculator, reached by passing
    /// the same polynomial as [`CrcParams`].
    Generic,
}

impl CrcKernel {
    /// The spelling printed in logs.
    fn as_str(self) -> &'static str {
        match self {
            CrcKernel::Auto => "auto",
            CrcKernel::Fusion => "fusion",
            CrcKernel::Generic => "generic",
        }
    }
}

impl std::fmt::Display for CrcKernel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

const KERNEL_FUSION: u8 = 0;
const KERNEL_GENERIC: u8 = 1;

/// Written once by [`select_kernel`], before any queue thread exists. The
/// IO-path read is a relaxed load, not a read-modify-write, so the engine's
/// no-atomic-RMW rule holds.
///
/// It starts at *fusion* rather than at the binary's `generic` default, and
/// that is load-bearing: fusion needs no warming, so a process that never
/// calls [`select_kernel`] -- a library embedder, or an integration test
/// driving `spawn_target` directly -- cannot end up folding through an
/// unwarmed [`generic_params`] and paying a lock and an allocation on a
/// queue thread. Whoever wants generic comes through [`select_kernel`],
/// which warms it first.
static KERNEL: AtomicU8 = AtomicU8::new(KERNEL_FUSION);

/// CRC-32/ISCSI as generic parameters, built once.
///
/// The first `CrcParams::new` for a polynomial generates fold constants
/// behind crc-fast's global key cache: a ~27 us miss taking an `RwLock`
/// write and an allocation. That must not land on a queue thread, which is
/// why nothing reaches [`CrcKernel::Generic`] without [`select_kernel`]
/// warming this first.
fn generic_params() -> &'static CrcParams {
    static PARAMS: OnceLock<CrcParams> = OnceLock::new();
    PARAMS.get_or_init(|| {
        CrcParams::new(
            "CRC-32/ISCSI",
            32,
            0x1EDC_6F41,
            0xFFFF_FFFF,
            true,
            0xFFFF_FFFF,
            0xE306_9283,
        )
    })
}

/// Choose the folding kernel and do the setup it needs; returns what
/// [`CrcKernel::Auto`] resolved to.
///
/// Call once during startup, before any connection is accepted.
pub fn select_kernel(kernel: CrcKernel) -> CrcKernel {
    // Warm before the store, unconditionally: paid once here whichever kernel
    // is chosen, so a later switch (crc_bench, the kernel tests) finds it
    // ready rather than faulting it in mid-run.
    let _ = generic_params();
    let resolved = match kernel {
        CrcKernel::Auto if is_x86_feature_detected!("avx512vl") => CrcKernel::Fusion,
        CrcKernel::Auto => CrcKernel::Generic,
        explicit => explicit,
    };
    let code = match resolved {
        // Auto is resolved above; naming it keeps a future variant a compile
        // error rather than a silent fusion.
        CrcKernel::Fusion | CrcKernel::Auto => KERNEL_FUSION,
        CrcKernel::Generic => KERNEL_GENERIC,
    };
    KERNEL.store(code, Ordering::Relaxed);
    // crc-fast's arch-ops detection is a second OnceLock, ~3 us on first
    // touch; one digest through the chosen kernel lands that here too.
    let _ = crc32c(&[0u8; 64]);
    resolved
}

/// The kernel currently in effect.
pub fn active_kernel() -> CrcKernel {
    match KERNEL.load(Ordering::Relaxed) {
        KERNEL_GENERIC => CrcKernel::Generic,
        _ => CrcKernel::Fusion,
    }
}

/// Incremental CRC32C accumulator for data digests (DDGST).
///
/// Holds a bare `u32`, not a [`Digest`] (296 bytes): the recv path snapshots
/// the accumulator with the rest of its per-PDU phase on the direct-recv
/// tail path.
#[derive(Debug, Clone, Copy)]
pub struct Crc32c {
    /// crc-fast's raw running state, pre-xorout, so it can be handed back to
    /// either kernel as a seed.
    state: u32,
}

impl Default for Crc32c {
    fn default() -> Self {
        Self::new()
    }
}

impl Crc32c {
    /// Fresh accumulator (initial state per RFC 3720 CRC32C).
    pub const fn new() -> Self {
        Crc32c { state: 0xFFFF_FFFF }
    }

    /// Fold more payload bytes into the digest.
    pub fn update(&mut self, data: &[u8]) {
        // Carry crc-fast's raw state across calls rather than the finalized
        // digest: `get_state` / `new_with_init_state` are a documented
        // round-trip, so only the generic branch's `init_algorithm` poke
        // leans on internals. What holds that line is
        // tests/digest_kernels.rs, which reseeds under both kernels against
        // a from-the-polynomial CRC32C.
        //
        // Rebuilding the `Digest` per call costs 3.5-5.0 ns against the
        // 3.4-4.0 ns saved by not growing `DataPhase` from 24 to 320 bytes:
        // a wash, taken for the smaller struct.
        let seed = u64::from(self.state);
        let mut digest = if KERNEL.load(Ordering::Relaxed) == KERNEL_GENERIC {
            let mut params = *generic_params();
            params.init_algorithm = seed;
            Digest::new_with_params(params)
        } else {
            Digest::new_with_init_state(ALGORITHM, seed)
        };
        digest.update(data);
        #[allow(clippy::cast_possible_truncation)] // 32-bit algorithm: high half is zero
        {
            self.state = digest.get_state() as u32;
        }
    }

    /// Final digest value (compare with the wire's little-endian u32).
    pub fn finalize(self) -> u32 {
        // xorout, applied here because the accumulator carries raw state.
        !self.state
    }
}

/// One-shot digest of a complete buffer (header digests).
///
/// `crc-fast` returns `u64` because one entry point serves CRC-16/32/64; for a
/// 32-bit algorithm the high half is always zero.
#[allow(clippy::cast_possible_truncation)] // 32-bit algorithm: high half is zero
pub fn crc32c(data: &[u8]) -> u32 {
    let sum = if KERNEL.load(Ordering::Relaxed) == KERNEL_GENERIC {
        crc_fast::checksum_with_params(*generic_params(), data)
    } else {
        crc_fast::checksum(ALGORITHM, data)
    };
    sum as u32
}
