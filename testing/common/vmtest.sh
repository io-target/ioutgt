# vmtest.sh — ioutgt's VM config: what this project overrides in the
# generic runner (runner.sh, beside this file), which finds it here
# and supplies a default for everything not set here.
#
# Sourced by runner.sh and by every testing/run_*.sh launcher, so it must
# stay idempotent -- hence the "${VAR:-...}" form throughout, which also
# lets one run differ without editing the file:
#
#   VMTEST_KERNEL=~/git/linux-next testing/run_interop.sh
#   VMTEST_NUMA_NODES=1 testing/run_vmtest.sh testing/vmtest/ioutgt_fio.sh
#
# Resolved from this file's own location, never the caller's cwd.
_VMTEST_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VMTEST_TOP="$(cd "$_VMTEST_SH_DIR/../.." && pwd)"

# The launcher, so a runner does not have to spell out the path.
RUN_VM="${RUN_VM:-$_VMTEST_TOP/testing/common/runner.sh}"
VMTEST_PROJECT_DIR="${VMTEST_PROJECT_DIR:-$_VMTEST_TOP}"

# The kernel is deliberately NOT set here. The runner's own default is the
# distribution kernel that is running -- no source tree, no build -- so a
# fresh clone runs the VM tests on any machine with vng installed. Testing
# a kernel under development is a shell-side choice, in any form vng --run
# accepts:
#
#   VMTEST_KERNEL=~/git/linux-next       a built kernel tree
#   VMTEST_KERNEL=/boot/vmlinuz-6.17     a kernel image by path
#   VMTEST_KERNEL=6.17.3-200.fc43.x86_64 an installed release
#   VMTEST_KERNEL=v6.6.17                an upstream tag, downloaded by vng
#
# The runner logs which kernel it booted either way.

# The 9p share the guest mounts read-write: the tmp/ marker directory used
# for host<->guest signalling, plus anything that must outlive the VM
# (fio JSON, target logs, xfstests results). Kept inside the repo so a
# checkout is self-contained; created on first use.
VMTEST_DATA_DIR="${VMTEST_DATA_DIR:-$_VMTEST_TOP/testing/vmtest/data}"

# A multi-NUMA guest by default: testing/run_affinity.sh needs more than
# one node to have anything to check (spread_cpus placement is per-node),
# and every other test is indifferent. The guest kernel needs CONFIG_NUMA=y.
VMTEST_NUMA_NODES="${VMTEST_NUMA_NODES:-4}"

# A second user-mode NIC for the two-NIC tests; the first is on by default
# and is how every NVMe/TCP test reaches the host target at 10.0.2.2.
VMTEST_NET2="${VMTEST_NET2:-1}"

unset _VMTEST_SH_DIR _VMTEST_TOP
