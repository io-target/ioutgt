#!/bin/bash
# Build the ioutgt-nvme-rdma test binary on the host and run the verbs
# rxe-loopback functional test inside the vmtest guest, which provides a
# soft-RoCE (rdma_rxe) device. The guest entrypoint
# (testing/vmtest/ioutgt_rdma_loopback.sh) loads rdma_rxe, adds an rxe device
# on the guest NIC, and runs the prebuilt test binary.
set -euo pipefail

TOP="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOP"
. "$TOP/testing/common/vmtest.sh"     # RUN_VM + VMTEST_DATA_DIR + VM config

# Take the LIB test harness path from cargo itself: the deps/ glob is ambiguous
# (the package's clap bin also lands there as ioutgt_nvme_rdma-<hash>, and
# picking it by mtime hands the guest a binary that rejects --test-threads).
# Selecting the harness and publishing it is shared with run_vmtest.sh,
# which runs the same helper from the test's vmtest-prepare header.

"$TOP/testing/common/prepare_rdma_loopback.sh"
trap 'rm -f "$VMTEST_DATA_DIR/tmp/ioutgt_rdma_test_bin"' EXIT

"$RUN_VM" "$TOP/testing/vmtest/ioutgt_rdma_loopback.sh"
