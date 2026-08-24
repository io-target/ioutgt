# vmtest.sh — shared vmtest launcher config, sourced by testing/run_*.sh.
# Keeps the vmtest binary and its config file defined in one place instead of
# repeated inline in every launcher. Both honor a pre-set environment variable,
# so a single run can point elsewhere without editing this file:
#   VMTEST=/path/vmtest VMTEST_CONF=/path/vmtest.conf testing/run_interop.sh
VMTEST="${VMTEST:-$HOME/git/utils/vmtest/vmtest}"
# The config ships with the repo (vmtest.conf, next to this file), so a
# fresh checkout runs the VM tests without a private per-machine file.
# Resolved from this file's own location, not the caller's $TOP or cwd.
_VMTEST_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMTEST_CONF="${VMTEST_CONF:-$_VMTEST_SH_DIR/vmtest.conf}"
unset _VMTEST_SH_DIR

# Where the VM images and the host<->guest marker dir live. The runners
# need this on the HOST, but the config file that sets it is sourced by
# vt_load_config inside the vmtest child -- so a conf-set value never
# reaches us on its own. Ask vmtest to resolve it, which applies the full
# environment > conf > built-in-default chain exactly once, and export it
# so the child agrees with us.
if [ -z "${VMTEST_DATA_DIR:-}" ]; then
    VMTEST_DATA_DIR="$("$VMTEST" -c "$VMTEST_CONF" config 2>/dev/null |
        sed -n 's/^VMTEST_DATA_DIR *= *//p')"
fi
: "${VMTEST_DATA_DIR:?could not resolve VMTEST_DATA_DIR from $VMTEST_CONF}"
export VMTEST_DATA_DIR
