//! Every folding kernel against a CRC32C computed from the polynomial --
//! including the ones this CPU does not select by default, which nothing
//! else in the tree covers.
//!
//! Selection is process-global and libtest runs `#[test]` fns on parallel
//! threads, so this is ONE test function in its own binary: two would
//! interleave their `select_kernel` calls and silently digest under the
//! wrong kernel.

use ioutgt_nvme::digest::{self, CrcKernel};

/// CRC32C from the polynomial, sharing no code with the backend.
fn reference(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0x82F6_3B78
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

#[test]
fn every_kernel_agrees_with_the_polynomial_and_shares_state() {
    assert_eq!(reference(b"123456789"), 0xE306_9283, "reference is wrong");

    let mut s = 0x2545_F491_4F6C_DD1Du64;
    let mut next = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    };
    let mut buf = Vec::with_capacity(70_000);
    while buf.len() < 70_000 {
        buf.extend_from_slice(&next().to_le_bytes());
    }

    // Auto must land on a real kernel and actually apply it; the explicit
    // arms below are what prove both kernels correct.
    let resolved = digest::select_kernel(CrcKernel::Auto);
    assert_ne!(resolved, CrcKernel::Auto, "Auto must resolve");
    assert_eq!(digest::active_kernel(), resolved, "Auto: not applied");

    for kernel in [CrcKernel::Fusion, CrcKernel::Generic] {
        assert_eq!(
            digest::select_kernel(kernel),
            kernel,
            "explicit not honoured"
        );
        assert_eq!(digest::active_kernel(), kernel, "{kernel}: not applied");

        assert_eq!(digest::crc32c(b"123456789"), 0xE306_9283, "{kernel}");

        // Lengths straddling every word, block and folding boundary,
        // including the empty payload a zero-length H2C produces.
        for len in [
            0usize, 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255,
            256, 257, 511, 512, 513, 4095, 4096, 4097, 8192, 16384, 32768, 65535, 65536, 70_000,
        ] {
            let data = &buf[..len];
            let want = reference(data);
            assert_eq!(digest::crc32c(data), want, "{kernel} one-shot len={len}");

            let mut inc = digest::Crc32c::new();
            inc.update(data);
            assert_eq!(inc.finalize(), want, "{kernel} incremental len={len}");

            // An empty fold must be the identity, wherever it lands. No
            // caller produces one today, but `update` is public.
            let mut inc = digest::Crc32c::new();
            inc.update(&[]);
            inc.update(data);
            inc.update(&[]);
            assert_eq!(inc.finalize(), want, "{kernel} empty-fold len={len}");
        }

        // Random fragmentation: the resume step must mean the same thing to
        // whichever kernel is folding.
        for case in 0..1_000 {
            // Mix the NVMe block sizes in with the random long tail, as the
            // recv path sees them.
            let len = match case % 4 {
                0 => 512,
                1 => 4096,
                2 => 65536,
                _ => usize::try_from(next() % buf.len() as u64).expect("< buf.len()"),
            };
            let data = &buf[..len];
            let mut inc = digest::Crc32c::new();
            let mut rest = data;
            while !rest.is_empty() {
                let bound = u64::try_from(rest.len().min(9_000)).expect("fits u64");
                let take = 1 + usize::try_from(next() % bound).expect("< bound");
                inc.update(&rest[..take]);
                rest = &rest[take..];
            }
            assert_eq!(
                inc.finalize(),
                reference(data),
                "{kernel} fragmented len={len}"
            );
        }
    }

    // A digest started under one kernel must finish under another: nothing
    // switches mid-connection, but the kernels sharing one meaning for the
    // intermediate state is what makes the 4-byte accumulator sound.
    let data: Vec<u8> = (0..4096u32)
        .map(|i| u8::try_from(i % 251).expect("< 256"))
        .collect();
    let want = reference(&data);
    for (first, second) in [
        (CrcKernel::Fusion, CrcKernel::Generic),
        (CrcKernel::Generic, CrcKernel::Fusion),
    ] {
        let mut inc = digest::Crc32c::new();
        digest::select_kernel(first);
        inc.update(&data[..1500]);
        digest::select_kernel(second);
        inc.update(&data[1500..]);
        assert_eq!(inc.finalize(), want, "{first} then {second}");
    }
}
