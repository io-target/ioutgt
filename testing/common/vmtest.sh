# vmtest.sh — shared vmtest launcher config, sourced by testing/run_*.sh.
# Keeps the vmtest binary and its config file defined in one place instead of
# repeated inline in every launcher. Both honor a pre-set environment variable,
# so a single run can point elsewhere without editing this file:
#   VMTEST=/path/vmtest VMTEST_CONF=/path/vmtest.conf testing/run_interop.sh
VMTEST="${VMTEST:-$HOME/git/utils/vmtest/vmtest}"
# The config ships with the repo (testing/vmtest/vmtest.conf), so a fresh
# checkout runs the VM tests without a private per-machine file. Resolved
# from this file's own location, not the caller's $TOP or cwd.
_VMTEST_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMTEST_CONF="${VMTEST_CONF:-$_VMTEST_TOP/vmtest/vmtest.conf}"
unset _VMTEST_TOP
