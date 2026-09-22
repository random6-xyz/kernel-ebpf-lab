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
- `sources/buildroot`: Buildroot source
- `out/kernel/<tree>`: per-worktree kernel output
- `out/buildroot/qemu-x86_64`: Buildroot output
- `out/bpf/minimal_tracepoint.bpf.o`: minimal BPF smoke object
- `out/ssh`: the local QEMU SSH key pair
- `out/qemu`: QEMU pid files and serial logs
- `artifacts`: generated source and build manifests
- `lab`: user directory

No command in the setup scripts uses `sudo`. Missing host packages are reported by `check-host.sh` for the operator to install.
