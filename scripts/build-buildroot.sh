#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

require_cmd make
[[ -d "$BUILDROOT_ROOT" ]] || die "Buildroot source is missing; run make fetch first"
[[ -f "$BUILDROOT_ROOT/Makefile" ]] || die "invalid Buildroot source tree: $BUILDROOT_ROOT"

EXT_ROOT="$ROOT_DIR/buildroot-external"
BASE_CONFIG="$ROOT_DIR/configs/buildroot/qemu_x86_64_defconfig"
[[ -f "$BASE_CONFIG" ]] || die "missing Buildroot configuration fragment: $BASE_CONFIG"

SSH_PRIVATE_KEY=$(ensure_ssh_key)
SSH_PUBLIC_KEY="$SSH_PRIVATE_KEY.pub"
BPF_OBJECT="$ROOT_DIR/out/bpf/minimal_tracepoint.bpf.o"
if [[ ! -f "$BPF_OBJECT" ]]; then
    "$ROOT_DIR/scripts/build-bpf-test.sh"
fi
ensure_directory "$BUILDROOT_OUTPUT"

set_kconfig() {
    local key=$1
    local value=$2
    local config=$3
    local tmp

    tmp=$(mktemp)
    awk -v key="$key" '
        $0 == "# " key " is not set" { next }
        index($0, key "=") == 1 { next }
        { print }
    ' "$config" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv -- "$tmp" "$config"
}

apply_fragment() {
    local fragment=$1
    local config=$2
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^#\ (BR2_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
            set_kconfig "${BASH_REMATCH[1]}" n "$config"
            continue
        fi
        [[ "$line" =~ ^BR2_[A-Za-z0-9_]+= ]] || continue
        key=${line%%=*}
        value=${line#*=}
        set_kconfig "$key" "$value" "$config"
    done < "$fragment"
}

if [[ ! -f "$BUILDROOT_OUTPUT/.config" ]]; then
    log "initializing Buildroot qemu_x86_64_defconfig"
    make -C "$BUILDROOT_ROOT" \
        O="$BUILDROOT_OUTPUT" \
        BR2_EXTERNAL="$EXT_ROOT" \
        qemu_x86_64_defconfig
fi

apply_fragment "$BASE_CONFIG" "$BUILDROOT_OUTPUT/.config"
set_kconfig BR2_ROOTFS_OVERLAY "\"$EXT_ROOT/board/qemu-x86_64/rootfs-overlay\"" "$BUILDROOT_OUTPUT/.config"
set_kconfig BR2_ROOTFS_POST_BUILD_SCRIPT "\"$EXT_ROOT/board/qemu-x86_64/post-build.sh\"" "$BUILDROOT_OUTPUT/.config"

log "normalizing Buildroot configuration"
make -C "$BUILDROOT_ROOT" \
    O="$BUILDROOT_OUTPUT" \
    BR2_EXTERNAL="$EXT_ROOT" \
    olddefconfig

log "building Buildroot rootfs"
export EBPF_LAB_SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY"
export EBPF_LAB_BPF_OBJECT="$BPF_OBJECT"
make -C "$BUILDROOT_ROOT" \
    O="$BUILDROOT_OUTPUT" \
    BR2_EXTERNAL="$EXT_ROOT" \
    -j"$(number_of_jobs)"

IMAGE=$(rootfs_image)
ensure_directory "$ARTIFACTS_OUTPUT"
cp -- "$BUILDROOT_OUTPUT/.config" "$ARTIFACTS_OUTPUT/buildroot-qemu-x86_64.config"
printf '%s\n' "$IMAGE" > "$ARTIFACTS_OUTPUT/rootfs-image.path"
log "Buildroot image: $IMAGE"
