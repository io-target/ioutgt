#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt block-device backend: Identify NS carries the device's IO topology (512e)
# vmtest-requires: root nvme-cli scsi_debug
#
# A 512e stand-in via scsi_debug (512 B logical sector, 4 KiB physical,
# UNMAP with a granularity, an optimal transfer length) behind an in-guest
# ioutgt target. The host derives its queue limits from Identify Namespace
# — NAWUPF/NPWG -> physical_block_size and minimum_io_size, NOWS ->
# optimal_io_size, NPDG -> discard_granularity (nvme_update_disk_info) — so
# the NVMe namespace's sysfs must match the scsi_debug disk's own. A
# target that leaves those fields zero makes the host believe physical ==
# logical == 512 B and issue RMW-inducing sub-page writes.
#
#   testing/run_vmtest.sh testing/vmtest/ioutgt_bdev_topology.sh
#   testing/run_vmtest.sh testing/vmtest/ioutgt_bdev_topology.sh --partition
#
# --partition serves a partition of the scsi_debug disk instead of the
# whole disk: the topology ioctls answer for a partition too, but its sysfs
# node has no queue/ directory — discard_granularity must come from the
# parent disk's, or the namespace under-reports it and fstrim sends
# discards below the device's granularity.
set -eu

PARTITION=0
while [ $# -gt 0 ]; do
    case "$1" in
    --partition) PARTITION=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap
vt_require_module nvme_tcp
vt_require_cmd nvme
modprobe -n scsi_debug 2>/dev/null || vt_skip "scsi_debug module not available"

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../common/ioutgt_guest.sh"

PORT=14422
NQN="nqn.2026-06.io.ioutgt:topo"

# 64 MiB, 512 B sectors in 4 KiB physical blocks (physblk_exp=3), UNMAP on
# with a 16-sector (8 KiB) granularity — deliberately larger than the
# physical block, because the block layer raises a namespace's
# discard_granularity to its physical_block_size anyway and would mask a
# target that forwards no NPDG — and a 1024-sector optimal transfer.
modprobe scsi_debug dev_size_mb=64 sector_size=512 physblk_exp=3 lbpu=1 \
    unmap_granularity=16 opt_blks=1024 || vt_die "modprobe scsi_debug failed"
vt_atexit "rmmod scsi_debug 2>/dev/null || true"
SD=""
for _ in $(seq 50); do
    SD=$(ls -d /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*/block/sd* 2>/dev/null | head -1)
    [ -n "$SD" ] && [ -b "/dev/$(basename "$SD")" ] && break
    sleep 0.2
done
[ -n "$SD" ] || vt_die "scsi_debug disk did not appear"
SDDEV="/dev/$(basename "$SD")"
# Limits always come from the whole disk's queue (a partition has none).
sdq="/sys/block/$(basename "$SD")/queue"
if [ "$PARTITION" = 1 ]; then
    vt_require_cmd sfdisk
    printf 'label: gpt\n,\n' | sfdisk -q "$SDDEV" || vt_die "sfdisk failed"
    PART="${SDDEV}1"
    vt_wait_for_block "$PART" 10 || vt_die "partition $PART did not appear"
    vt_log "serving partition $PART of $SDDEV"
    SDDEV="$PART"
fi
vt_log "scsi_debug disk: $SDDEV lbs=$(cat $sdq/logical_block_size) pbs=$(cat $sdq/physical_block_size) io_min=$(cat $sdq/minimum_io_size) io_opt=$(cat $sdq/optimal_io_size) dg=$(cat $sdq/discard_granularity)"
[ "$(cat $sdq/physical_block_size)" -gt "$(cat $sdq/logical_block_size)" ] ||
    vt_die "scsi_debug did not produce a 512e disk"

ioutgt_guest_start "$SDDEV" "$NQN" "$PORT"
ioutgt_guest_connect "$NQN" "$PORT"
NS=$(ioutgt_guest_wait_ns "$NQN")
nsq="/sys/block/$(basename "$NS")/queue"
vt_log "namespace: $NS lbs=$(cat $nsq/logical_block_size) pbs=$(cat $nsq/physical_block_size) io_min=$(cat $nsq/minimum_io_size) io_opt=$(cat $nsq/optimal_io_size) dg=$(cat $nsq/discard_granularity)"

# Every limit the host derives from Identify NS must equal the backing
# disk's — that is the whole point of forwarding the topology.
for attr in logical_block_size physical_block_size minimum_io_size optimal_io_size discard_granularity; do
    want=$(cat "$sdq/$attr"); got=$(cat "$nsq/$attr")
    [ "$got" = "$want" ] || vt_die "$attr: namespace reports $got, backing disk has $want — topology not forwarded"
done
vt_log "queue topology matches the backing disk"

vt_pass "ioutgt bdev Identify NS forwards the device topology"
