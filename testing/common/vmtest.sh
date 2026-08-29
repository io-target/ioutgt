# vmtest.sh — host-side VM config, sourced by runner.sh (beside this file) and every
# testing/run_*.sh launcher. The single place the VM's shape is defined.
#
# Every knob honours a pre-set environment variable, so one run can differ
# without editing this file:
#
#   VMTEST_NUMA_NODES=1 testing/run_interop.sh
#   VMTEST_KERNEL=~/git/linux-next testing/run_vmtest.sh testing/vmtest/ioutgt_tbkas.sh
#
# Resolved from this file's own location, never the caller's cwd.
_VMTEST_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VMTEST_TOP="$(cd "$_VMTEST_SH_DIR/../.." && pwd)"

# The launcher itself, so a runner does not have to spell out the path.
RUN_VM="${RUN_VM:-$_VMTEST_TOP/testing/common/runner.sh}"

# Kernel to boot: the distribution kernel that is running, by default --
# no source tree, no build -- so a fresh clone runs the VM tests on any
# machine with vng installed. Testing a kernel under development is a
# shell-side choice, in any form vng --run accepts:
#
#   VMTEST_KERNEL=~/git/linux-next       a built kernel tree
#   VMTEST_KERNEL=/boot/vmlinuz-6.17     a kernel image by path
#   VMTEST_KERNEL=6.17.3-200.fc43.x86_64 an installed release
#   VMTEST_KERNEL=v6.6.17                an upstream tag, downloaded by vng
#
# The runner logs which kernel it booted either way.
VMTEST_KERNEL="${VMTEST_KERNEL:-$(uname -r)}"

# The 9p share the guest mounts read-write: the tmp/ marker directory used
# for host<->guest signalling, plus anything that must outlive the VM
# (fio JSON, target logs, xfstests results). Kept inside the repo so a
# checkout is self-contained; created on first use.
VMTEST_DATA_DIR="${VMTEST_DATA_DIR:-$_VMTEST_TOP/testing/vmtest/data}"

# Extra directories to share into the guest read-write, as a space-separated
# list of raw vng --rwdir specs -- a bare path, or guestpath=hostpath:
#
#   VMTEST_RWDIR=/mnt/nvme testing/run_vmtest.sh testing/vmtest/ioutgt_fio.sh
#   VMTEST_RWDIR="/mnt/nvme /data=/srv/data" testing/ioutgt_xfstests.sh
#
# VMTEST_DATA_DIR is always shared and does not need listing here. Useful
# for putting backing images on a real filesystem instead of 9p.
VMTEST_RWDIR="${VMTEST_RWDIR:-}"

# VM sizing. A multi-NUMA guest is the default because
# testing/run_affinity.sh needs more than one node to have anything to
# check (spread_cpus placement is per-node); every other test is
# indifferent, and the guest kernel needs CONFIG_NUMA=y either way.
VMTEST_CPUS="${VMTEST_CPUS:-16}"
VMTEST_MEM="${VMTEST_MEM:-8G}"
VMTEST_NUMA_NODES="${VMTEST_NUMA_NODES:-4}"

# User-mode networking: the guest reaches a host-side target at 10.0.2.2,
# which is how every NVMe/TCP test connects. NET2 adds the second
# interface the two-NIC tests use.
VMTEST_NET="${VMTEST_NET:-1}"
VMTEST_NET2="${VMTEST_NET2:-1}"

mkdir -p "$VMTEST_DATA_DIR/tmp"
unset _VMTEST_SH_DIR _VMTEST_TOP
