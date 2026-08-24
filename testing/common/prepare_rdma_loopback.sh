#!/bin/bash
# Host-side preparation for testing/vmtest/ioutgt_rdma_loopback.sh.
#
# Picks the crate's lib test harness and publishes its path through the
# marker dir. The guest cannot do this itself: cargo drops several
# ioutgt_nvme_rdma-<hash> executables into target/debug/deps and they all
# answer --list, so only cargo's metadata tells them apart.
#
# IOUTGT_RDMA_TEST_BIN pins a specific harness (a bisect, a build from
# elsewhere) and skips the cargo query.
set -eu
TOP="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TOP"
. "$TOP/testing/common/vmtest.sh"     # VMTEST_DATA_DIR

BIN="${IOUTGT_RDMA_TEST_BIN:-}"
if [ -z "$BIN" ]; then
    BIN=$(cargo test -p ioutgt-nvme-rdma --no-run --message-format=json |
        jq -r 'select(.executable != null and .target.kind == ["lib"]) | .executable' | tail -1)
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || {
    echo "FAIL: no ioutgt-nvme-rdma lib test binary built" >&2
    exit 1
}
mkdir -p "$VMTEST_DATA_DIR/tmp"
echo "$BIN" > "$VMTEST_DATA_DIR/tmp/ioutgt_rdma_test_bin"
echo "published rdma test harness: $BIN"
