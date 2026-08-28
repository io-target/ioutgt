#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP recv-ring A/B perf probe (target on host)
# vmtest-requires: root nvme-cli fio
#
# Connects to the host ioutgt target with a single IO queue and runs a
# fixed fio perf matrix (no verify), writing per-run JSON into the 9p
# shared dir so the HOST can parse iops/bw/clat. The host drives the ring
# ON vs OFF distinction by restarting the target between boots (the
# --recv-ring-mb knob); this guest test is identical across both arms:
#
#   testing/run_interop.sh ioutgt_recvab                    # ring off
#   IOUTGT_RECV_BUF_MB=64 testing/run_vmtest.sh \
#       testing/vmtest/ioutgt_recvab.sh                     # ring on
#
# Tunables: RECVAB_RUNTIME (15s), RECVAB_RAMP (3s), RECVAB_RUNS (2).
set -eu

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../common/ioutgt_connect.sh"
. "$HERE/../common/ioutgt_guest.sh"

vt_require_cmd fio

OUT="$VMTEST_DATA_DIR/tmp"
RUNTIME="${RECVAB_RUNTIME:-15}"
RAMP="${RECVAB_RAMP:-3}"
RUNS="${RECVAB_RUNS:-2}"

vt_log "nvme connect --nr-io-queues=1 to $ADDR:$PORT"
nvme connect -t tcp -a "$ADDR" -s "$PORT" -n "$NQN" --nr-io-queues=1 ||
    vt_die "nvme connect failed"
vt_atexit "nvme disconnect -n $NQN >/dev/null 2>&1 || true"

# By NQN, not the last device nvme list prints: a controller left over
# from an aborted run would otherwise be measured instead of this one.
dev=$(ioutgt_guest_wait_ns "$NQN")
ctrl=$(basename "$dev"); ctrl=${ctrl%n*}
qc=$(cat "/sys/class/nvme/$ctrl/queue_count" 2>/dev/null || echo '?')
vt_log "perf dev=$dev ctrl=$ctrl queue_count=$qc"

# Workload matrix: rw:bs:qd. randwrite is where the recv ring elides the
# H2C payload copy; randread is the C2H control (ring should not matter).
JOBS="randwrite:4k:32 randwrite:64k:8 randread:4k:32"

run_one() {
    local rw=$1 bs=$2 qd=$3 run=$4
    local tag="${rw}-${bs}-qd${qd}-run${run}"
    local json="$OUT/recvab-${tag}.json"
    rm -f "$json"
    vt_log "fio $tag"
    fio --name="$tag" --filename="$dev" --rw="$rw" --bs="$bs" \
        --iodepth="$qd" --numjobs=1 --direct=1 --ioengine=libaio \
        --runtime="$RUNTIME" --time_based --ramp_time="$RAMP" \
        --norandommap --randrepeat=0 --group_reporting \
        --output-format=json --output="$json" ||
        vt_die "fio $tag failed"
    sync
}

for spec in $JOBS; do
    IFS=: read -r rw bs qd <<<"$spec"
    for run in $(seq "$RUNS"); do
        run_one "$rw" "$bs" "$qd" "$run"
    done
done

ioutgt_mark "PASS recvab"
vt_pass "ioutgt recv-ring A/B perf matrix (JSON in \$VMTEST_DATA_DIR/tmp/recvab-*.json)"
