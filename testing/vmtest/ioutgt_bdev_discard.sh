#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt block-device backend: DSM discard frees space, Write Zeroes zeroes
# vmtest-requires: root nvme-cli util-linux
#
# Runs its own ioutgt target inside the guest on a loop device (the only
# place a block device is available without root on the host), then drives
# the two ONCS operations the file backend used to treat as no-ops on
# bdevs and checks their *effect* on the backing store:
#
#   blkdiscard     -> NVMe DSM deallocate -> BLOCK_URING_CMD_DISCARD on the
#                     loop device -> the backing file's allocated blocks drop
#   blkdiscard -z  -> NVMe Write Zeroes  -> fallocate(ZERO_RANGE) on the bdev
#                     -> the range reads back as zeroes
#
# Either verb silently succeeding without touching the store is exactly the
# bug this test pins, so both effects are asserted, not just exit status.
#
#   testing/run_vmtest.sh testing/vmtest/ioutgt_bdev_discard.sh
#   testing/run_vmtest.sh testing/vmtest/ioutgt_bdev_discard.sh --sector-size 4096
#
# --sector-size N formats the loop device with an N-byte logical sector (a
# 4Kn drive stand-in) and additionally asserts the host sees an N-byte LBA:
# the target must probe the store's block size rather than assume 512, or
# every sub-4K O_DIRECT IO the host is entitled to issue fails with EINVAL.
set -eu

SECTOR=512
while [ $# -gt 0 ]; do
    case "$1" in
    --sector-size) SECTOR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap
vt_require_module nvme_tcp
vt_require_module loop
vt_require_cmd nvme
vt_require_cmd blkdiscard
vt_require_cmd losetup

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../common/ioutgt_guest.sh"

PORT=14421
NQN="nqn.2026-06.io.ioutgt:bdev"
SIZE_MB=64
IMG=/tmp/ioutgt-bdev.img
PAT=/tmp/ioutgt-bdev.pat
MB=$((1024 * 1024))

# Sparse backing file on a filesystem that can punch holes, so a discard
# that reaches it is observable as freed blocks.
rm -f "$IMG" "$PAT"
truncate -s "${SIZE_MB}M" "$IMG"
LOOP=$(losetup -f --show --sector-size "$SECTOR" "$IMG") || vt_die "losetup failed"
vt_atexit "losetup -d $LOOP 2>/dev/null || true; rm -f $IMG $PAT"
vt_log "loop device: $LOOP over $IMG ($(df -T "$IMG" | awk 'NR==2{print $2}')), sector $SECTOR"
lname=$(basename "$LOOP")
dmax=$(cat "/sys/block/$lname/queue/discard_max_bytes" 2>/dev/null || echo 0)
[ "$dmax" -gt 0 ] || vt_skip "$LOOP does not support discard (discard_max_bytes=$dmax)"

alloc_bytes() { echo $(( $(stat -c %b "$IMG") * $(stat -c %B "$IMG") )); }

ioutgt_guest_start "$LOOP" "$NQN" "$PORT"
ioutgt_guest_connect "$NQN" "$PORT"
NS=$(ioutgt_guest_wait_ns "$NQN")
vt_log "namespace: $NS"

# Geometry: the LBA the host was told must be the loop device's logical
# sector. A 512 B LBA over a 4096 B sector is the pre-probe bug.
lbs=$(cat "/sys/block/$(basename "$NS")/queue/logical_block_size")
[ "$lbs" = "$SECTOR" ] ||
    vt_die "host sees ${lbs}B LBAs over a ${SECTOR}B-sector device — block size not probed"
vt_log "host logical block size: $lbs"

# Fill the whole device with a saved random pattern so both "still intact"
# and "now zero" are checkable byte-for-byte.
head -c $((SIZE_MB * MB)) /dev/urandom >"$PAT"
dd if="$PAT" of="$NS" bs=1M count="$SIZE_MB" oflag=direct status=none ||
    vt_die "pattern write failed"
sync
full=$(alloc_bytes)
vt_log "backing store allocated after fill: $((full / MB)) MiB"
[ "$full" -ge $((SIZE_MB * MB * 9 / 10)) ] ||
    vt_die "fill did not allocate the backing file ($full bytes)"

# --- DSM deallocate: first half ---------------------------------------
blkdiscard -o 0 -l $((SIZE_MB / 2 * MB)) "$NS" || vt_die "blkdiscard failed"
sync
after_discard=$(alloc_bytes)
freed=$((full - after_discard))
vt_log "backing store freed by discard: $((freed / MB)) MiB"
# A discard that reached the loop device punches ~32 MiB of holes; a
# target that swallowed the DSM leaves the allocation untouched.
[ "$freed" -ge $((SIZE_MB / 2 * MB * 3 / 4)) ] ||
    vt_die "discard freed only $freed bytes — DSM did not reach the block device"
# Untouched half still intact.
cmp -n $((SIZE_MB / 2 * MB)) -i $((SIZE_MB / 2 * MB)) "$NS" "$PAT" ||
    vt_die "data outside the discarded range was clobbered"
vt_log "discard: space freed, other half intact"

# --- Write Zeroes: third quarter --------------------------------------
q=$((SIZE_MB / 4 * MB))
blkdiscard -z -o $((2 * q)) -l "$q" "$NS" || vt_die "blkdiscard -z failed"
sync
cmp -n "$q" -i $((2 * q)):0 "$NS" /dev/zero ||
    vt_die "Write Zeroes range does not read back as zeroes"
cmp -n "$q" -i $((3 * q)) "$NS" "$PAT" ||
    vt_die "data beyond the Write Zeroes range was clobbered"
vt_log "write zeroes: range zeroed, neighbour intact"

vt_pass "ioutgt bdev discard + write zeroes reach the block device"
