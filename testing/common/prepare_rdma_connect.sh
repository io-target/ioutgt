#!/bin/bash
# Host-side preparation for testing/vmtest/ioutgt_rdma_connect.sh: build
# the target binary the guest launches. The guest finds it by path
# (target/debug/ioutgt-nvme-rdma, relative to the tree the test locates),
# so nothing needs publishing -- it just has to exist.
set -eu
TOP="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TOP"
cargo build -p ioutgt-nvme-rdma --bin ioutgt-nvme-rdma
[ -x "$TOP/target/debug/ioutgt-nvme-rdma" ] || {
    echo "FAIL: ioutgt-nvme-rdma binary not built" >&2
    exit 1
}
echo "built target/debug/ioutgt-nvme-rdma"
