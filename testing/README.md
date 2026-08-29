# VM testing

The VM tests need only [virtme-ng](https://github.com/arighi/virtme-ng)
(`vng`) on `PATH`; everything else ships with this checkout, so a fresh
clone runs the acceptance matrix with nothing else to install or set up.

The idea: no disk image. The guest boots a kernel — by default the one
the host is running — and mounts the host filesystem over 9p, so the
repo, the binaries you just built, and the test script itself are all
reachable at their real paths. A test is just a root shell script running
against your working tree in a throwaway VM. NVMe/TCP tests connect to a
target on the host at `10.0.2.2`; the RDMA and affinity tests start
theirs inside the guest.

## Running

```sh
# the M4-M8 interop matrix (discover/connect, fio --verify, filesystem)
testing/run_interop.sh
testing/run_interop.sh ioutgt_fio      # just one stage

# one guest test: build ioutgt, start it on the host, boot the guest, tear down
testing/run_vmtest.sh testing/vmtest/ioutgt_tbkas.sh

# every test in a directory, each in its own VM, with a pass/fail summary
testing/run_vmtest.sh testing/vmtest/

# multi-NUMA guest: spread_cpus IO-thread placement
testing/run_affinity.sh

# xfstests (./check -g quick) over both transports, ioutgt or nvmet
testing/ioutgt_xfstests.sh

# a root shell in the guest instead of a test, for post-mortem poking
testing/common/runner.sh --shell
```

A test exits **0** for pass, **4** for skip (a prerequisite the guest
lacks), and anything else for failure. A directory sweep reports the
three separately, so a box missing an optional dependency does not read
as broken.

## Layout

| Path | Role |
|------|------|
| `common/runner.sh` | host side: boots the VM under `vng` and runs one guest script in it |
| `common/vt.sh` | guest side: the library every test sources — logging, cleanup stack, requirement checks, the exit-code contract |
| `common/vmtest.sh` | this project's config — what ioutgt overrides in the runner's defaults |
| `vmtest/*.sh` | the guest tests |
| `run_*.sh` | host-side runners: build, start a target, publish markers, launch |

Host↔guest signalling goes through marker files under
`$VMTEST_DATA_DIR/tmp`, not the environment — env does not cross into a
VM.

## Knobs

Every setting has a default and can be overridden per run:

| Variable | Meaning |
|----------|---------|
| `VMTEST_KERNEL` | kernel to boot, in any form `vng --run` takes (default: the running kernel) |
| `VMTEST_NUMA_NODES` | guest NUMA nodes (4 here, so the affinity test has something to check) |
| `VMTEST_RWDIR` | extra host directories to share read-write |
| `VMTEST_GUEST_ENV` | extra `NAME=VALUE` pairs to forward into the guest |
| `VMTEST_CPUS`, `VMTEST_MEM` | guest sizing (16, 8G) |
| `VMTEST_NET`, `VMTEST_NET2` | user-mode NICs (both on; NET2 serves the two-NIC tests) |
| `VMTEST_MASK=0` | stop hiding `$HOME/.ssh` from the guest |

`VMTEST_KERNEL` defaults to the distribution kernel the host is running,
which needs no source tree and no build. To test a kernel under
development, name it — a built tree, a kernel image, an installed
release, or an upstream tag `vng` downloads:

```sh
VMTEST_KERNEL=~/git/linux-next testing/run_interop.sh
VMTEST_KERNEL=v6.6.17 testing/run_vmtest.sh testing/vmtest/ioutgt_fio.sh
```

The runner logs which kernel it booted and how it resolved it, so a run's
kernel never has to be guessed from its output.

`VMTEST_RWDIR` takes raw `vng --rwdir` specs (a bare path, or
`guestpath=hostpath`), which is how you keep backing images off 9p:

```sh
VMTEST_RWDIR=/mnt/nvme testing/ioutgt_xfstests.sh
```

The guest rootfs is your host filesystem, so `$HOME/.ssh` is masked out
of it by default — an unprivileged user+mount namespace overmounts it
before qemu starts, which holds even against a remount inside the guest.

## Reusing it elsewhere

`common/runner.sh` and `common/vt.sh` know nothing about ioutgt — copy
the two files into another project, side by side, and they work as they
are. The only dependency is `vng` (`unshare` is optional and its absence
is survived; `python3` is vng's own runtime, so it is never an extra
install). The project supplies its own guest tests, which source `vt.sh`
relative to themselves, and
optionally a config file of `VAR="${VAR:-default}"` lines — `vmtest.sh`
beside the runner, or whatever `VMTEST_CONFIG` names. With no config at
all it boots the running kernel into a flat single-node guest.
`VMTEST_GUEST_ENV` is how a project passes its own paths inward without
patching the runner.
