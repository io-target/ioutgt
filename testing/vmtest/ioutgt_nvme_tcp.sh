#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP M4-M8 matrix (target on host)
# vmtest-requires: root nvme-cli fio
#
# Self-contained entry point: runnable directly by vmtest, no stub in the
# vmtest checkout's tests/ needed.
#
#   testing/run_interop.sh "$PWD/testing/vmtest/run_nvme_tcp.sh"
#
# or straight through the harness:
#
#   ~/git/utils/vmtest/vmtest -c ~/git/linux-ioutgt/vmtest.conf \
#       run "$PWD/testing/vmtest/run_nvme_tcp.sh"
set -eu

# We live outside the vmtest checkout, so lib/ is reached through
# VMTEST_DIR (exported into the guest by run_vm).
. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

# The test logic is a sourced library under testing/common/. Living in
# the ioutgt tree means we can find it relative to ourselves -- no 9p
# marker lookup for the checkout path, which a stub in tests/ needs.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../common/ioutgt_connect.sh"

# IOUTGT_MILESTONE picks the stage set (m4/m5/m7/m8/fs/all), as the
# tests/ stub did.
ioutgt_run_"${IOUTGT_MILESTONE:-all}"
