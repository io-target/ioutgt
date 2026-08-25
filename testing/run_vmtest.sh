#!/bin/bash
# Generic runner for the guest tests in testing/vmtest/.
#
#   testing/run_vmtest.sh testing/vmtest/ioutgt_tbkas.sh
#   testing/run_vmtest.sh testing/vmtest/run_fio.sh -g quick
#   testing/run_vmtest.sh testing/vmtest/           # every test in the dir
#
# Takes a script's path, and anything after it is passed to that test; or
# a directory, in which case every runnable script under it is run in
# turn and a per-test OK/FAIL summary is printed. Extra arguments make no
# sense for a directory, so they are refused rather than silently applied
# to every test.
#
# "Runnable" means the file carries a `# vmtest-desc:` header: the
# libraries under testing/common/ are sourced by an entry script, and a
# directory sweep must not try to execute one.
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

# A file carries the vmtest-desc header iff it is meant to be executed
# rather than sourced.
runnable() { grep -q '^# vmtest-desc:' "$1" 2>/dev/null; }

[ $# -ge 1 ] || {
    echo "usage: $0 testing/vmtest/<test>.sh [args...]" >&2
    echo "       $0 testing/vmtest/            # run them all" >&2
    echo "runnable tests:" >&2
    for f in "$TOP"/testing/vmtest/*.sh; do
        runnable "$f" && echo "  testing/vmtest/$(basename "$f")" >&2
    done
    exit 2
}
TARGET_ARG="${1%/}"; shift   # trailing slash would give testing/vmtest//foo.sh

TESTS=()
if [ -d "$TARGET_ARG" ]; then
    [ $# -eq 0 ] || {
        echo "arguments cannot be passed to a directory of tests: $*" >&2
        exit 2
    }
    for f in "$TARGET_ARG"/*.sh; do
        [ -f "$f" ] && [ -x "$f" ] && runnable "$f" && TESTS+=("$f")
    done
    [ ${#TESTS[@]} -gt 0 ] || { echo "no runnable tests in $TARGET_ARG" >&2; exit 2; }
else
    [ -f "$TARGET_ARG" ] || { echo "no such script or directory: $TARGET_ARG" >&2; exit 2; }
    [ -x "$TARGET_ARG" ] || { echo "not executable: $TARGET_ARG" >&2; exit 2; }
    # Refuse a library here rather than boot a VM to watch it die on the
    # first vt_* call: sourced files define helpers and invoke nothing.
    runnable "$TARGET_ARG" || {
        echo "not a runnable test (no '# vmtest-desc:' header): $TARGET_ARG" >&2
        echo "sourced libraries are run through an entry script in testing/vmtest/" >&2
        exit 2
    }
    TESTS=("$TARGET_ARG")
fi

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
    # ioutgt_rdma_test_bin is published by a vmtest-prepare step; leaving
    # it behind would let a later direct run silently use a stale harness.
    rm -f "$PID_FILE" "$MARKER_DIR/ioutgt_top" "$MARKER_DIR/ioutgt_rdma_test_bin"
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
echo "ioutgt up (pid $TARGET_PID); ${#TESTS[@]} test(s) to run"

# Sweeping a directory, each test's output goes to its own file rather
# than the console. Not just for tidiness: vmtest's VM writes its console
# output starting at offset 0 of whatever it is redirected to, so with
# every test sharing one stream the next boot overwrites the previous
# test's output *and* the RUN/OK/FAIL lines around it. Per-test files
# keep the console stream to the markers alone, which nothing clobbers.
LOG_DIR=""
if [ ${#TESTS[@]} -gt 1 ]; then
    LOG_DIR="$TOP/target/vmtest-logs"
    rm -rf "$LOG_DIR"
    mkdir -p "$LOG_DIR"
fi

FAILED=()
SKIPPED=()
RC=0
for t in "${TESTS[@]}"; do
    name="$(basename "${t%.sh}")"
    echo
    echo "=== RUN  ${t#$TOP/} $*"
    # A test may name a host-side setup step it cannot do from inside the
    # guest -- building a binary, or publishing a path through the marker
    # dir. Run it here rather than teaching this script about any
    # particular test.
    prep="$(sed -n 's/^# vmtest-prepare:[[:space:]]*//p' "$t" | head -1)"
    if [ -n "$prep" ]; then
        set +e
        ( cd "$TOP" && "$TOP/$prep" )
        prc=$?
        set -e
        if [ $prc -ne 0 ]; then
            echo "=== FAIL ${t#$TOP/} (prepare failed: $prep)"
            FAILED+=("${t#$TOP/}")
            RC=1
            continue
        fi
    fi
    # Pipe through cat rather than redirecting straight to the file. The
    # VM's console output is not written sequentially: given a regular
    # file it seeks back to the start, so a plain > loses the boot
    # messages under later output (and >> does not help -- the writer
    # reopens the file instead of using our O_APPEND handle). A pipe
    # cannot be seeked at all, so everything arrives in order and cat
    # appends it. PIPESTATUS keeps the test's own exit code.
    set +e
    if [ -n "$LOG_DIR" ]; then
        "$VMTEST" -c "$VMTEST_CONF" run "$t" "$@" 2>&1 | cat >> "$LOG_DIR/$name.log"
    else
        "$VMTEST" -c "$VMTEST_CONF" run "$t" "$@" 2>&1 | cat
    fi
    trc=${PIPESTATUS[0]}
    set -e
    if [ $trc -eq 0 ]; then
        echo "=== OK   ${t#$TOP/}"
    elif [ $trc -eq 4 ]; then
        # vmtest's documented skip status: a prerequisite the guest does
        # not have (vt_require_cmd, vt_skip). Not a failure -- counting it
        # as one turns a green sweep red on any box missing an optional
        # dependency, or on a documented override like NUMA_NODES=1.
        echo "=== SKIP ${t#$TOP/}"
        SKIPPED+=("${t#$TOP/}")
    else
        echo "=== FAIL ${t#$TOP/} (exit $trc)${LOG_DIR:+ -- log: ${LOG_DIR#$TOP/}/$name.log}"
        FAILED+=("${t#$TOP/}")
        RC=1
    fi
done

if [ ${#TESTS[@]} -gt 1 ]; then
    echo
    echo "=== summary: $(( ${#TESTS[@]} - ${#FAILED[@]} - ${#SKIPPED[@]} ))/${#TESTS[@]} passed, ${#SKIPPED[@]} skipped, ${#FAILED[@]} failed"
    for f in ${SKIPPED+"${SKIPPED[@]}"}; do echo "  SKIP $f"; done
    for f in ${FAILED+"${FAILED[@]}"}; do echo "  FAIL $f"; done
fi

if [ -n "$LOG_DIR" ]; then
    echo "per-test logs: ${LOG_DIR#$TOP/}/"
else
    echo "--- target log ---"
    tail -30 "$LOG"
fi
exit $RC
