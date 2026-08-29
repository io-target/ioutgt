#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP M4-M8 matrix (target on host)
# vmtest-requires: root nvme-cli fio
#
#   testing/run_interop.sh                 # the default test
#   testing/run_interop.sh ioutgt_nvme_tcp
#
# or straight into the VM, against a target you started yourself:
#
#   testing/common/runner.sh testing/vmtest/ioutgt_nvme_tcp.sh
set -eu

. "$(dirname "$0")/../common/vt.sh"
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
