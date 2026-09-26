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
