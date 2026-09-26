#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR=${1:?Buildroot did not provide TARGET_DIR}
PUBLIC_KEY=${EBPF_LAB_SSH_PUBLIC_KEY:-}

if [[ -z "$PUBLIC_KEY" || ! -r "$PUBLIC_KEY" ]]; then
    printf 'EBPF_LAB_SSH_PUBLIC_KEY must point to a readable public key\n' >&2
    exit 1
fi

install -d -m 0700 "$TARGET_DIR/root/.ssh"
install -m 0600 "$PUBLIC_KEY" "$TARGET_DIR/root/.ssh/authorized_keys"

# Make the SSH login deterministic for the local QEMU lab.
install -d -m 0755 "$TARGET_DIR/var/log"

# Buildroot 2025.02 links bpftool through libbfd/libopcodes, which in turn
# require libsframe, but does not install libsframe into the target image.
# Copy the ABI library from staging so bpftool works inside the guest.
if [[ ! -r "$TARGET_DIR/usr/lib/libsframe.so.1" ]]; then
    libsframe=""
    if [[ -n "${STAGING_DIR:-}" && -r "$STAGING_DIR/usr/lib/libsframe.so.1" ]]; then
        libsframe="$STAGING_DIR/usr/lib/libsframe.so.1"
    else
        for candidate in "${BUILD_DIR:-}"/binutils-*/libsframe/.libs/libsframe.so.1; do
            if [[ -r "$candidate" ]]; then
                libsframe="$candidate"
                break
            fi
        done
    fi
    [[ -n "$libsframe" ]] || {
        printf 'unable to locate libsframe.so.1 required by bpftool\n' >&2
        exit 1
    }
    install -D -m 0755 "$libsframe" "$TARGET_DIR/usr/lib/libsframe.so.1"
fi

# Every built case is shipped so that a booted guest can be inspected without a
# host round trip. The verifier collector transfers cases over SSH instead, so
# new cases do not require rebuilding this root filesystem.
BPF_DIR=${EBPF_LAB_BPF_DIR:-}
if [[ -n "$BPF_DIR" ]]; then
    [[ -d "$BPF_DIR" ]] || {
        printf 'EBPF_LAB_BPF_DIR is not a directory: %s\n' "$BPF_DIR" >&2
        exit 1
    }
    install -d -m 0755 "$TARGET_DIR/root/lab-bpf"
    for object in "$BPF_DIR"/*.bpf.o; do
        [[ -e "$object" ]] || continue
        install -m 0644 "$object" "$TARGET_DIR/root/lab-bpf/"
    done
fi

BPF_OBJECT=${EBPF_LAB_BPF_OBJECT:-}
if [[ -z "$BPF_OBJECT" || ! -r "$BPF_OBJECT" ]]; then
    printf 'EBPF_LAB_BPF_OBJECT must point to a readable BPF object\n' >&2
    exit 1
fi
install -D -m 0644 "$BPF_OBJECT" "$TARGET_DIR/root/minimal_tracepoint.bpf.o"
