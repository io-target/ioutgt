#!/bin/bash
# Generic runner for the guest tests in testing/vmtest/.
#
#   testing/run_vmtest.sh testing/vmtest/ioutgt_tbkas.sh
#   testing/run_vmtest.sh testing/vmtest/run_fio.sh
#   testing/run_vmtest.sh testing/vmtest/run_nvme_tcp.sh
#
# Takes the script's path; anything after it is passed to the test.
#
# Like run_interop.sh, this stands up a host-side ioutgt target for the
# guest to connect to at 10.0.2.2:$PORT and publishes the marker files
# the guest reads (env does not cross into the VM). Tests that run their
# own target inside the guest (affinity, rdma_*, spdk) simply ignore it.
#
# run_interop.sh is deliberately untouched: it drives the M4-M8 interop
# matrix with its own soak mode and RSS gate. This one is the general
# launcher, and where integration tests will hang off.
#
# Knobs: IOUTGT_BACKEND=memory|null|file, IOUTGT_FILE_MB, IOUTGT_PORT,
#   IOUTGT_IO_THREADS, IOUTGT_SEND_ZC=1, IOUTGT_IO_QUEUE_SIZE,
#   IOUTGT_RECV_BUF_MB, IOUTGT_ENABLE_KILL=1, VMTEST, VMTEST_CONF.
set -eu

TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/testing/common/vmtest.sh"     # VMTEST + VMTEST_CONF + VMTEST_DATA_DIR

[ $# -ge 1 ] || {
    echo "usage: $0 testing/vmtest/<test>.sh [args...]" >&2
    echo "runnable tests:" >&2
    for f in "$TOP"/testing/vmtest/*.sh; do
        # The libraries are sourced by an entry script, not run directly;
        # the metadata header is what marks a file as runnable.
        grep -q '^# vmtest-desc:' "$f" && echo "  testing/vmtest/$(basename "$f")" >&2
    done
    exit 2
}
TEST="$1"; shift
[ -f "$TEST" ] || { echo "no such script: $TEST" >&2; exit 2; }
[ -x "$TEST" ] || { echo "not executable: $TEST" >&2; exit 2; }

PORT="${IOUTGT_PORT:-14420}"
LOG="$TOP/target/ioutgt-vmtest.log"
CTL_SOCK="$TOP/target/ioutgt-vmtest.sock"
PID_FILE="$TOP/target/ioutgt-vmtest.pid"
MARKER_DIR="$VMTEST_DATA_DIR/tmp"

cargo build --release --manifest-path "$TOP/Cargo.toml" -p ioutgt-nvme-tcp

BACKEND_ARGS=()
case "${IOUTGT_BACKEND:-memory}" in
memory) BACKEND_ARGS=(--backend memory) ;;
null) BACKEND_ARGS=(--backend null) ;;
file)
    BACKING="$TOP/target/ioutgt-vmtest-backing.img"
    truncate -s "${IOUTGT_FILE_MB:-256}M" "$BACKING"
    BACKEND_ARGS=(--backend "$BACKING")
    ;;
*) echo "unknown IOUTGT_BACKEND" >&2; exit 1 ;;
esac
ZC_ARGS=(); [ "${IOUTGT_SEND_ZC:-0}" = "1" ] && ZC_ARGS=(--send-zc)
IOQS_ARGS=(); [ -n "${IOUTGT_IO_QUEUE_SIZE:-}" ] && IOQS_ARGS=(--io-queue-size "$IOUTGT_IO_QUEUE_SIZE")
RECV_BUF_ARGS=(); [ -n "${IOUTGT_RECV_BUF_MB:-}" ] && RECV_BUF_ARGS=(--recv-buf-mb "$IOUTGT_RECV_BUF_MB")

# Kill the target (and watcher) however we exit: a survivor squats the
# port and poisons the next run. Installed before anything starts, and
# the stale pid file is dropped first so cleanup cannot kill a reused pid.
rm -f "$PID_FILE"
WATCHER_PID=""
cleanup() {
    [ -s "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
    [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null || true
    rm -f "$PID_FILE" "$MARKER_DIR/ioutgt_top"
}
trap cleanup EXIT
trap 'exit 129' INT TERM

mkdir -p "$MARKER_DIR"
rm -f "$MARKER_DIR/ioutgt_want_ns2" "$MARKER_DIR/ioutgt_want_kill" \
    "$MARKER_DIR/ioutgt_kill_enabled"
echo "$PORT" > "$MARKER_DIR/ioutgt_port"
echo "$TOP" > "$MARKER_DIR/ioutgt_top"
[ "${IOUTGT_ENABLE_KILL:-0}" = "1" ] && : > "$MARKER_DIR/ioutgt_kill_enabled"
: > "$LOG"

start_target() {
    "$TOP/target/release/ioutgt-nvme-tcp" --listen "0.0.0.0:$PORT" \
        --io-threads "${IOUTGT_IO_THREADS:-2}" --control-socket "$CTL_SOCK" \
        "${BACKEND_ARGS[@]}" "${ZC_ARGS[@]}" "${IOQS_ARGS[@]}" "${RECV_BUF_ARGS[@]}" \
        >>"$LOG" 2>&1 &
    echo $! >"$PID_FILE"
}
start_target
TARGET_PID=$(cat "$PID_FILE")

# Watcher: serves guest-driven events — hot-add and kill/restart.
(
    while :; do
        sleep 0.5
        if [ -f "$MARKER_DIR/ioutgt_want_ns2" ]; then
            rm -f "$MARKER_DIR/ioutgt_want_ns2"
            "$TOP/target/release/ioutgt-nvme-tcp" ctl --socket "$CTL_SOCK" \
                '{"op":"ADD_NAMESPACE","nsid":2,"backend":{"type":"memory","size_mb":32}}' ||
                echo "ctl hot-add failed" >>"$LOG"
        fi
        if [ -f "$MARKER_DIR/ioutgt_want_kill" ]; then
            rm -f "$MARKER_DIR/ioutgt_want_kill"
            echo "watcher: kill -9 target" >>"$LOG"
            kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
            sleep 2
            start_target
            echo "watcher: target restarted (pid $(cat "$PID_FILE"))" >>"$LOG"
        fi
        kill -0 "$(cat "$PID_FILE")" 2>/dev/null || exit 0
    done
) &
WATCHER_PID=$!

for _ in $(seq 50); do
    grep -q "listening" "$LOG" 2>/dev/null && break
    kill -0 $TARGET_PID 2>/dev/null || { cat "$LOG"; echo "target died"; exit 1; }
    sleep 0.1
done
echo "ioutgt up (pid $TARGET_PID); running ${TEST#$TOP/} $*"

set +e
"$VMTEST" -c "$VMTEST_CONF" run "$TEST" "$@"
RC=$?
set -e

echo "--- target log ---"
tail -30 "$LOG"
exit $RC
