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

# Pull vmtest's resolved paths into this shell -- chiefly VMTEST_DATA_DIR,
# which the runners need on the HOST to place the marker files the guest
# reads. `vmtest env` applies environment > conf > default once and emits
# shell assignments, so nothing here has to know where the conf points.
eval "$("$VMTEST" -c "$VMTEST_CONF" env)"
: "${VMTEST_DATA_DIR:?vmtest env did not resolve VMTEST_DATA_DIR}"
