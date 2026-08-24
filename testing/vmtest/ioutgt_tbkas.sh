#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP traffic-based keep-alive (CTRATT.TBKAS)
# vmtest-requires: root nvme-cli
#
# Guest-side traffic-based keep-alive (CTRATT.TBKAS) check against an
# ioutgt target on the host. Self-contained: run it by path, e.g.
#
#   testing/run_interop.sh "$PWD/testing/vmtest/ioutgt_tbkas.sh"
#
# Connects with a deliberately short KATO so the target's expiry window
# (2*KATO + one keepalive tick) is far shorter than the IO phase: if IO
# traffic did NOT feed the admin queue's watchdog, the controller would
# be torn down mid-run.
set -eu

# Outside the vmtest checkout, so lib/ comes via VMTEST_DIR (run_vm
# exports it into the guest).
. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

ADDR="${IOUTGT_ADDR:-10.0.2.2}"
PORT="${IOUTGT_PORT:-$(cat "${VMTEST_DATA_DIR:-/nonexistent}/tmp/ioutgt_port" 2>/dev/null || echo 4420)}"
NQN="${IOUTGT_NQN:-nqn.2026-06.io.ioutgt:test}"

# KATO=1s -> target expiry at 2*1000 + 500ms tick = 2.5s of silence.
KATO_S="${IOUTGT_TBKAS_KATO:-1}"
# Well past several expiry windows.
PHASE_S="${IOUTGT_TBKAS_PHASE:-20}"

vt_require_module nvme_tcp
vt_require_cmd nvme

tbkas_ns() {
    local dev i
    for i in $(seq 100); do
        dev=$(nvme list 2>/dev/null | awk '$1 ~ /\/dev\/nvme/ {print $1}' | tail -1)
        [ -n "$dev" ] && [ -b "$dev" ] && { echo "$dev"; return 0; }
        sleep 0.2
    done
    return 1
}

# Fail if the controller reset/reconnected/dropped during a phase.
tbkas_assert_no_reset() {
    local what="$1" since="$2" now
    now=$(dmesg | sed -n "${since},\$p")
    if echo "$now" | grep -qiE "Removing ctrl|reconnect|Reconnecting|keep.alive|I/O [0-9]+ QID|resetting controller|connection lost"; then
        echo "$now" | tail -30 >&2
        vt_die "controller disturbed during $what (see dmesg above)"
    fi
    vt_log "$what: controller undisturbed"
}

ioutgt_run_tbkas() {
    nvme disconnect -n "$NQN" >/dev/null 2>&1 || true

    vt_log "nvme connect --keep-alive-tmo=$KATO_S --nr-io-queues=2"
    nvme connect -t tcp -a "$ADDR" -s "$PORT" -n "$NQN" \
        --nr-io-queues=2 --keep-alive-tmo="$KATO_S" ||
        vt_die "nvme connect (kato=$KATO_S) failed"

    local ctrl
    ctrl=$(nvme list-subsys "$NQN" 2>/dev/null | sed -n 's/.*\(nvme[0-9]\+\) .*tcp.*/\1/p' | head -1)
    [ -n "$ctrl" ] || ctrl=$(ls -d /sys/class/nvme/nvme* 2>/dev/null | tail -1 | xargs -r basename)
    [ -n "$ctrl" ] || vt_die "no controller after connect"
    vt_log "controller: $ctrl"

    # 1) The advertisement. The Linux host only suppresses Keep Alive
    #    commands because of this bit, so it must actually be visible.
    local ctratt
    ctratt=$(nvme id-ctrl "/dev/$ctrl" -o json 2>/dev/null |
        sed -n 's/.*"ctratt"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
    [ -n "$ctratt" ] || vt_die "could not read ctratt from id-ctrl"
    vt_log "id-ctrl ctratt=$ctratt"
    [ $(( ctratt & 64 )) -ne 0 ] ||
        vt_die "CTRATT.TBKAS (bit 6) not advertised (ctratt=$ctratt)"
    vt_log "CTRATT.TBKAS advertised"

    # Also confirm the kernel latched it (nvme_init_identify sets
    # NVME_CTRL_ATTR_TBKAS, which is what makes the host skip KAs).
    local dev
    dev=$(tbkas_ns) || vt_die "namespace device missing"
    vt_log "namespace: $dev"

    local mark
    mark=$(dmesg | wc -l)

    # 2) Busy phase: sustained IO on the IO queues. The admin queue
    #    carries no commands of its own here, so the controller only
    #    survives if IO traffic reaches its keep-alive watchdog.
    vt_log "busy phase: ${PHASE_S}s of IO with kato=${KATO_S}s"
    local end=$(( SECONDS + PHASE_S ))
    while [ "$SECONDS" -lt "$end" ]; do
        dd if="$dev" of=/dev/null bs=4k count=256 iflag=direct status=none 2>/dev/null ||
            vt_die "IO failed mid-run (controller likely torn down)"
        sleep 0.2
    done
    [ -b "$dev" ] || vt_die "namespace vanished during busy phase"
    nvme id-ctrl "/dev/$ctrl" >/dev/null 2>&1 ||
        vt_die "admin queue dead after busy phase"
    tbkas_assert_no_reset "busy phase (${PHASE_S}s, kato=${KATO_S}s)" "$mark"

    # 3) Idle phase: no IO at all. The host's own Keep Alive commands
    #    must still hold the controller up -- TBKAS must not have
    #    replaced that path, only supplemented it.
    mark=$(dmesg | wc -l)
    vt_log "idle phase: ${PHASE_S}s with no IO"
    sleep "$PHASE_S"
    nvme id-ctrl "/dev/$ctrl" >/dev/null 2>&1 ||
        vt_die "controller dropped while idle (keep-alive regression)"
    tbkas_assert_no_reset "idle phase (${PHASE_S}s, kato=${KATO_S}s)" "$mark"

    nvme disconnect -n "$NQN" >/dev/null || vt_die "nvme disconnect failed"
    vt_log "disconnect ok"
    vt_pass "ioutgt TBKAS: advertised, IO traffic and idle KA both hold the controller"
}

# Runnable directly (vmtest run <path>) and still sourceable as a library
# by a tests/ stub -- the guard keeps a stub from running us twice.
# An `if` (not `&&`) so a false test cannot return 1 into a sourcing
# script's `set -e`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ioutgt_run_tbkas
fi
