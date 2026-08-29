#!/bin/bash
# vmtest-desc: ioutgt NVMe/RDMA verbs rxe-loopback functional test
# vmtest-requires: root
# vmtest-prepare: testing/common/prepare_rdma_loopback.sh
set -u
# Run by path from the ioutgt tree: this file is testing/vmtest/<me>, so
# the repo root is two levels up.
REPO_TOP="$(cd "$(dirname "$0")/../.." && pwd)"
# The lib test harness cannot be picked out in here: cargo drops several
# ioutgt_nvme_rdma-<hash> executables into target/debug/deps and they all
# answer --list, so only cargo's own metadata distinguishes them. The
# host side selects it and publishes the path through the marker dir,
# the same channel run_interop.sh uses for the t/io_uring probe.
# Read it from the marker, not from the environment: only a fixed set of
# variables crosses into the guest (the runner's GUEST_ENV), so an IOUTGT_*
# override set here would never arrive. The launcher honours
# IOUTGT_RDMA_TEST_BIN on the host and writes the result below.
BIN="$(cat "${VMTEST_DATA_DIR:-/nonexistent}/tmp/ioutgt_rdma_test_bin" 2>/dev/null || true)"
[ -n "$BIN" ] && [ -x "$BIN" ] || {
    echo "[rdma] RESULT: FAIL (no test binary published at"
    echo "       \$VMTEST_DATA_DIR/tmp/ioutgt_rdma_test_bin)"
    echo "       run testing/run_rdma_loopback.sh -- it selects the lib test"
    echo "       harness with cargo and publishes it; IOUTGT_RDMA_TEST_BIN"
    echo "       overrides that choice, set on the HOST."
    exit 1
}
# Say which harness we got: with the path chosen on the host there is
# otherwise no way to tell from the run whether an override took effect.
echo "[rdma] test binary: $BIN"
echo "[rdma] loading rdma_rxe"
# shellcheck source=../common/rxe.sh
. "$REPO_TOP/testing/common/rxe.sh"
rxe_setup || echo "[rdma] rxe bring-up incomplete (no netdev/IP?) — proceeding"
ibv_devinfo 2>&1 | grep -E "hca_id|state:|link_layer" | head -6
# The CM loopback test connects to the rxe netdev's own IP; publish it.
if [ -n "${RXE_IP:-}" ]; then
	IOUTGT_RXE_IP="$RXE_IP"
	export IOUTGT_RXE_IP
fi
echo "[rdma] rxe ip=${IOUTGT_RXE_IP:-<none>}"
echo "[rdma] === running rxe_ tests ==="
"$BIN" --test-threads=1 --nocapture rxe_
rc=$?
echo "[rdma] rxe tests rc=$rc"
[ $rc -eq 0 ] && echo "[rdma] RESULT: PASS" || echo "[rdma] RESULT: FAIL"
exit $rc
