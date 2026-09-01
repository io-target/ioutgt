//! Compare the CRC32C folding kernels on THIS machine, to settle what
//! `--crc-kernel` should be here.
//!
//!   cargo run --release -p ioutgt-nvme --example crc_bench
//!
//! PIN IT: `taskset -c <cpu>`, to a core the IO threads will actually use.
//! The answer is microarchitectural, not a property of the machine -- on one
//! hybrid CPU generic wins by 1.42x on a P-core and loses by 0.73x on an
//! E-core, same binary, same boot. Unpinned, the two arms can even land on
//! different core types and the verdict becomes a lottery, which is the
//! artifact the A/A control exists to expose.
//!
//! Arms are interleaved and reported as medians (back-to-back arms drift with
//! clocks and thermals), and an A/A control -- one kernel in both arms, true
//! difference zero -- states the measurement's own false-signal floor. An A/B
//! result inside the control band means no difference measured.

use std::hint::black_box;
use std::time::Instant;

use ioutgt_nvme::digest::{self, CrcKernel};

/// An NVMe block, a TCP segment's worth of recv window, and the large-IO end.
const SIZES: &[usize] = &[512, 1448, 4096, 16384, 65536];
/// Enough for a stable median, few enough that the run takes seconds.
const ROUNDS: usize = 12;

/// The CPU this process is running on, so a result can be tied to the core
/// that produced it. `processor` is field 39 of /proc/self/stat; the fields
/// before it include the parenthesised comm, so split past that first.
fn current_cpu() -> String {
    std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|stat| {
            let tail = stat.rsplit(')').next()?.to_owned();
            tail.split_whitespace().nth(36).map(str::to_owned)
        })
        .unwrap_or_else(|| "?".to_owned())
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).expect("no NaN"));
    v[v.len() / 2]
}

/// One round of one arm: nanoseconds per one-shot digest of `buf`.
fn time_round(kernel: CrcKernel, buf: &[u8], iters: usize) -> f64 {
    digest::select_kernel(kernel);
    let start = Instant::now();
    let mut sink = 0u32;
    for _ in 0..iters {
        sink ^= digest::crc32c(black_box(buf));
    }
    black_box(sink);
    start.elapsed().as_secs_f64() * 1e9 / iters as f64
}

/// One round of each per iteration -- A,B,A,B -- so a mid-run frequency step
/// lands on the pair instead of masquerading as a kernel difference.
fn time_pair(a: CrcKernel, b: CrcKernel, buf: &[u8], iters: usize) -> (f64, f64) {
    let mut sa = Vec::with_capacity(ROUNDS);
    let mut sb = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        sa.push(time_round(a, buf, iters));
        sb.push(time_round(b, buf, iters));
    }
    (median(sa), median(sb))
}

fn main() {
    println!(
        "cpu: {} (pin with taskset), avx512vl={}",
        current_cpu(),
        is_x86_feature_detected!("avx512vl")
    );
    // `get_calculator_target` ignores its algorithm argument and reports the
    // GENERIC calculator's tier; on x86_64 the fusion path detects inline and
    // has no report of its own.
    println!(
        "crc-fast generic-arm tier: {}",
        crc_fast::get_calculator_target(crc_fast::CrcAlgorithm::Crc32Iscsi)
    );
    println!(
        "--crc-kernel auto resolves here to: {}\n",
        digest::select_kernel(CrcKernel::Auto)
    );

    println!(
        "{:>8}  {:>11}  {:>11}  {:>9}  {:>9}",
        "bytes", "fusion(ns)", "generic(ns)", "speedup", "A/A ctrl"
    );
    for &n in SIZES {
        let buf = vec![0xA5u8; n];
        let iters = (1 << 24) / n + 64;

        // A fast wrong answer is worthless, and this is the cheapest place
        // to notice the kernels diverging.
        digest::select_kernel(CrcKernel::Fusion);
        let a = digest::crc32c(&buf);
        digest::select_kernel(CrcKernel::Generic);
        let b = digest::crc32c(&buf);
        assert_eq!(a, b, "kernels disagree at {n} bytes");

        let (fusion, generic) = time_pair(CrcKernel::Fusion, CrcKernel::Generic, &buf, iters);
        // Same kernel in both arms, interleaved identically: whatever this
        // reports is the measurement's own noise, not a kernel difference.
        let (ctrl_a, ctrl_b) = time_pair(CrcKernel::Fusion, CrcKernel::Fusion, &buf, iters);

        println!(
            "{n:>8}  {fusion:>11.1}  {generic:>11.1}  {:>8.2}x  {:>8.2}x",
            fusion / generic,
            ctrl_a / ctrl_b,
        );
    }

    println!("\nSpeedup > 1.00x means generic is faster. The A/A control is the");
    println!("same ratio computed between two runs of ONE kernel, so its distance");
    println!("from 1.00x is the measurement's own noise: treat any speedup no");
    println!("farther from 1.00x than the control as no difference.");
}
