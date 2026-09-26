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

4. Boot QEMU:

   ```bash
   make run TREE=master
   ```

5. Run the SSH-based smoke test:

   ```bash
   make test TREE=master
   ```

The test image uses Dropbear and a generated key at `out/ssh/lab_ed25519`. The SSH endpoint is `root@127.0.0.1:2222` by default. The guest smoke test probes BPF features with `bpftool` and loads the minimal tracepoint object from `/root/minimal_tracepoint.bpf.o`.

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
