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
set -eu

. "${VMTEST_DIR:?run me via vmtest}/lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap
vt_require_module nvme_tcp
vt_require_module loop
vt_require_cmd nvme
vt_require_cmd blkdiscard
vt_require_cmd losetup

top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
[ -n "$top" ] && [ -d "$top/testing/vmtest" ] ||
    top=$(cat "${VMTEST_DATA_DIR:-/nonexistent}/tmp/ioutgt_top" 2>/dev/null || true)
[ -n "$top" ] || vt_die "no ioutgt checkout (missing ioutgt_top marker)"
BIN="$top/target/release/ioutgt-nvme-tcp"
[ -x "$BIN" ] || vt_die "no ioutgt binary at $BIN (build on the host first)"

PORT=14421
NQN="nqn.2026-06.io.ioutgt:bdev"
SIZE_MB=64
IMG=/tmp/ioutgt-bdev.img
PAT=/tmp/ioutgt-bdev.pat
LOG=/tmp/ioutgt-bdev.log
MB=$((1024 * 1024))

# Sparse backing file on a filesystem that can punch holes, so a discard
# that reaches it is observable as freed blocks.
rm -f "$IMG" "$PAT"
truncate -s "${SIZE_MB}M" "$IMG"
LOOP=$(losetup -f --show "$IMG") || vt_die "losetup failed"
vt_atexit "losetup -d $LOOP 2>/dev/null || true; rm -f $IMG $PAT"
vt_log "loop device: $LOOP over $IMG ($(df -T "$IMG" | awk 'NR==2{print $2}'))"
lname=$(basename "$LOOP")
dmax=$(cat "/sys/block/$lname/queue/discard_max_bytes" 2>/dev/null || echo 0)
[ "$dmax" -gt 0 ] || vt_skip "$LOOP does not support discard (discard_max_bytes=$dmax)"

alloc_bytes() { echo $(( $(stat -c %b "$IMG") * $(stat -c %B "$IMG") )); }

RUST_LOG=info "$BIN" --listen "127.0.0.1:$PORT" --io-threads 1 --subsys-nqn "$NQN" \
    --backend "$LOOP" --control-socket /tmp/ioutgt-bdev.sock >"$LOG" 2>&1 &
TPID=$!
vt_atexit "kill $TPID 2>/dev/null || true; sed 's/\x1b\[[0-9;]*m//g' $LOG | tail -20 >&2"
for _ in $(seq 100); do
    grep -q "listening" "$LOG" && break
    kill -0 "$TPID" 2>/dev/null || { cat "$LOG"; vt_die "target died"; }
    sleep 0.1
done
grep -q "listening" "$LOG" || vt_die "target never listened"

# The namespace of OUR subsystem, found through sysfs by NQN. Not a
# before/after diff of /dev/nvme*n*: a controller left over from an aborted
# earlier run would hide the device, and any other namespace appearing in
# the window (the guest's QEMU PCI NVMe rescanning) would be picked — and
# then overwritten by the pattern fill below.
ns_for_nqn() {
    local s c n
    for s in /sys/class/nvme-subsystem/*; do
        [ "$(cat "$s/subsysnqn" 2>/dev/null)" = "$NQN" ] || continue
        # Native multipath: the head node sits in the subsystem dir; without
        # it, the namespace hangs off the controller dir.
        for n in "$s"/nvme*n* "$s"/nvme*/nvme*n*; do
            n=$(basename "$n")
            [[ "$n" =~ ^nvme[0-9]+n[0-9]+$ ]] && [ -b "/dev/$n" ] && { echo "/dev/$n"; return 0; }
        done
    done
    for c in /sys/class/nvme/*; do
        [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$NQN" ] || continue
        for n in "$c"/nvme*n*; do
            n=$(basename "$n")
            [[ "$n" =~ ^nvme[0-9]+n[0-9]+$ ]] && [ -b "/dev/$n" ] && { echo "/dev/$n"; return 0; }
        done
    done
    return 1
}

nvme connect -t tcp -a 127.0.0.1 -s "$PORT" -n "$NQN" --nr-io-queues=1 ||
    vt_die "nvme connect failed"
vt_atexit "nvme disconnect -n $NQN >/dev/null 2>&1 || true"
NS=""
for _ in $(seq 100); do
    NS=$(ns_for_nqn) && break
    sleep 0.2
done
[ -n "$NS" ] || { dmesg | tail -20; vt_die "namespace device missing"; }
vt_log "namespace: $NS"

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
