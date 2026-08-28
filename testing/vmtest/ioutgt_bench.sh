#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP t/io_uring throughput probe (target on host)
# vmtest-requires: root nvme-cli
#
# Launch from the host runner, which starts the target and boots the VM:
#
#   T_IO_URING=/path/to/fio/t/io_uring \
#   IOUTGT_BACKEND=null IOUTGT_IO_THREADS=16 \
#       testing/run_interop.sh ioutgt_bench
#
# env does not cross into the guest, so the host runner publishes the
# listen port and the t/io_uring path through the 9p marker dir; this
# test reads them back. Tunables:
#   IOUTGT_NR_IO_QUEUES  nvme connect --nr-io-queues  (default 16)
#   TIOU_ARGS            t/io_uring args              (default -p0 -b4096 -r15)
#   T_IO_URING           probe path, when run by hand inside the guest
set -eu

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../common/ioutgt_connect.sh"

# The probe is an out-of-tree fio build, so it is optional: SKIP rather
# than FAIL when it is absent, or a box without a fio source tree turns a
# whole-directory sweep (testing/run_vmtest.sh testing/vmtest/) red.
TIOU="${T_IO_URING:-$(cat "$VMTEST_DATA_DIR/tmp/ioutgt_tiou" 2>/dev/null || true)}"
[ -n "$TIOU" ] ||
    vt_skip "t/io_uring path unset: pass T_IO_URING to testing/run_interop.sh"
[ -x "$TIOU" ] ||
    vt_skip "t/io_uring not executable at '$TIOU' (build it: make -C <fio> t/io_uring)"

NRQ="${IOUTGT_NR_IO_QUEUES:-16}"
vt_log "nvme connect --nr-io-queues=$NRQ to $ADDR:$PORT"
nvme connect -t tcp -a "$ADDR" -s "$PORT" -n "$NQN" --nr-io-queues="$NRQ" ||
    vt_die "nvme connect failed"
vt_atexit "nvme disconnect -n $NQN >/dev/null 2>&1 || true"

# The namespace of THIS subsystem, not the last device nvme list prints:
# the guest may carry other controllers (a leftover from an aborted run),
# and driving the wrong disk would benchmark something else entirely.
. "$HERE/../common/ioutgt_guest.sh"
dev=$(ioutgt_guest_wait_ns "$NQN")
ctrl=$(basename "$dev"); ctrl=${ctrl%n*}
qc=$(cat "/sys/class/nvme/$ctrl/queue_count" 2>/dev/null || echo '?')
nr_tags=$(cat "/sys/block/$(basename "$dev")/mq/0/nr_tags" 2>/dev/null || echo '?')
vt_log "bench dev=$dev ctrl=$ctrl queue_count=$qc mq0/nr_tags=$nr_tags (the single-queue depth)"

# Default args mirror the reported repro: t/io_uring's own default is one
# submitter thread at depth 128, 4K, 15s. The single submitter rides one
# nvme queue, whose depth is what the target's --io-queue-size (MAXCMD)
# clamps.
ARGS="${TIOU_ARGS:--p0 -b4096 -r15}"
vt_log "RUN: $TIOU $ARGS $dev"
# shellcheck disable=SC2086
"$TIOU" $ARGS "$dev" 2>&1 | while IFS= read -r line; do vt_log "tiou| $line"; done

ioutgt_mark "PASS bench"
vt_pass "ioutgt t/io_uring throughput probe"
