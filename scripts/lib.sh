#!/usr/bin/env bash

# Common helpers for the eBPF lab scripts.

set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
VERSION_FILE="$ROOT_DIR/VERSION.lock"

if [[ ! -r "$VERSION_FILE" ]]; then
    printf 'missing version file: %s\n' "$VERSION_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$VERSION_FILE"

# Local pahole installations may keep their shared libraries outside the
# system loader path. Make the setting available to kernel and host builds.
if [[ -z "${PAHOLE_LIBDIR:-}" ]]; then
    for candidate in "${HOME:-}/.local/lib" /usr/local/lib; do
        if [[ -r "$candidate/libdwarves.so.1" && -r "$candidate/libdwarves_emit.so.1" ]]; then
            PAHOLE_LIBDIR="$candidate"
            break
        fi
    done
fi
if [[ -n "${PAHOLE_LIBDIR:-}" && -d "$PAHOLE_LIBDIR" ]]; then
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        export LD_LIBRARY_PATH="$PAHOLE_LIBDIR:$LD_LIBRARY_PATH"
    else
        export LD_LIBRARY_PATH="$PAHOLE_LIBDIR"
    fi
fi

# These paths are shared by scripts that source this file.
# shellcheck disable=SC2034
LINUX_ROOT="$ROOT_DIR/sources/linux"
# shellcheck disable=SC2034
BUILDROOT_ROOT="$ROOT_DIR/sources/buildroot"
# shellcheck disable=SC2034
BUILDROOT_OUTPUT="$ROOT_DIR/out/buildroot/qemu-x86_64"
# shellcheck disable=SC2034
BUILDROOT_FRAGMENT_DIR="$ROOT_DIR/configs/buildroot"
# Toolchain identity of BUILDROOT_OUTPUT, used to refuse a toolchain switch on a
# directory that was built with another one.
# shellcheck disable=SC2034
BUILDROOT_STATE_FILE="$BUILDROOT_OUTPUT/.ebpf-lab-buildroot-state"
# shellcheck disable=SC2034
SSH_OUTPUT="$ROOT_DIR/out/ssh"
# shellcheck disable=SC2034
QEMU_OUTPUT="$ROOT_DIR/out/qemu"
# shellcheck disable=SC2034
ARTIFACTS_OUTPUT="$ROOT_DIR/artifacts"

# Diagnostics go to stderr: several helpers are called as $(helper) so that the
# caller can capture the produced path, and any stdout write would corrupt it.
log() {
    printf '[%s] %s\n' "$(basename -- "$0")" "$*" >&2
}

warn() {
    printf '[%s] warning: %s\n' "$(basename -- "$0")" "$*" >&2
}

die() {
    printf '[%s] error: %s\n' "$(basename -- "$0")" "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

number_of_jobs() {
    if [[ -n "${JOBS:-}" ]]; then
        printf '%s\n' "$JOBS"
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
    fi
}

# Buildroot toolchain backend: "external" (prebuilt) or "internal" (built from
# source). Selected by TOOLCHAIN, defaulting to BUILDROOT_TOOLCHAIN_DEFAULT.
buildroot_toolchain() {
    printf '%s\n' "${TOOLCHAIN:-$BUILDROOT_TOOLCHAIN_DEFAULT}"
}

buildroot_toolchain_fragment() {
    case "$(buildroot_toolchain)" in
        external)
            printf '%s\n' "$BUILDROOT_FRAGMENT_DIR/toolchain-external.fragment"
            ;;
        internal)
            printf '%s\n' "$BUILDROOT_FRAGMENT_DIR/toolchain-internal.fragment"
            ;;
        *)
            die "invalid TOOLCHAIN '$(buildroot_toolchain)'; expected external or internal"
            ;;
    esac
}

# Identity of the selected toolchain, recorded in the output directory so that
# changing the profile (for example stable to bleeding-edge) is detected too.
buildroot_toolchain_profile() {
    local fragment
    local profile

    fragment=$(buildroot_toolchain_fragment)
    profile=$(sed -n 's/^\(BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_[A-Z0-9_]*\)=y$/\1/p' "$fragment" 2>/dev/null | head -n 1)
    if [[ -n "$profile" ]]; then
        printf '%s\n' "${profile#BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_}"
    else
        printf '%s\n' "$(buildroot_toolchain)"
    fi
}

validate_tree() {
    case "${1:-}" in
        master|bpf|bpf-next)
            ;;
        *)
            die "invalid Linux tree '$1'; expected master, bpf, or bpf-next"
            ;;
    esac
}

tree_path() {
    validate_tree "$1"
    printf '%s/%s\n' "$LINUX_ROOT" "$1"
}

# Build directory for a Linux tree, optionally suffixed by a debug profile:
# out/kernel/master or out/kernel/master-kasan.
kernel_output_dir() {
    local tree=$1
    local profile=${2:-${DEBUG:-}}
    local output="$ROOT_DIR/out/kernel/$tree"

    if [[ -n "$profile" ]]; then
        output="$output-$profile"
    fi
    printf '%s\n' "$output"
}

kernel_image_path() {
    printf '%s/arch/x86/boot/bzImage\n' "$(kernel_output_dir "$@")"
}

ensure_directory() {
    mkdir -p -- "$1"
}

ensure_ssh_key() {
    ensure_directory "$SSH_OUTPUT"
    local private_key="$SSH_OUTPUT/lab_ed25519"
    local public_key="$SSH_OUTPUT/lab_ed25519.pub"

    require_cmd ssh-keygen

    if [[ ! -s "$private_key" || ! -s "$public_key" ]]; then
        if [[ -e "$private_key" || -e "$public_key" ]]; then
            die "incomplete SSH key pair in $SSH_OUTPUT; remove both files and retry"
        fi
        log "generating QEMU SSH key pair"
        ssh-keygen -q -t ed25519 -N '' -C ebpf-lab -f "$private_key"
        chmod 600 "$private_key"
        chmod 644 "$public_key"
    fi

    # Keep this function's stdout limited to the key path; callers capture it.
    printf '%s\n' "$private_key"
}

rootfs_image() {
    local image
    image=$(find "$BUILDROOT_OUTPUT/images" -maxdepth 1 -type f -name 'rootfs.cpio*' -print -quit 2>/dev/null || true)
    [[ -n "$image" ]] || die "Buildroot rootfs image not found; run make buildroot first"
    printf '%s\n' "$image"
}

write_source_manifest() {
    ensure_directory "$ARTIFACTS_OUTPUT"
    local manifest="$ARTIFACTS_OUTPUT/source-manifest.txt"
    {
        printf '# Generated source manifest\n'
        printf 'generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for tree in master bpf bpf-next; do
            local path
            path=$(tree_path "$tree")
            if [[ -d "$path/.git" || -f "$path/.git" ]]; then
                printf '[%s]\n' "$tree"
                printf 'path=%s\n' "$path"
                printf 'commit=%s\n' "$(git -C "$path" rev-parse HEAD)"
                printf 'branch=%s\n' "$(git -C "$path" symbolic-ref --short -q HEAD || printf 'detached')"
                git -C "$path" remote -v | sort -u | sed 's/^/remote=/'
            fi
        done
    } > "$manifest"
    log "wrote $manifest"
}

write_buildroot_toolchain_manifest() {
    local mode=$1
    local profile=$2
    local manifest="$ARTIFACTS_OUTPUT/buildroot-toolchain.txt"
    local config="$BUILDROOT_OUTPUT/.config"
    local compiler
    local compiler_line=unknown
    local headers
    local ccache_enabled=no
    local ccache_line=disabled

    ensure_directory "$ARTIFACTS_OUTPUT"

    compiler=$(find "$BUILDROOT_OUTPUT/host/bin" -maxdepth 1 -name '*-gcc' ! -name '*-gcc-[0-9]*' -print -quit 2>/dev/null || true)
    if [[ -n "$compiler" ]]; then
        compiler_line=$("$compiler" --version 2>/dev/null | head -n 1 || true)
    fi
    [[ -n "$compiler_line" ]] || compiler_line=unknown

    headers=$(sed -n 's/^BR2_TOOLCHAIN_HEADERS_AT_LEAST_\([0-9]*\)_\([0-9]*\)=y$/\1.\2/p' "$config" | sort -t. -k1,1n -k2,2n | tail -n 1)

    if grep -q '^BR2_CCACHE=y$' "$config"; then
        ccache_enabled=yes
        # Buildroot builds its own patched ccache into the host directory; the
        # system ccache, if any, is not used.
        ccache_line=$("$BUILDROOT_OUTPUT/host/bin/ccache" --version 2>/dev/null | head -n 1 || true)
        [[ -n "$ccache_line" ]] || ccache_line=unknown
    fi

    {
        printf '# Generated Buildroot toolchain manifest\n'
        printf 'generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'buildroot_ref=%s\n' "${BUILDROOT_REF:-unknown}"
        printf 'toolchain_mode=%s\n' "$mode"
        printf 'toolchain_profile=%s\n' "$profile"
        printf 'kernel_headers=%s\n' "${headers:-unknown}"
        printf 'ccache_enabled=%s\n' "$ccache_enabled"
        printf 'ccache_version=%s\n' "$ccache_line"
        printf 'compiler=%s\n' "$compiler_line"
    } > "$manifest"
    log "wrote $manifest"
}
