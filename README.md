# eBPF kernel lab

This repository contains a reproducible Buildroot and QEMU environment for preparing eBPF kernel patches.

## Linux source policy

The lab creates exactly three Linux worktrees:

- `master`: the selected baseline
- `bpf`: the bpf tree
- `bpf-next`: the bpf-next tree

The initial Linux clone is local and uses `/home/rand/kernel-server/repo/linux` by default. The setup script then configures the canonical kernel.org remotes. It does not fetch over the network unless explicitly requested.

The existing `dev`, `test-dev`, and stale temporary worktrees are not copied into this lab.

## Quick start

1. Check host tools:

   ```bash
   make check-host
   ```

2. Create the Linux worktrees and obtain Buildroot:

   ```bash
   make fetch
   ```

   If Buildroot is already available locally, use:

   ```bash
   BUILDROOT_SEED=/path/to/buildroot make fetch
   ```

3. Build the root filesystem and a kernel:

   ```bash
   make image TREE=master
   ```

   The root filesystem uses the prebuilt Bootlin toolchain by default, so a cold
   build does not compile a cross toolchain. See
   [Buildroot toolchain](#buildroot-toolchain) for the available knobs.

4. Boot QEMU:

   ```bash
   make run TREE=master
   ```

5. Run the SSH-based smoke test:

   ```bash
   make test TREE=master
   ```

The test image uses Dropbear and a generated key at `out/ssh/lab_ed25519`. The SSH endpoint is `root@127.0.0.1:2222` by default. The guest smoke test probes BPF features with `bpftool` and loads the minimal tracepoint object from `/root/minimal_tracepoint.bpf.o`.

## Buildroot toolchain

The root filesystem is built with the prebuilt Bootlin toolchain profile
`BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_X86_64_GLIBC_STABLE` (x86-64, glibc, gcc 13.3.0,
kernel headers 4.19.315). Buildroot downloads the tarball once into
`sources/buildroot/dl/toolchain-external-bootlin` and verifies the sha256 that the
pinned Buildroot tree records for it, so `make distclean` keeps the download and
a later cold build does not fetch it again.

Building the cross toolchain from source is the single most expensive part of a
cold build, and the lab does not need it: the kernel is built outside Buildroot
and the guest userspace only contains busybox, Dropbear, libbpf and bpftool. On a
12-core host the difference is large:

| Variant | Toolchain | ccache | Cold build |
|---|---|---|---|
| Internal (previous default) | built from source | off | 15m23s |
| External (default) | prebuilt Bootlin | off | 4m10s |
| External (default) | prebuilt Bootlin | on, first build | 5m26s |
| External (default) | prebuilt Bootlin | on, warm cache | 3m36s |

Cold build means `out/buildroot` was removed first. These numbers come from one
12-core host and scale with the machine; they are wall clock, and the host was
idle for every run.

`ccache` is enabled by default. Buildroot builds its own copy under
`out/buildroot/qemu-x86_64/host/bin/ccache`, so no host package is required, and
cached objects live in `$HOME/.buildroot-ccache`, which survives
`make distclean`. The first build with an empty cache is slower than without
ccache (about a minute, mostly the `host-ccache` package and cache misses); every
cold build after that is faster, which is the case the lab actually hits when it
rebuilds the root filesystem from scratch. Use `CCACHE=0` if you build once and
never again.

### Selecting the toolchain

```bash
make buildroot                     # prebuilt Bootlin toolchain (default)
make buildroot TOOLCHAIN=internal  # build the cross toolchain from source
make buildroot CCACHE=0            # disable ccache
```

The default is set by `BUILDROOT_TOOLCHAIN_DEFAULT` in `VERSION.lock`; the two
backend configurations live in `configs/buildroot/toolchain-external.fragment`
and `configs/buildroot/toolchain-internal.fragment`.

Switching toolchain backend or profile inside an existing `out/buildroot` is
refused, because the already-built packages and the previous C library would be
mixed:

```
[build-buildroot.sh] error: .../out/buildroot/qemu-x86_64 was built with the
'internal' toolchain; the 'external' toolchain needs a clean output directory.
Run 'make distclean' (sources/buildroot/dl is kept) and retry.
```

Run `make distclean` and build again to switch. The download cache and the ccache
cache are both preserved.

### Offline and CI use

The toolchain tarball is fetched from `toolchains.bootlin.com` on the first
build. To build without network access, point Buildroot at an already extracted
toolchain instead: unpack
`sources/buildroot/dl/toolchain-external-bootlin/x86-64--glibc--stable-2024.05-1.tar.xz`
somewhere permanent and add this to
`configs/buildroot/toolchain-external.fragment`:

```
# BR2_TOOLCHAIN_EXTERNAL_DOWNLOAD is not set
BR2_TOOLCHAIN_EXTERNAL_PREINSTALLED=y
BR2_TOOLCHAIN_EXTERNAL_PATH="/path/to/x86-64--glibc--stable-2024.05-1"
```

### Moving to newer kernel headers

The pinned profile ships kernel headers 4.19, so packages that require newer
headers cannot be enabled while it is selected. `make check-host` and the build
itself report such a case as a missing dependency. If a package needs newer
headers, either use `TOOLCHAIN=internal` (kernel headers follow the Linux tree)
or bump the profile to a newer Bootlin release and re-verify the guest.

### Patches carried by the external tree

`buildroot-external/patches` is part of `BR2_GLOBAL_PATCH_DIR` and holds the
fixes this Buildroot release still needs. One example is the bpftool v7.1.0
quoting bug (`CC=$(HOSTCC)`) that breaks the libbpf bootstrap build when ccache
is enabled; it carries the upstream fix (bpftool commit `09cbdb1`).

## Verifier response collection

Collect the verifier's own response for every case in `tests/bpf`:

```bash
make image TREE=master      # once: kernel and root filesystem
make verifier TREE=master   # boot QEMU, transfer cases, collect reports
```

`make verifier` boots the guest, pushes each `out/bpf/*.bpf.o` over SSH, and runs
`ebpf-lab-verifier` inside the guest. Because cases travel over SSH, adding or
changing a case does not require rebuilding the root filesystem.

### Case convention

Each `tests/bpf/<name>.c` is a case and is compiled to `out/bpf/<name>.bpf.o`.
An optional sidecar `tests/bpf/<name>.expect` declares the expected outcome:

```
accept              # default: the program must load
reject              # the verifier must reject the program
type=tracepoint     # optional bpftool program type
```

### How the verifier log is obtained

`ebpf-lab-verifier` runs `bpftool -d prog load`, which makes bpftool request
kernel verifier logging, so the log is captured for rejected loads as well as
successful ones. The flag is probed at runtime and a plain `bpftool prog load` is
used when the installed bpftool does not support it; libbpf still asks for the
log after a failed attempt.

The kernel only formats verifier messages into a log buffer when a log level is
requested, so dmesg is recorded as surrounding kernel context and is not a
verifier log source.

### Outputs

- `artifacts/verifier/<tree>/<program>.log`: full verifier report for one case
- `artifacts/verifier/<tree>/summary.txt`: tree, guest kernel, source commit, and one line per case
- `artifacts/qemu-<tree>-<port>.serial.log`: console log of the run

`make verifier` exits non-zero when a case does not match its expectation.

Another lab instance may already hold the default SSH port. Select a free one with
`SSH_PORT`:

```bash
make verifier TREE=master SSH_PORT=2225
```

## Source setup

The source script accepts these optional variables:

- `LINUX_SEED`: local Linux repository used as the clone source
- `BUILDROOT_SEED`: local Buildroot repository used as the clone source
- `FETCH_REMOTES=1`: explicitly fetch the configured Linux remotes after setup

Example:

```bash
LINUX_SEED=/home/rand/kernel-server/repo/linux \
BUILDROOT_SEED=/path/to/buildroot \
make fetch
```

## Generated paths

- `sources/linux/{master,bpf,bpf-next}`: Linux worktrees
- `sources/linux/<tree>/compile_commands.json`: symlink to that tree's generated compile database
- `sources/buildroot`: Buildroot source
- `out/kernel/<tree>`: per-worktree kernel output, including `compile_commands.json`
- `out/buildroot/qemu-x86_64`: Buildroot output
- `out/bpf/*.bpf.o`: compiled `tests/bpf` cases
- `out/ssh`: the local QEMU SSH key pair
- `out/qemu`: QEMU pid files and serial logs
- `artifacts`: generated source and build manifests, plus collected verifier reports
- `lab`: user directory

Each successful `make kernel TREE=<tree>` generates a compile database from the existing kernel build and exposes it at the selected Linux worktree root. To regenerate it without rebuilding the kernel, run:

```bash
make compile-commands TREE=master
```

This target requires a completed kernel build for the selected tree. `make clean` removes the generated source-root symlink along with the kernel build output.

No command in the setup scripts uses `sudo`. Missing host packages are reported by `check-host.sh` for the operator to install.
