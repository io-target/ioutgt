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

use crc_fast::{CrcAlgorithm, Digest};

/// NVMe/TCP digests are CRC-32/ISCSI (Castagnoli), fixed by RFC 3720.
const ALGORITHM: CrcAlgorithm = CrcAlgorithm::Crc32Iscsi;

/// Incremental CRC32C accumulator for data digests (DDGST).
///
/// Holds a bare `u32`, not a [`Digest`] (296 bytes): the recv path snapshots
/// the accumulator with the rest of its per-PDU phase on the direct-recv
/// tail path.
#[derive(Debug, Clone, Copy)]
pub struct Crc32c {
    /// crc-fast's raw running state, pre-xorout, so it can be handed back
    /// as a seed.
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
        // round-trip, so the resume needs no reasoning about xorout. What
        // holds that line is the fragmentation test in tests/codec.rs, which
        // reseeds at random split points against a from-the-polynomial
        // CRC32C.
        //
        // Rebuilding the `Digest` per call costs 3.5-5.0 ns against the
        // 3.4-4.0 ns saved by not growing `DataPhase` from 24 to 320 bytes:
        // a wash, taken for the smaller struct.
        let mut digest = Digest::new_with_init_state(ALGORITHM, u64::from(self.state));
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
    crc_fast::checksum(ALGORITHM, data) as u32
}
