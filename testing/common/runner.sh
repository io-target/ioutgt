#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# runner.sh — boot a kernel under virtme-ng and run one guest script in it.
#
#   testing/common/runner.sh path/to/guest-test.sh [args...]
#   testing/common/runner.sh --shell    # interactive root shell instead
#
# The host side of the harness. Guest tests never run this file; they
# source vt.sh, beside it, which is also where this script gets its own
# log/die helpers from -- so the two files travel together.
#
# Dependencies: vng (virtme-ng), and nothing else to install. unshare is
# optional -- it backs the $HOME/.ssh mask, and its absence is logged and
# survived. python3 runs the guest prelude, but vng is itself a Python 3
# program and the guest rootfs is the host's, so it is present whenever
# vng is; it is never an extra install.
#
# You normally reach it through one of the testing/run_*.sh
# runners, which stand up a host-side target first and publish what the
# guest needs through the marker directory.
#
# The guest sees the host filesystem over 9p, so the checkout, the built
# binaries, and the script itself are all reachable at their host absolute
# paths -- nothing is copied in, and a test is just a root shell script
# running against the working tree in a throwaway VM. Config comes from
# vmtest.sh beside this file (VMTEST_KERNEL, sizing, networking, shares).
#
# Exit status is the guest script's, and the codes are the contract a
# sweep reads: 0 pass, 4 skip (a prerequisite the guest lacks), anything
# else fail. Counting 4 apart is what keeps a sweep green on a box
# missing an optional dependency.

set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=vt.sh
. "$SELF_DIR/vt.sh"
TOP="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=vmtest.sh
. "$SELF_DIR/vmtest.sh"


# `--shell` drops into an interactive root shell in the guest instead of
# running a script. It must NOT go through virtme-ng's --exec path: in
# script mode the kernel console is a write-only chardev and the script's
# stdin is a non-tty virtio-serial port, so an interactive shell there
# gets no input and no job control. Interactive mode (no --exec) wires a
# bidirectional getty on the serial console instead, and the env --exec
# would have forwarded is reintroduced through a generated wrapper.
SHELL_MODE=
if [ "${1:-}" = "--shell" ]; then
    SHELL_MODE=1; shift
    TEST_CMD=
else
    [ $# -ge 1 ] || vt_die "usage: $0 <guest-script|--shell> [args...]"
    TEST_CMD="$1"; shift
    [ -f "$TEST_CMD" ] || vt_die "no such script: $TEST_CMD"
    TEST_CMD="$(cd "$(dirname "$TEST_CMD")" && pwd)/$(basename "$TEST_CMD")"
fi

VNG="${VMTEST_VNG:-vng}"
command -v "$VNG" >/dev/null || vt_die "'$VNG' not found (install virtme-ng or set VMTEST_VNG)"

# VMTEST_KERNEL goes straight to `vng --run`, which resolves a build
# directory, a kernel image, an installed release (via
# /usr/lib/modules/<rel>/vmlinuz, then /boot/vmlinuz-<rel>), or an
# upstream tag it downloads. Check what we can here: an unresolvable
# release string would otherwise reach vng as an opaque argument, and one
# that happens to look like a tag would silently start a download.
#
# Always say which kernel this is: a project's default may adapt to the
# machine (a build tree if present, the distribution kernel otherwise), so
# "which kernel did that run against" must not need guessing.
if [ -d "$VMTEST_KERNEL" ]; then
    [ -f "$VMTEST_KERNEL/vmlinux" ] ||
        vt_die "no vmlinux in $VMTEST_KERNEL — build the kernel first"
    vt_log "kernel: build tree $VMTEST_KERNEL"
elif [ -f "$VMTEST_KERNEL" ]; then
    vt_log "kernel: image $VMTEST_KERNEL"
else
    case "$VMTEST_KERNEL" in
    v[0-9]*) vt_log "kernel: upstream tag $VMTEST_KERNEL (vng will fetch it)" ;;
    *)  [ -f "/usr/lib/modules/$VMTEST_KERNEL/vmlinuz" ] ||
        [ -f "/boot/vmlinuz-$VMTEST_KERNEL" ] ||
            vt_die "VMTEST_KERNEL='$VMTEST_KERNEL' is not a built kernel tree, a kernel image, or an installed release"
        vt_log "kernel: installed release $VMTEST_KERNEL$([ "$VMTEST_KERNEL" = "$(uname -r)" ] && echo ' (the running one)')" ;;
    esac
fi

TMPDIR="$VMTEST_DATA_DIR/tmp"
export TMPDIR

# NUMA topology. vng splits -m across the nodes we describe and QEMU
# requires them to sum exactly to it, so compute in MiB; any remainder
# goes to the last node. VMTEST_NUMA_NODES=1 leaves a flat guest.
NUMA_ARGS=()
case "$VMTEST_NUMA_NODES" in
''|*[!0-9]*|0) vt_die "VMTEST_NUMA_NODES must be a positive integer (got '$VMTEST_NUMA_NODES')" ;;
esac
if [ "$VMTEST_NUMA_NODES" -gt 1 ]; then
    case "$VMTEST_MEM" in
    *[Gg]) mem_mb=$(( ${VMTEST_MEM%[Gg]} * 1024 )) ;;
    *[Mm]) mem_mb=${VMTEST_MEM%[Mm]} ;;
    *)     mem_mb=$VMTEST_MEM ;;          # bare = MiB (QEMU default)
    esac
    case "$mem_mb" in
    ''|*[!0-9]*) vt_die "cannot split VMTEST_MEM='$VMTEST_MEM' across NUMA nodes" ;;
    esac
    [ "$VMTEST_CPUS" -ge "$VMTEST_NUMA_NODES" ] ||
        vt_die "VMTEST_NUMA_NODES=$VMTEST_NUMA_NODES needs at least that many CPUs (VMTEST_CPUS=$VMTEST_CPUS)"
    mem_per=$(( mem_mb / VMTEST_NUMA_NODES ))
    [ "$mem_per" -ge 1 ] || vt_die "VMTEST_MEM=$VMTEST_MEM too small for $VMTEST_NUMA_NODES NUMA nodes"
    cpu_per=$(( VMTEST_CPUS / VMTEST_NUMA_NODES ))
    cpu_lo=0
    for (( node = 0; node < VMTEST_NUMA_NODES; node++ )); do
        if (( node == VMTEST_NUMA_NODES - 1 )); then
            node_mem=$(( mem_mb - mem_per * node ))
            cpu_hi=$(( VMTEST_CPUS - 1 ))
        else
            node_mem=$mem_per
            cpu_hi=$(( cpu_lo + cpu_per - 1 ))
        fi
        NUMA_ARGS+=(--numa "${node_mem}M,cpus=${cpu_lo}-${cpu_hi}")
        cpu_lo=$(( cpu_hi + 1 ))
    done
    vt_log "NUMA: $VMTEST_NUMA_NODES nodes, ~${mem_per}M + ~${cpu_per} cpus each (guest needs CONFIG_NUMA=y)"
fi

# Networking. User-mode (SLIRP) needs no host setup and no root: the guest
# gets a DHCP address and reaches host services at the gateway, so a target
# bound on the host's 127.0.0.1:PORT is 10.0.2.2:PORT inside. NET2 adds a
# second interface on its own subnet for the two-NIC tests.
NET_ARGS=()
if [ -n "$VMTEST_NET" ] && [ "$VMTEST_NET" != 0 ]; then
    NET_ARGS+=(--network user)
    [ -n "$VMTEST_NET2" ] && [ "$VMTEST_NET2" != 0 ] && NET_ARGS+=(--network user)
fi

# Shares. The data dir is always mounted (the marker files live in its
# tmp/); VMTEST_RWDIR adds any others, as raw vng specs.
RWDIR_ARGS=(--rwdir "$VMTEST_DATA_DIR")
for d in $VMTEST_RWDIR; do
    RWDIR_ARGS+=(--rwdir "$d")
done

# Env the guest scripts want. VMTEST_DATA_DIR is the important one: it is
# how a test finds the marker directory and where it writes anything that
# must survive the VM. Guest scripts source vt.sh relative
# to themselves, so nothing has to point back at this checkout.
GUEST_ENV="VMTEST_DATA_DIR=$VMTEST_DATA_DIR"

# A guest PATH including any cargo-installed bin dirs on the host: /home is
# exposed into the guest, so those paths resolve at the same absolute
# location inside. The glob expands here, before vng runs; missing
# directories drop out.
GUEST_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
for d in /home/*/.cargo/bin /root/.cargo/bin; do
    [ -d "$d" ] && GUEST_PATH="$d:$GUEST_PATH"
done

# --- confidentiality mask (VMTEST_MASK=0 to disable) -----------------------
# The guest rootfs is the HOST filesystem over 9p, served by qemu with the
# invoking user's credentials — including $HOME/.ssh (private keys!). Launch
# the vng/qemu chain inside an unprivileged user+mount namespace where
# $HOME/.ssh is overmounted with an empty directory, so the 9p server cannot
# serve the real one (this also holds against guest-side remounts — the mask
# lives on the host side of 9p). Deliberately MINIMAL: only .ssh is masked;
# /etc root-only secrets (shadow, sudoers, key material) are unreadable
# through 9p anyway since qemu runs with this user's credentials.
MASK_WRAP=()
# No mask in interactive shell mode: vng starts the shell through the guest's
# su BEFORE the prelude can run its nosuid pass, and under the mask su is
# setuid-nobody ("su: cannot set groups"). Shell mode is the user at the
# console, not unattended test code, so run it unmasked.
if [ "${VMTEST_MASK:-1}" = 1 ] && [ -z "$SHELL_MODE" ]; then
    if unshare --map-root-user --mount true 2>/dev/null && [ -d "$HOME/.ssh" ]; then
        MASK_EMPTY_DIR="$TMPDIR/vmtest-empty.d"
        mkdir -p "$MASK_EMPTY_DIR"
        export VMTEST_MASK_EMPTY_DIR="$MASK_EMPTY_DIR"
        VMTEST_MASK_UID="$(id -u)"
        VMTEST_MASK_GID="$(id -g)"
        export VMTEST_MASK_UID VMTEST_MASK_GID
        # Nested namespaces: the OUTER map-root-user pass does the bind
        # (mount(8) refuses with a non-zero euid), then the INNER unshare
        # maps back to the invoking uid/gid before exec'ing vng — so qemu
        # and the guest see exactly the uid view of an unmasked run (a
        # fake-root euid confuses vng and breaks guest mounts).
        # shellcheck disable=SC2016  # the inner script expands in the namespace
        MASK_WRAP=(unshare --map-root-user --mount bash -c '
            set -e
            mount --bind "$VMTEST_MASK_EMPTY_DIR" "$HOME/.ssh"
            exec unshare --map-user="$VMTEST_MASK_UID" \
                --map-group="$VMTEST_MASK_GID" "$@"' vmtest-mask)
        vt_log "mask: \$HOME/.ssh hidden from the guest (VMTEST_MASK=0 disables)"
    else
        vt_log "VMTEST_MASK: user namespaces unavailable (or no ~/.ssh); running unmasked"
    fi
fi

# Guest prelude: normalize the guest before the test (or shell) runs.
#
# 1) With VMTEST_MASK, qemu runs in an unprivileged user namespace where
#    host-root-owned files appear as nobody over 9p — including the SETUID
#    bits on mount/umount/su, which then switch to euid nobody and refuse to
#    work ("mount: must be superuser"). Remount every guest mount nosuid via
#    raw mount(2) (python, since mount(8) is one of the broken tools): setuid
#    bits are then ignored and the tools run with the caller's identity —
#    always root in this guest. Tests needing real setuid semantics use the
#    TEST/SCRATCH devices, whose fresh mounts stay suid-capable.
#
# 2) virtme-ng-init bind-mounts generated config FILES (fstab, hosts, shadow,
#    sudoers, resolv.conf stubs) over the guest /etc; tools that walk the
#    mount table choke on a file mountpoint — the quota tools spew
#    "repquota: Unable to get a filedescriptor from mountpoint: /etc/fstab",
#    polluting six xfstests quota tests' golden output. Replace each file
#    bind-mount with a plain copy of the SAME content in the overlay upper,
#    then unmount (looping for stacked binds).
#
# 3) The guest env advertises XDG_RUNTIME_DIR but its creation depends on
#    boot details; tests bind sockets under it, so guarantee it exists.
#
# 4) virtme-ng-init configures the NICs it finds under
#    /sys/bus/virtio/drivers/virtio_net/ BEFORE it runs udev coldplug, and
#    never looks again. With virtio_net built as a module -- distribution
#    kernels: Fedora and Ubuntu both ship CONFIG_VIRTIO_NET=m -- the device
#    can appear only after coldplug loads the module, and then no DHCP ever
#    runs for it: the guest boots with no usable netdev and every test that
#    reaches 10.0.2.2 fails. A dev tree with =y never shows this. Configure
#    any NIC still without an address. User-mode networking is the only
#    kind this runner sets up, and SLIRP hands out exactly 10.0.2.15/24 via
#    10.0.2.2 every time, so a static assignment is what DHCP would have
#    done. Only when the guest has networking at all (virtme.dhcp on the
PRELUDE="$TMPDIR/vmtest-prelude.sh"
# The nosuid pass is ONLY needed (and only applied) when the mask is active:
# without the user namespace, setuid binaries work normally and the guest
# should stay byte-for-byte identical to the unmasked world.
if [ ${#MASK_WRAP[@]} -gt 0 ]; then MASK_ON=1; else MASK_ON=0; fi
cat > "$PRELUDE" <<PRELUDE_HEAD
#!/bin/bash
# Generated by runner.sh; runs as root inside the guest before the test.
export VMTEST_MASK_ON=$MASK_ON
PRELUDE_HEAD
cat >> "$PRELUDE" <<'PRELUDE_BODY'
[ -n "${XDG_RUNTIME_DIR:-}" ] && mkdir -p "$XDG_RUNTIME_DIR"
python3 - <<'PY'
import ctypes, os, shutil

libc = ctypes.CDLL("libc.so.6", use_errno=True)
MS_RDONLY, MS_NOSUID, MS_NODEV, MS_NOEXEC = 0x1, 0x2, 0x4, 0x8
MS_NOATIME, MS_NODIRATIME, MS_RELATIME = 0x400, 0x800, 0x200000
MS_REMOUNT, MS_BIND = 0x20, 0x1000
OPT = {"ro": MS_RDONLY, "nosuid": MS_NOSUID, "nodev": MS_NODEV,
       "noexec": MS_NOEXEC, "noatime": MS_NOATIME,
       "nodiratime": MS_NODIRATIME, "relatime": MS_RELATIME}

def mounts():
    out = []
    with open("/proc/self/mounts", "rb") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 4 and parts[1].startswith(b"/"):
                mnt = parts[1].decode("unicode_escape")
                opts = parts[3].decode()
                out.append((mnt, opts))
    return out

# (2) file bind-mounts -> same-content plain copies.
for mnt, _ in sorted(set(mounts())):
    if not os.path.isfile(mnt):
        continue
    tmp = mnt + ".vmtest-tmp"
    try:
        shutil.copyfile(mnt, tmp)
    except OSError:
        continue
    while libc.umount2(mnt.encode(), 0) == 0:
        pass
    try:
        os.replace(tmp, mnt)
    except OSError:
        os.unlink(tmp)

# (1) nosuid everywhere, preserving each mount's existing flags — but only
# under the mask, where the user namespace turns setuid-root binaries into
# setuid-nobody ones over 9p.
if os.environ.get("VMTEST_MASK_ON") == "1":
    for mnt, opts in mounts():
        flags = MS_REMOUNT | MS_BIND | MS_NOSUID
        for o in opts.split(","):
            flags |= OPT.get(o, 0)
        libc.mount(b"none", mnt.encode(), None, flags, None)
PY

# (4) virtio NICs that appeared after virtme-ng-init's network setup.
if grep -qE '(^| )virtme\.dhcp($| )' /proc/cmdline; then
    modprobe virtio_net 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        ls -d /sys/bus/virtio/drivers/virtio_net/virtio*/net/* >/dev/null 2>&1 && break
        sleep 0.5
    done
    for d in /sys/bus/virtio/drivers/virtio_net/virtio*/net/*; do
        [ -e "$d" ] || continue
        n=$(basename "$d")
        ip -o -4 addr show dev "$n" 2>/dev/null | grep -q inet && continue
        ip link set dev "$n" up
        ip addr add 10.0.2.15/24 dev "$n" 2>/dev/null || true
        ip route add default via 10.0.2.2 dev "$n" 2>/dev/null || true
        echo "vmtest-prelude: $n had no address (virtio_net loaded after init's network setup); configured 10.0.2.15/24"
    done
fi
PRELUDE_BODY
chmod +x "$PRELUDE"

# Mode-specific vng args. Test mode runs the script through --exec with the
# env vng does not otherwise forward. Shell mode boots interactively (so the
# getty owns the console) and carries the same env through a generated
# wrapper; the wrapper lives under the data dir, which is mounted into the
# guest at the same absolute path, so vng can exec it as the login shell.
MODE_ARGS=()
if [ -n "$SHELL_MODE" ]; then
    WRAPPER="$TMPDIR/vmtest-shell.sh"
    {
        echo '#!/bin/bash'
        # %q shell-quotes each value so quotes/spaces/metacharacters in a
        # forwarded path can't break or inject into the wrapper.
        printf 'export PATH=%q\n' "$GUEST_PATH"
        for kv in $GUEST_ENV; do
            printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"
        done
        printf 'export TERM=%q\n' "${TERM:-xterm}"
        printf 'bash %q\n' "$PRELUDE"
        printf 'cd %q 2>/dev/null || true\n' "$TOP"
        echo 'exec bash -i'
    } > "$WRAPPER"
    chmod +x "$WRAPPER"
    MODE_ARGS=(--shell "$WRAPPER")
    vt_log "shell mode: exit the shell (or Ctrl-D) to power off the VM"
else
    MODE_ARGS=(--exec "bash $PRELUDE; env PATH=$GUEST_PATH $GUEST_ENV $TEST_CMD $*")
fi

exec "${MASK_WRAP[@]}" "$VNG" --run "$VMTEST_KERNEL" --force-9p \
    --cpus "$VMTEST_CPUS" --memory "$VMTEST_MEM" \
    --verbose \
    --user root \
    "${RWDIR_ARGS[@]}" \
    "${NUMA_ARGS[@]}" \
    "${NET_ARGS[@]}" \
    --append "systemd.mask=dev-zram0.device systemd.mask=systemd-zram-setup@zram0.service${VMTEST_KCMDLINE_EXTRA:+ $VMTEST_KCMDLINE_EXTRA}" \
    "${MODE_ARGS[@]}" \
    ${VMTEST_QEMU_EXTRA:+"--qemu-opts=$VMTEST_QEMU_EXTRA"}
