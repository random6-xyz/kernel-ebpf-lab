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

TOOLCHAIN_MODE=$(buildroot_toolchain)
TOOLCHAIN_FRAGMENT=$(buildroot_toolchain_fragment)
TOOLCHAIN_PROFILE=$(buildroot_toolchain_profile)
[[ -f "$TOOLCHAIN_FRAGMENT" ]] || die "missing toolchain fragment: $TOOLCHAIN_FRAGMENT"
[[ -n "${BUILDROOT_REF:-}" ]] || die "VERSION.lock does not pin BUILDROOT_REF"

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

# Toolchain backend recorded in an existing Buildroot .config, or empty when
# neither backend is selected.
configured_toolchain() {
    local config=$1

    if grep -q '^BR2_TOOLCHAIN_BUILDROOT=y$' "$config"; then
        printf 'internal\n'
    elif grep -q '^BR2_TOOLCHAIN_EXTERNAL=y$' "$config"; then
        printf 'external\n'
    fi
}

# Switching toolchain backends or profiles in an existing output directory would
# reuse the staging and target trees of the previous C library while Buildroot
# keeps the stamps of every package it already built. Refuse instead of
# producing a rootfs that mixes two toolchains.
previous_mode=""
previous_profile=""
previous_ref=""
if [[ -f "$BUILDROOT_STATE_FILE" ]]; then
    previous_mode=$(sed -n 's/^toolchain_mode=//p' "$BUILDROOT_STATE_FILE")
    previous_profile=$(sed -n 's/^toolchain_profile=//p' "$BUILDROOT_STATE_FILE")
    previous_ref=$(sed -n 's/^buildroot_ref=//p' "$BUILDROOT_STATE_FILE")
elif [[ -f "$BUILDROOT_OUTPUT/.config" ]]; then
    # Output directories created before the state file existed.
    previous_mode=$(configured_toolchain "$BUILDROOT_OUTPUT/.config")
fi

clean_output_hint="Run 'make distclean' (sources/buildroot/dl is kept) and retry."
if [[ -n "$previous_mode" && "$previous_mode" != "$TOOLCHAIN_MODE" ]]; then
    die "$BUILDROOT_OUTPUT was built with the '$previous_mode' toolchain; the '$TOOLCHAIN_MODE' toolchain needs a clean output directory. $clean_output_hint"
fi
if [[ -n "$previous_profile" && "$previous_profile" != "$TOOLCHAIN_PROFILE" ]]; then
    die "$BUILDROOT_OUTPUT was built with toolchain profile '$previous_profile'; this tree selects '$TOOLCHAIN_PROFILE'. $clean_output_hint"
fi
if [[ -n "$previous_ref" && "$previous_ref" != "$BUILDROOT_REF" ]]; then
    warn "$BUILDROOT_OUTPUT was created with Buildroot $previous_ref, this tree pins $BUILDROOT_REF; $clean_output_hint"
fi

if [[ ! -f "$BUILDROOT_OUTPUT/.config" ]]; then
    log "initializing Buildroot qemu_x86_64_defconfig"
    make -C "$BUILDROOT_ROOT" \
        O="$BUILDROOT_OUTPUT" \
        BR2_EXTERNAL="$EXT_ROOT" \
        qemu_x86_64_defconfig
fi

apply_fragment "$BASE_CONFIG" "$BUILDROOT_OUTPUT/.config"
apply_fragment "$TOOLCHAIN_FRAGMENT" "$BUILDROOT_OUTPUT/.config"
set_kconfig BR2_ROOTFS_OVERLAY "\"$EXT_ROOT/board/qemu-x86_64/rootfs-overlay\"" "$BUILDROOT_OUTPUT/.config"
set_kconfig BR2_ROOTFS_POST_BUILD_SCRIPT "\"$EXT_ROOT/board/qemu-x86_64/post-build.sh\"" "$BUILDROOT_OUTPUT/.config"

log "normalizing Buildroot configuration"
make -C "$BUILDROOT_ROOT" \
    O="$BUILDROOT_OUTPUT" \
    BR2_EXTERNAL="$EXT_ROOT" \
    olddefconfig

# The fragments are only a request: Kconfig drops a toolchain profile whose
# dependencies (CPU features, minimum gcc version) are not met, so verify what
# was actually selected before starting a long build.
selected_mode=$(configured_toolchain "$BUILDROOT_OUTPUT/.config")
if [[ "$selected_mode" != "$TOOLCHAIN_MODE" ]]; then
    die "the Buildroot configuration selected the '${selected_mode:-none}' toolchain instead of '$TOOLCHAIN_MODE'; check $TOOLCHAIN_FRAGMENT and the target options"
fi

{
    printf 'buildroot_ref=%s\n' "$BUILDROOT_REF"
    printf 'toolchain_mode=%s\n' "$TOOLCHAIN_MODE"
    printf 'toolchain_profile=%s\n' "$TOOLCHAIN_PROFILE"
    printf 'toolchain_fragment_sha256=%s\n' "$(sha256sum "$TOOLCHAIN_FRAGMENT" | cut -d' ' -f1)"
} > "$BUILDROOT_STATE_FILE"

log "building Buildroot rootfs with the $TOOLCHAIN_MODE toolchain ($TOOLCHAIN_PROFILE)"
export EBPF_LAB_SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY"
export EBPF_LAB_BPF_OBJECT="$BPF_OBJECT"
export EBPF_LAB_BPF_DIR="$ROOT_DIR/out/bpf"
make -C "$BUILDROOT_ROOT" \
    O="$BUILDROOT_OUTPUT" \
    BR2_EXTERNAL="$EXT_ROOT" \
    -j"$(number_of_jobs)"

IMAGE=$(rootfs_image)
ensure_directory "$ARTIFACTS_OUTPUT"
cp -- "$BUILDROOT_OUTPUT/.config" "$ARTIFACTS_OUTPUT/buildroot-qemu-x86_64.config"
printf '%s\n' "$IMAGE" > "$ARTIFACTS_OUTPUT/rootfs-image.path"
write_buildroot_toolchain_manifest "$TOOLCHAIN_MODE" "$TOOLCHAIN_PROFILE"
log "Buildroot image: $IMAGE"
