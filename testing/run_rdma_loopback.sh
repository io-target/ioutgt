#!/bin/bash
# Build the ioutgt-nvme-rdma test binary on the host and run the verbs
# rxe-loopback functional test inside the vmtest guest, which provides a
# soft-RoCE (rdma_rxe) device. The guest entrypoint
# (testing/vmtest/ioutgt_rdma_loopback.sh) loads rdma_rxe, adds an rxe device
# on the guest NIC, and runs the prebuilt test binary.
set -euo pipefail

TOP="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOP"
. "$TOP/testing/common/vmtest.sh"     # VMTEST + VMTEST_CONF (env-overridable)

# Take the LIB test harness path from cargo itself: the deps/ glob is ambiguous
# (the package's clap bin also lands there as ioutgt_nvme_rdma-<hash>, and
# picking it by mtime hands the guest a binary that rejects --test-threads).
BIN=$(cargo test -p ioutgt-nvme-rdma --no-run --message-format=json \
    | jq -r 'select(.executable != null and .target.kind == ["lib"]) | .executable' | tail -1)
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "FAIL: no ioutgt-nvme-rdma test binary built"; exit 1; }

# Only cargo can tell the lib test harness from the other
# ioutgt_nvme_rdma-<hash> executables in deps/, so publish the choice
# through the marker dir the guest reads (as run_interop.sh does for the
# t/io_uring probe). Everything else the script works out from its own
# path, so it takes no arguments.
mkdir -p "$VMTEST_DATA_DIR/tmp"
echo "$BIN" > "$VMTEST_DATA_DIR/tmp/ioutgt_rdma_test_bin"
trap 'rm -f "$VMTEST_DATA_DIR/tmp/ioutgt_rdma_test_bin"' EXIT

"$VMTEST" -c "$VMTEST_CONF" run "$TOP/testing/vmtest/ioutgt_rdma_loopback.sh"
