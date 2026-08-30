#!/bin/bash
# Host-side interop runner: build ioutgt, start it on 127.0.0.1:4420,
# run the vmtest VM test against it (guest reaches us at 10.0.2.2:4420),
# tear down. Usage: testing/run_interop.sh [test-name]
set -eu

TOP="$(cd "$(dirname "$0")/.." && pwd)"
. "$TOP/testing/common/vmtest.sh"     # RUN_VM + VMTEST_DATA_DIR + VM config
# t/io_uring throughput probe for the ioutgt_bench guest test; published to
# the guest via the 9p marker dir below (env does not cross into the VM).
# Other tests ignore it; override for a different fio build.
T_IO_URING="${T_IO_URING:-$HOME/git/fio/t/io_uring}"
# The guest test to run. A bare name resolves against testing/vmtest/, so
# the short forms stay -- `testing/run_interop.sh ioutgt_fio`. A path is
# taken as given, for a test living elsewhere. Resolved here rather than
# handed to the harness as a registered name: the tests are ours and live
# in this checkout, so a fresh clone runs the acceptance matrix with no
# second repo in the right state.
TEST_NAME="${1:-ioutgt_nvme_tcp}"
if [ -f "$TEST_NAME" ]; then
    TEST_SCRIPT="$TEST_NAME"
else
    TEST_SCRIPT="$TOP/testing/vmtest/$TEST_NAME.sh"
    [ -f "$TEST_SCRIPT" ] || {
        echo "no such test: $TEST_NAME" >&2
        echo "available:" >&2
        for f in "$TOP"/testing/vmtest/*.sh; do
            grep -q '^# vmtest-desc:' "$f" && echo "  $(basename "${f%.sh}")" >&2
        done
        exit 2
    }
fi
# Dedicated port: 4420 is the canonical NVMe port and may be owned by
# other targets on a dev box (kernel nvmet, etc.).
PORT="${IOUTGT_PORT:-14420}"
LOG="$TOP/target/ioutgt-interop.log"

cargo build --release --manifest-path "$TOP/Cargo.toml" -p ioutgt-nvme-tcp

# IOUTGT_BACKEND=memory (default) | null | file
BACKEND_ARGS=()
case "${IOUTGT_BACKEND:-memory}" in
memory) BACKEND_ARGS=(--backend memory) ;;
null) BACKEND_ARGS=(--backend null) ;;
file)
    BACKING="$TOP/target/ioutgt-backing.img"
    truncate -s "${IOUTGT_FILE_MB:-256}M" "$BACKING"
    BACKEND_ARGS=(--backend "$BACKING")
    ;;
*) echo "unknown IOUTGT_BACKEND"; exit 1 ;;
esac

# IOUTGT_SEND_ZC=1: start the target with --send-zc (loopback-copy
# path inside the VM net; exercises notification-gated tag reuse).
ZC_ARGS=()
[ "${IOUTGT_SEND_ZC:-0}" = "1" ] && ZC_ARGS=(--send-zc)

# IOUTGT_IO_QUEUE_SIZE=N: advertise N as the IO MAXCMD ceiling
# (--io-queue-size). Unset → the binary default (128). Set below the
# host's requested depth (e.g. 64) to see the guest kernel clamp to N.
IOQS_ARGS=()
[ -n "${IOUTGT_IO_QUEUE_SIZE:-}" ] && IOQS_ARGS=(--io-queue-size "$IOUTGT_IO_QUEUE_SIZE")
RECV_BUF_ARGS=()
[ -n "${IOUTGT_RECV_BUF_MB:-}" ] && RECV_BUF_ARGS=(--recv-buf-mb "$IOUTGT_RECV_BUF_MB")

CTL_SOCK="$TOP/target/ioutgt-interop.sock"
MARKER_DIR="$VMTEST_DATA_DIR/tmp"
PID_FILE="$TOP/target/ioutgt-interop.pid"

# Only one run at a time: two sharing $TOP/target would overwrite each
# other's pid file and fight over the port, and the loser's cleanup would
# then kill the winner's pid -- or kill nothing and leave a target squatting
# the port for every run after.
exec 9>"$TOP/target/ioutgt-hosttarget.lock"
flock -n 9 || {
    echo "another host-target run is in progress (lock: target/ioutgt-hosttarget.lock)" >&2
    exit 2
}

# Kill the target (and watcher) however the script exits: a surviving
# target squats the port and poisons the next harness or bench run.
# Installed before anything starts so an early failure cannot leak;
# the stale PID file from a previous run is dropped first so cleanup
# can never kill an unrelated reused pid.
rm -f "$PID_FILE"
WATCHER_PID=""
TARGET_PID=""
cleanup() {
    # Kill by the pid we remember AND by whatever the file says. Neither
    # alone is enough: the file can vanish (and then `[ -s ]` silently
    # skips the kill, leaking the target), while the watcher's kill/restart
    # path replaces the process and records the new pid only in the file.
    local filed
    filed=$(cat "$PID_FILE" 2>/dev/null || true)
    for _p in "$TARGET_PID" "$filed"; do
        [ -n "$_p" ] && kill "$_p" 2>/dev/null || true
    done
    [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null || true
    # Drop the checkout marker so a later manual vmtest run cannot pick
    # up a stale path (run_affinity.sh does the same).
    rm -f "$PID_FILE" "$MARKER_DIR/ioutgt_top" "$MARKER_DIR/ioutgt_tiou"
}
trap cleanup EXIT
# Fatal signals bypass the EXIT trap unless turned into an exit.
trap 'exit 129' INT TERM

mkdir -p "$MARKER_DIR"
rm -f "$MARKER_DIR/ioutgt_want_ns2" "$MARKER_DIR/ioutgt_want_kill" \
    "$MARKER_DIR/ioutgt_kill_enabled" "$MARKER_DIR/ioutgt_soak_only"
# Tell the guest which port we serve on (env does not cross into the VM).
echo "$PORT" > "$MARKER_DIR/ioutgt_port"
# Publish this checkout to the guest test wrappers (same 9p marker
# mechanism as run_affinity.sh) so they never need a hardcoded path.
echo "$TOP" > "$MARKER_DIR/ioutgt_top"
# Publish the t/io_uring probe path the same way (only ioutgt_bench reads it).
echo "$T_IO_URING" > "$MARKER_DIR/ioutgt_tiou"
# Fresh log: the startup gate below greps it for the listener line.
: > "$LOG"
# IOUTGT_SOAK_ONLY=N: reconnect-leak mode — the guest only runs N
# connect/disconnect cycles, and we assert the target RSS stays flat.
[ -n "${IOUTGT_SOAK_ONLY:-}" ] && echo "$IOUTGT_SOAK_ONLY" > "$MARKER_DIR/ioutgt_soak_only"

start_target() {
    "$TOP/target/release/ioutgt-nvme-tcp" --listen "0.0.0.0:$PORT" --io-threads "${IOUTGT_IO_THREADS:-2}" \
        --control-socket "$CTL_SOCK" "${BACKEND_ARGS[@]}" "${ZC_ARGS[@]}" "${IOQS_ARGS[@]}" "${RECV_BUF_ARGS[@]}" >>"$LOG" 2>&1 &
    echo $! >"$PID_FILE"
}
start_target
TARGET_PID=$(cat "$PID_FILE")

# Opt-in for the guest's kill/recovery test.
[ "${IOUTGT_ENABLE_KILL:-0}" = "1" ] && : > "$MARKER_DIR/ioutgt_kill_enabled"

# Watcher: serves guest-driven events — M7 hot-add and M8 kill/restart.
#
# It tracks the target in a variable rather than re-reading the pid file
# each pass: deriving liveness from the file meant a vanished file read as
# "target gone", so the watcher exited and silently stopped serving the
# hot-add — the guest then failed M7 with no indication why on the host.
(
    cur=$TARGET_PID
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
            kill -9 "$cur" 2>/dev/null || true
            sleep 2
            start_target
            cur=$(cat "$PID_FILE" 2>/dev/null || true)
            echo "watcher: target restarted (pid $cur)" >>"$LOG"
        fi
        kill -0 "$cur" 2>/dev/null || exit 0
    done
) &
WATCHER_PID=$!

# Wait for the listener.
for _ in $(seq 50); do
    if grep -q "listening" "$LOG" 2>/dev/null; then break; fi
    kill -0 $TARGET_PID 2>/dev/null || { cat "$LOG"; echo "target died"; exit 1; }
    sleep 0.1
done
echo "ioutgt up (pid $TARGET_PID); starting VM test $TEST_NAME"

set +e
"$RUN_VM" "$TEST_SCRIPT"
RC=$?
set -e

# The file first (the watcher's restart path records the live pid only
# there), falling back to the one we started -- otherwise a missing file
# turns the IOUTGT_SOAK_ONLY RSS gate below into a silent no-op.
FINAL_PID=$(cat "$PID_FILE" 2>/dev/null || true)
[ -n "$FINAL_PID" ] || FINAL_PID=$TARGET_PID
if [ -n "$FINAL_PID" ] && [ -r "/proc/$FINAL_PID/status" ]; then
    RSS_KB=$(awk '/VmRSS/{print $2}' "/proc/$FINAL_PID/status")
    echo "--- target RSS after run: $RSS_KB kB ---"
    if [ -n "${IOUTGT_SOAK_ONLY:-}" ] && [ "$RSS_KB" -gt 32768 ]; then
        echo "FAIL: RSS not flat after reconnect soak ($RSS_KB kB > 32 MB)"
        RC=1
    fi
fi
# Per-queue counters, informational: the fio stage's --fsync pass shows
# up as Flush commands when the pool is still alive (idle teardown drops
# the counters after 30 s without connections; the kill stage restarts the
# process). FUA writes flush inside the write path and are not counted.
# The hard VWC gate is the guest-side write_cache/fua sysfs check.
echo "--- target stats after run ---"
"$TOP/target/release/ioutgt-nvme-tcp" stat --socket "$CTL_SOCK" 2>&1 || true
echo "--- target log ---"
tail -50 "$LOG"
exit $RC
