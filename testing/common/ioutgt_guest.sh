#!/bin/bash
# In-guest ioutgt helpers for tests that run their own target inside the VM
# (block-device backends need root, which only the guest has). A sourced
# library: expects vmtest's lib/common.sh loaded and vt_install_trap done.
#
#   ioutgt_guest_bin            -> path of the host-built release binary
#   ioutgt_guest_start BACKEND NQN PORT [extra target args...]
#                               -> starts the target, waits for its listener,
#                                  registers kill + log tail on exit
#   ioutgt_guest_connect NQN PORT -> connects over loopback, registers the
#                                  disconnect on exit
#   ioutgt_guest_wait_ns NQN    -> prints that subsystem's /dev node once
#                                  it exists (capture it: NS=$(...))
#   ioutgt_guest_ns NQN         -> the same lookup, once, no wait
#
# Only ioutgt_guest_wait_ns/ioutgt_guest_ns may be called inside $(...):
# vt_atexit appends to a bash array, and an array write in a
# command-substitution subshell never reaches the parent, so a hook
# registered there is silently lost.

# The checkout is 9p-visible at its host path: relative to this library,
# else through the marker run_vmtest.sh/run_interop.sh publish.
ioutgt_guest_top() {
    local top
    top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    [ -n "$top" ] && [ -d "$top/testing/vmtest" ] ||
        top=$(cat "${VMTEST_DATA_DIR:-/nonexistent}/tmp/ioutgt_top" 2>/dev/null || true)
    [ -n "$top" ] || vt_die "no ioutgt checkout (missing ioutgt_top marker)"
    echo "$top"
}

ioutgt_guest_bin() {
    local bin
    bin="$(ioutgt_guest_top)/target/release/ioutgt-nvme-tcp"
    [ -x "$bin" ] || vt_die "no ioutgt binary at $bin (build on the host first)"
    echo "$bin"
}

ioutgt_guest_start() {
    local backend="$1" nqn="$2" port="$3"; shift 3
    local bin log pid
    bin=$(ioutgt_guest_bin)
    log="/tmp/ioutgt-guest-$port.log"
    RUST_LOG=info "$bin" --listen "127.0.0.1:$port" --io-threads 1 --subsys-nqn "$nqn" \
        --backend "$backend" --control-socket "/tmp/ioutgt-guest-$port.sock" "$@" >"$log" 2>&1 &
    pid=$!
    vt_atexit "kill $pid 2>/dev/null || true; sed 's/\x1b\[[0-9;]*m//g' $log | tail -20 >&2"
    for _ in $(seq 100); do
        grep -q "listening" "$log" && return 0
        kill -0 "$pid" 2>/dev/null || { cat "$log"; vt_die "target died"; }
        sleep 0.1
    done
    vt_die "target never listened"
}

# The namespace of ONE subsystem, found through sysfs by NQN. Not a
# before/after diff of /dev/nvme*n*: a controller left over from an aborted
# earlier run would hide the device, and any other namespace appearing in
# the window (the guest's QEMU PCI NVMe rescanning) would be picked — and
# then written to by the test.
ioutgt_guest_ns() {
    local nqn="$1" s c n
    for s in /sys/class/nvme-subsystem/*; do
        [ "$(cat "$s/subsysnqn" 2>/dev/null)" = "$nqn" ] || continue
        # Native multipath: the head node sits in the subsystem dir; without
        # it, the namespace hangs off the controller dir.
        for n in "$s"/nvme*n* "$s"/nvme*/nvme*n*; do
            n=$(basename "$n")
            [[ "$n" =~ ^nvme[0-9]+n[0-9]+$ ]] && [ -b "/dev/$n" ] && { echo "/dev/$n"; return 0; }
        done
    done
    for c in /sys/class/nvme/*; do
        [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$nqn" ] || continue
        for n in "$c"/nvme*n*; do
            n=$(basename "$n")
            [[ "$n" =~ ^nvme[0-9]+n[0-9]+$ ]] && [ -b "/dev/$n" ] && { echo "/dev/$n"; return 0; }
        done
    done
    return 1
}

ioutgt_guest_connect() {
    local nqn="$1" port="$2"
    nvme connect -t tcp -a 127.0.0.1 -s "$port" -n "$nqn" --nr-io-queues=1 ||
        vt_die "nvme connect failed"
    vt_atexit "nvme disconnect -n $nqn >/dev/null 2>&1 || true"
}

ioutgt_guest_wait_ns() {
    local nqn="$1" ns=""
    for _ in $(seq 100); do
        ns=$(ioutgt_guest_ns "$nqn") && break
        sleep 0.2
    done
    [ -n "$ns" ] || { dmesg | tail -20 >&2; vt_die "namespace device missing"; }
    echo "$ns"
}
