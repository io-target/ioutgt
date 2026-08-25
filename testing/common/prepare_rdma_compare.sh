#!/bin/bash
# Host-side preparation for testing/vmtest/ioutgt_rdma_compare.sh: build
# the release RDMA target it launches. The guest finds it by path
# (target/release/ioutgt-nvme-rdma), so nothing needs publishing.
set -eu
TOP="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TOP"
cargo build --release -p ioutgt-nvme-rdma --bin ioutgt-nvme-rdma
[ -x "$TOP/target/release/ioutgt-nvme-rdma" ] || {
    echo "FAIL: release ioutgt-nvme-rdma not built" >&2
    exit 1
}
echo "built target/release/ioutgt-nvme-rdma"
