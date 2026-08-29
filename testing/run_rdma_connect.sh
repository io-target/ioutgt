#!/bin/bash
# Build the ioutgt-nvme-rdma target binary on the host and run a real
# `nvme connect -t rdma` bring-up inside the vmtest guest (which provides a
# soft-RoCE rdma_rxe device and the in-kernel nvme-rdma host). The guest
# entrypoint (testing/vmtest/ioutgt_rdma_connect.sh) loads the modules, adds an
# rxe device on the guest NIC, starts the target, and drives discover/connect/
# identify/read/disconnect.
set -euo pipefail

TOP="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOP"
. "$TOP/testing/common/vmtest.sh"     # RUN_VM + VMTEST_DATA_DIR + VM config

cargo build -p ioutgt-nvme-rdma --bin ioutgt-nvme-rdma
BIN="$TOP/target/debug/ioutgt-nvme-rdma"
[ -x "$BIN" ] || { echo "FAIL: ioutgt-nvme-rdma binary not built"; exit 1; }

# Run the in-tree script by path: no copy into the vmtest checkout, and
# the guest keeps $0 inside this repo so the script finds the tree (and
# the binary) itself instead of taking them as arguments.
exec "$RUN_VM" "$TOP/testing/vmtest/ioutgt_rdma_connect.sh"
