#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP fio data-integrity verify (target on host)
# vmtest-requires: root nvme-cli fio
#
#   testing/run_interop.sh "$PWD/testing/vmtest/run_fio.sh"
set -eu

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../common/ioutgt_connect.sh"

ioutgt_run_m5
ioutgt_mark "PASS fio-verify"
