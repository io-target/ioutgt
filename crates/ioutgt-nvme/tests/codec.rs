//! PDU codec round-trips, fragmentation torture, and digest vectors.

use ioutgt_nvme::digest;
use ioutgt_nvme::pdu::{self, PduDecoder, PduKind};
use ioutgt_nvme::spec::{Cqe, Sqe};

/// Drive a decoder over `wire` in fragments of `chunk` bytes; collect all
/// decoded PDUs, skipping payload bytes the way a transport would.
fn decode_all(wire: &[u8], chunk: usize, hdr_digest: bool) -> Vec<pdu::DecodedPdu> {
    let mut decoder = PduDecoder::new(hdr_digest);
    let mut out = Vec::new();
    let mut pos = 0;
    let mut skip = 0usize; // payload + ddgst bytes owed to the current PDU
    while pos < wire.len() {
        let end = (pos + chunk).min(wire.len());
        let mut slice = &wire[pos..end];
        pos = end;
        while !slice.is_empty() {
            if skip > 0 {
                let n = skip.min(slice.len());
                skip -= n;
                slice = &slice[n..];
                continue;
            }
            let consumed = decoder.feed(slice).expect("decode error");
            slice = &slice[consumed..];
            if decoder.is_complete() {
                let decoded = decoder.take().expect("take error");
                skip = decoded.data_len as usize + if decoded.ddgst { 4 } else { 0 };
                out.push(decoded);
            } else {
                assert!(slice.is_empty(), "feed stopped early without completion");
            }
        }
    }
    out
}

#[test]
fn crc32c_known_answer() {
    // Standard CRC32C check value.
    assert_eq!(digest::crc32c(b"123456789"), 0xE306_9283);
    let mut inc = digest::Crc32c::new();
    inc.update(b"1234");
    inc.update(b"56789");
    assert_eq!(inc.finalize(), 0xE306_9283);
}

/// Reversed Castagnoli polynomial (0x1EDC6F41, reflected).
const CRC32C_POLY: u32 = 0x82F6_3B78;

/// CRC32C from the polynomial: reflected, one bit at a time, no crate.
///
/// The backend has several CPU-dispatched folding kernels, so checking it
/// against itself would only prove self-consistency -- the failure worth
/// catching is one that is wrong the same way twice.
fn crc32c_bitwise(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ CRC32C_POLY
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

/// Same arithmetic byte-at-a-time, over a table [`crc32c_bitwise`] generates
/// -- still independent of the backend, but fast enough for megabytes in a
/// debug build.
fn crc32c_reference(data: &[u8]) -> u32 {
    static TABLE: std::sync::OnceLock<[u32; 256]> = std::sync::OnceLock::new();
    let table = TABLE.get_or_init(|| {
        let mut table = [0u32; 256];
        for (i, entry) in table.iter_mut().enumerate() {
            let mut crc = u32::try_from(i).expect("i < 256");
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ CRC32C_POLY
                } else {
                    crc >> 1
                };
            }
            *entry = crc;
        }
        table
    });

    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        let idx = usize::try_from((crc ^ u32::from(byte)) & 0xFF).expect("masked to 8 bits");
        crc = (crc >> 8) ^ table[idx];
    }
    !crc
}

#[test]
fn crc32c_reference_agrees_with_the_check_vector() {
    // Pins the reference itself, so a bug in it cannot excuse the backend.
    assert_eq!(crc32c_bitwise(b"123456789"), 0xE306_9283);
    assert_eq!(crc32c_reference(b"123456789"), 0xE306_9283);
    assert_eq!(crc32c_bitwise(b""), 0);
    assert_eq!(crc32c_reference(b""), 0);
    // The table form must track the bit loop, not just the published vector.
    let bytes: Vec<u8> = (0..=255u8).collect();
    for len in [0usize, 1, 2, 7, 8, 9, 63, 64, 65, 255, 256] {
        assert_eq!(
            crc32c_reference(&bytes[..len]),
            crc32c_bitwise(&bytes[..len]),
            "len={len}"
        );
    }
}

#[test]
fn crc32c_matches_reference_at_edge_lengths() {
    // Lengths that straddle the backend's word, block and folding
    // boundaries, including the empty payload a zero-length H2C produces.
    let bytes: Vec<u8> = (0..70_000u32)
        .map(|i| u8::try_from(i % 251).expect("i % 251 < 256"))
        .collect();
    for len in [
        0usize, 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256,
        257, 511, 512, 513, 4095, 4096, 4097, 8192, 16384, 32768, 65535, 65536, 70_000,
    ] {
        let data = &bytes[..len];
        assert_eq!(
            digest::crc32c(data),
            crc32c_reference(data),
            "one-shot len={len}"
        );
        let mut inc = digest::Crc32c::new();
        inc.update(data);
        assert_eq!(
            inc.finalize(),
            crc32c_reference(data),
            "incremental len={len}"
        );

        // An empty fold must be the identity. No caller produces one today,
        // but `update` is public and the check costs a line.
        let mut inc = digest::Crc32c::new();
        inc.update(&[]);
        inc.update(data);
        inc.update(&[]);
        assert_eq!(
            inc.finalize(),
            crc32c_reference(data),
            "empty-fold len={len}"
        );
    }
}

/// Folding in arbitrary fragments must equal the independent digest.
///
/// Recv windows decide the split points, so correctness has to hold for every
/// fragmentation. The accumulator carries only a finalized `u32` between
/// calls, so this also pins that resume step. `want` comes from the
/// reference, not the backend's own one-shot path: that would agree with
/// itself however wrong both were, and would assert nothing at length zero.
#[test]
fn crc32c_incremental_matches_reference_for_any_fragmentation() {
    // Deterministic xorshift: a fixed seed keeps any failure reproducible.
    let mut s = 0x9E37_79B9_7F4A_7C15u64;
    let mut next = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    };
    // Taken 8 bytes at a time so no draw is truncated on the way in.
    let mut buf = Vec::with_capacity(70_000);
    while buf.len() < 70_000 {
        buf.extend_from_slice(&next().to_le_bytes());
    }
    // A value in `0..n`. Every bound below is at most `buf.len()`.
    let mut draw = |n: usize| -> usize {
        let n = u64::try_from(n).expect("bound fits u64");
        usize::try_from(next() % n).expect("remainder < n <= usize::MAX")
    };

    for case in 0..2_000 {
        // Empty, sub-word, the NVMe block sizes, and the long tail.
        let len = match case % 6 {
            0 => 0,
            1 => draw(64),
            2 => 512,
            3 => 4096,
            4 => 65536,
            _ => draw(buf.len()),
        };
        let data = &buf[..len];
        let want = crc32c_reference(data);

        let mut inc = digest::Crc32c::new();
        let mut rest = data;
        while !rest.is_empty() {
            // 1..=min(remaining, 9000): windows land on both sides of the
            // backend's folding thresholds, so neither path goes untested.
            let take = 1 + draw(rest.len().min(9_000));
            inc.update(&rest[..take]);
            rest = &rest[take..];
        }
        assert_eq!(inc.finalize(), want, "len={len} case={case}");
    }
}

#[test]
fn icreq_icresp_roundtrip() {
    let mut buf = [0u8; 256];
    let n = pdu::encode_icreq(&mut buf, true, true, 4);
    assert_eq!(n, 128);
    let decoded = decode_all(&buf[..n], 128, false);
    assert_eq!(decoded.len(), 1);
    match decoded[0].kind {
        PduKind::IcReq(ic) => {
            assert_eq!(ic.pfv.get(), pdu::PFV_1_0);
            assert_eq!(ic.hpda, 0);
            assert_eq!(ic.digest, pdu::DIGEST_HDGST | pdu::DIGEST_DDGST);
            assert_eq!(ic.maxr2t.get(), 4);
        }
        ref other => panic!("expected ICReq, got {other:?}"),
    }

    let n = pdu::encode_icresp(&mut buf, false, true, 0x40_0000);
    let decoded = decode_all(&buf[..n], 1, false);
    match decoded[0].kind {
        PduKind::IcResp(ic) => {
            assert_eq!(ic.digest, pdu::DIGEST_DDGST);
            assert_eq!(ic.maxdata.get(), 0x40_0000);
        }
        ref other => panic!("expected ICResp, got {other:?}"),
    }
}

#[test]
fn capsule_cmd_with_inline_data_all_fragmentations() {
    let mut sqe = Sqe::zeroed();
    sqe.opcode = 0x01; // write
    sqe.cid.set(0x1234);
    sqe.nsid.set(1);

    let payload = [0xA5u8; 512];
    let mut wire = Vec::new();
    let mut hdr = [0u8; 80];
    let n = pdu::encode_capsule_cmd(&mut hdr, &sqe, true, 512, true);
    wire.extend_from_slice(&hdr[..n]);
    wire.extend_from_slice(&payload);
    let mut ddgst = digest::Crc32c::new();
    ddgst.update(&payload);
    wire.extend_from_slice(&ddgst.finalize().to_le_bytes());

    for chunk in [1, 2, 3, 7, 8, 9, 71, 72, 73, 76, wire.len()] {
        let decoded = decode_all(&wire, chunk, true);
        assert_eq!(decoded.len(), 1, "chunk={chunk}");
        assert_eq!(decoded[0].data_len, 512);
        assert!(decoded[0].ddgst);
        match decoded[0].kind {
            PduKind::CapsuleCmd(got) => {
                assert_eq!(got.opcode, 0x01);
                assert_eq!(got.cid.get(), 0x1234);
                assert_eq!(got.nsid.get(), 1);
            }
            ref other => panic!("expected CapsuleCmd, got {other:?}"),
        }
    }
}

#[test]
fn response_r2t_c2h_data_roundtrip() {
    let mut buf = [0u8; 64];

    let cqe = Cqe::new(0xDEAD_BEEF, 7, 1, 0x42, 0);
    let n = pdu::encode_capsule_resp(&mut buf, &cqe, true);
    let decoded = decode_all(&buf[..n], 1, true);
    match decoded[0].kind {
        PduKind::CapsuleResp(got) => {
            assert_eq!(got.result.get(), 0xDEAD_BEEF);
            assert_eq!(got.sq_head.get(), 7);
            assert_eq!(got.cid.get(), 0x42);
            assert_eq!(got.status.get(), 0);
        }
        ref other => panic!("expected CapsuleResp, got {other:?}"),
    }

    let n = pdu::encode_r2t(&mut buf, 0x11, 9, 8192, 65536, true);
    let decoded = decode_all(&buf[..n], 5, true);
    match decoded[0].kind {
        PduKind::R2T {
            cid,
            ttag,
            offset,
            length,
        } => {
            assert_eq!((cid, ttag, offset, length), (0x11, 9, 8192, 65536));
        }
        ref other => panic!("expected R2T, got {other:?}"),
    }

    // C2HData with payload, last+success set.
    let payload = [0x5Au8; 100];
    let mut wire = Vec::new();
    let n = pdu::encode_c2h_data(&mut buf, 0x33, 0, 100, true, true, true, false);
    wire.extend_from_slice(&buf[..n]);
    wire.extend_from_slice(&payload);
    let decoded = decode_all(&wire, 9, true);
    match decoded[0].kind {
        PduKind::C2HData {
            cid,
            offset,
            length,
            last,
            success,
        } => {
            assert_eq!(
                (cid, offset, length, last, success),
                (0x33, 0, 100, true, true)
            );
        }
        ref other => panic!("expected C2HData, got {other:?}"),
    }
    assert_eq!(decoded[0].data_len, 100);
}

#[test]
fn back_to_back_pdus_across_fragments() {
    // R2T + response + H2CData header concatenated, fed in 3-byte chunks.
    let mut wire = Vec::new();
    let mut buf = [0u8; 64];
    let n = pdu::encode_r2t(&mut buf, 1, 2, 0, 4096, false);
    wire.extend_from_slice(&buf[..n]);
    let n = pdu::encode_capsule_resp(&mut buf, &Cqe::new(0, 1, 1, 1, 0), false);
    wire.extend_from_slice(&buf[..n]);
    let payload = [1u8; 32];
    let n = pdu::encode_h2c_data(&mut buf, 5, 6, 0, 32, true, false, false);
    wire.extend_from_slice(&buf[..n]);
    wire.extend_from_slice(&payload);

    let decoded = decode_all(&wire, 3, false);
    assert_eq!(decoded.len(), 3);
    assert!(matches!(decoded[0].kind, PduKind::R2T { .. }));
    assert!(matches!(decoded[1].kind, PduKind::CapsuleResp(_)));
    match decoded[2].kind {
        PduKind::H2CData {
            cid,
            ttag,
            length,
            last,
            ..
        } => {
            assert_eq!((cid, ttag, length, last), (5, 6, 32, true));
        }
        ref other => panic!("expected H2CData, got {other:?}"),
    }
}

#[test]
fn corrupted_header_digest_rejected() {
    let mut buf = [0u8; 64];
    let n = pdu::encode_r2t(&mut buf, 1, 2, 0, 4096, true);
    buf[10] ^= 0xFF; // corrupt a header byte after the digest was computed
    let mut decoder = PduDecoder::new(true);
    let consumed = decoder
        .feed(&buf[..n])
        .expect("header assembly is digest-agnostic");
    assert_eq!(consumed, n);
    let err = decoder.take().expect_err("corrupted digest must fail");
    assert_eq!(err.fes, pdu::fes::HDR_DIGEST_ERR);
}

#[test]
fn unknown_pdu_type_rejected() {
    let mut decoder = PduDecoder::new(false);
    let bogus = [0xEEu8, 0, 24, 0, 24, 0, 0, 0];
    let err = decoder.feed(&bogus).expect_err("unknown type must fail");
    assert_eq!(err.fes, pdu::fes::INVALID_PDU_HDR);
    assert_eq!(err.fei, 0); // offending field: type at offset 0
}

#[test]
fn truncated_plen_rejected() {
    // CapsuleCmd claiming plen < header size.
    let mut decoder = PduDecoder::new(false);
    let bad = [0x04u8, 0, 72, 0, 16, 0, 0, 0];
    let err = decoder.feed(&bad).expect_err("plen < header must fail");
    assert_eq!(err.fes, pdu::fes::INVALID_PDU_HDR);
}

#[test]
fn term_pdu_roundtrip() {
    let mut buf = [0u8; 64];
    let n = pdu::encode_c2h_term(
        &mut buf,
        pdu::PduError {
            fes: pdu::fes::HDR_DIGEST_ERR,
            fei: 3,
        },
    );
    assert_eq!(n, 24);
    // C2HTerm decodes through the same path as H2CTerm.
    let decoded = decode_all(&buf[..n], 4, false);
    match decoded[0].kind {
        PduKind::H2CTerm { fes, fei } => {
            assert_eq!(fes, pdu::fes::HDR_DIGEST_ERR);
            assert_eq!(fei, 3);
        }
        ref other => panic!("expected term, got {other:?}"),
    }
}

#[test]
fn connect_capsule_layout_matches_spec_offsets() {
    use ioutgt_nvme::fabrics::{ConnectCommand, ConnectData};
    use zerocopy::IntoBytes;

    let mut cmd: ConnectCommand = zerocopy::FromZeros::new_zeroed();
    cmd.opcode = 0x7F;
    cmd.fctype = 0x01;
    cmd.qid.set(0xABCD);
    cmd.sqsize.set(127);
    cmd.kato.set(15000);
    let bytes = cmd.as_bytes();
    assert_eq!(bytes.len(), 64);
    assert_eq!(bytes[0], 0x7F);
    assert_eq!(bytes[4], 0x01);
    assert_eq!(&bytes[42..44], &0xABCDu16.to_le_bytes()); // qid at 42
    assert_eq!(&bytes[44..46], &127u16.to_le_bytes()); // sqsize at 44
    assert_eq!(&bytes[48..52], &15000u32.to_le_bytes()); // kato at 48

    let mut data = ConnectData::zeroed();
    data.cntlid.set(0xFFFF);
    data.subsysnqn[..4].copy_from_slice(b"nqn.");
    let bytes = data.as_bytes();
    assert_eq!(bytes.len(), 1024);
    assert_eq!(&bytes[16..18], &[0xFF, 0xFF]); // cntlid at 16
    assert_eq!(&bytes[256..260], b"nqn."); // subsysnqn at 256
}
