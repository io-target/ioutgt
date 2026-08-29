#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# vt.sh — in-guest helpers for tests launched by runner.sh.
#
# A sourced library, and the only thing a guest test needs from the
# harness. Every test starts by sourcing it relative to itself:
#
#     . "$(dirname "$0")/../common/vt.sh"
#
# and gets logging, a cleanup stack, and requirement checks. Sourcing
# defines functions and nothing else: it sets no shell options and touches
# no state, so a test keeps whatever `set` flags it chose.
#
# The exit codes are the contract a runner reads: 0 = pass, 4 = skip (a
# prerequisite the guest does not have), anything else = fail. Counting 4
# separately is what keeps a sweep green on a box missing an optional
# dependency.
#
# runner.sh exports VMTEST_DATA_DIR into the guest: the 9p share holding
# the host<->guest marker files and any artifact that must survive the VM.
# runner.sh also sources this file itself, for the same log/die helpers on
# the host side, so the two always sit in one directory.
#
# PROJECT-INDEPENDENT, like runner.sh beside it — copy both into another
# project unchanged. Project-specific helpers belong in their own library
# sourced after this one.

# ----------------------------------------------------------------------
# Logging / exit status
# ----------------------------------------------------------------------

vt_log()  { printf '[vmtest] %s\n' "$*" >&2; }
vt_die()  { printf '[vmtest] FAIL: %s\n' "$*" >&2; exit 1; }
vt_skip() { printf '[vmtest] SKIP: %s\n' "$*" >&2; exit 4; }
vt_pass() { printf '[vmtest] PASS: %s\n' "$*" >&2; }

# ----------------------------------------------------------------------
# Cleanup stack
#
# Every helper that allocates something registers its own undo with
# vt_atexit, so one vt_install_trap at the top of a test unwinds
# everything. Hooks run LIFO, and a failing hook does not stop the rest.
#
# An array append inside $(...) runs in a subshell and never reaches the
# parent, so a hook registered from a command substitution is silently
# lost -- callers must not register from one.
# ----------------------------------------------------------------------

VT_ATEXIT_CMDS=()

vt_atexit() { VT_ATEXIT_CMDS+=("$*"); }

vt_run_atexit() {
    local rc=$? i
    for (( i = ${#VT_ATEXIT_CMDS[@]} - 1; i >= 0; i-- )); do
        eval "${VT_ATEXIT_CMDS[$i]}" || true
    done
    exit "$rc"
}

vt_install_trap() { trap vt_run_atexit EXIT; }

# ----------------------------------------------------------------------
# Requirements — declared at the top of a test.
# A missing optional piece SKIPs; a missing hard requirement FAILs.
# ----------------------------------------------------------------------

vt_require_root() {
    [ "$(id -u)" -eq 0 ] || vt_die "must run as root (inside the VM)"
}

vt_require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || vt_skip "missing command: $c"
    done
}

vt_require_module() {
    local m
    for m in "$@"; do
        modprobe "$m" 2>/dev/null || vt_skip "cannot modprobe $m"
    done
}

# ----------------------------------------------------------------------
# Block devices
# ----------------------------------------------------------------------

# Wait up to TIMEOUT seconds (default 10) for DEV to appear.
vt_wait_for_block() {
    local dev="$1" timeout="${2:-10}" i
    for (( i = 0; i < timeout * 10; i++ )); do
        [ -b "$dev" ] && return 0
        sleep 0.1
    done
    return 1
}

