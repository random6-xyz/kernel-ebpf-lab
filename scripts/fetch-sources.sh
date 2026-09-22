#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

LINUX_SEED=${LINUX_SEED:-$LINUX_SEED_DEFAULT}
BUILDROOT_SEED=${BUILDROOT_SEED:-}
FETCH_REMOTES=${FETCH_REMOTES:-0}
LINUX_MASTER="$LINUX_ROOT/master"

usage() {
    cat <<'EOF'
Usage: fetch-sources.sh [options]

Options:
  --linux-seed PATH       Local Linux repository used for the initial clone.
  --buildroot-seed PATH   Local Buildroot repository used for the initial clone.
  --fetch-remotes         Fetch bpf and bpf-next after local setup.
  -h, --help              Show this help.

The default Linux seed is /home/rand/kernel-server/repo/linux. No network
fetch is performed unless --fetch-remotes is supplied. Buildroot is cloned
from its configured remote unless --buildroot-seed is supplied.
EOF
}

while (($# > 0)); do
    case "$1" in
        --linux-seed)
            (($# >= 2)) || die "--linux-seed requires a path"
            LINUX_SEED=$2
            shift 2
            ;;
        --buildroot-seed)
            (($# >= 2)) || die "--buildroot-seed requires a path"
            BUILDROOT_SEED=$2
            shift 2
            ;;
        --fetch-remotes)
            FETCH_REMOTES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

ensure_remote() {
    local repo=$1
    local name=$2
    local url=$3

    if git -C "$repo" remote get-url "$name" >/dev/null 2>&1; then
        git -C "$repo" remote set-url "$name" "$url"
        git -C "$repo" remote set-url --push "$name" "$url"
    else
        git -C "$repo" remote add "$name" "$url"
    fi
}

ensure_empty_or_absent() {
    local path=$1
    if [[ -e "$path" ]]; then
        if [[ -d "$path" ]] && [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            rmdir -- "$path"
        else
            die "refusing to overwrite non-empty path: $path"
        fi
    fi
}

ensure_linux_worktree() {
    ensure_directory "$LINUX_ROOT"

    if [[ ! -e "$LINUX_MASTER" ]]; then
        [[ -d "$LINUX_SEED" ]] || die "Linux seed directory not found: $LINUX_SEED"
        git -C "$LINUX_SEED" rev-parse --git-dir >/dev/null 2>&1 || die "Linux seed is not a Git repository: $LINUX_SEED"
        log "creating local Linux clone from $LINUX_SEED"
        git clone --local "$LINUX_SEED" "$LINUX_MASTER"
    else
        git -C "$LINUX_MASTER" rev-parse --show-toplevel >/dev/null 2>&1 || die "invalid Linux master worktree: $LINUX_MASTER"
    fi

    # Normalize the two canonical remotes. Remove only the local seed remote
    # created by this script; preserve unrelated operator configuration.
    if git -C "$LINUX_MASTER" remote get-url origin >/dev/null 2>&1 \
        && [[ "$(git -C "$LINUX_MASTER" remote get-url origin)" == "$LINUX_SEED" ]]; then
        if git -C "$LINUX_MASTER" remote get-url bpf-next >/dev/null 2>&1; then
            git -C "$LINUX_MASTER" remote remove origin
        else
            git -C "$LINUX_MASTER" remote rename origin bpf-next
        fi
    fi
    ensure_remote "$LINUX_MASTER" bpf "$LINUX_BPF_REMOTE"
    ensure_remote "$LINUX_MASTER" bpf-next "$LINUX_BPF_NEXT_REMOTE"
    git -C "$LINUX_MASTER" branch --unset-upstream master 2>/dev/null || true

    for tree in bpf bpf-next; do
        local path="$LINUX_ROOT/$tree"
        if [[ -e "$path" ]]; then
            git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1 || die "invalid Linux worktree: $path"
            [[ "$(git -C "$path" branch --show-current)" == "$tree" ]] \
                || die "$path is not checked out on branch $tree"
            continue
        fi

        if ! git -C "$LINUX_MASTER" show-ref --verify --quiet "refs/heads/$tree" \
            && ! git -C "$LINUX_MASTER" show-ref --verify --quiet "refs/remotes/bpf-next/$tree" \
            && git -C "$LINUX_SEED" show-ref --verify --quiet "refs/heads/$tree"; then
            seed_commit=$(git -C "$LINUX_SEED" rev-parse "refs/heads/$tree")
            git -C "$LINUX_MASTER" branch "$tree" "$seed_commit"
        fi

        if git -C "$LINUX_MASTER" show-ref --verify --quiet "refs/heads/$tree"; then
            git -C "$LINUX_MASTER" -c branch.autoSetupMerge=false worktree add -B "$tree" "$path" "refs/heads/$tree"
        elif git -C "$LINUX_MASTER" show-ref --verify --quiet "refs/remotes/bpf-next/$tree"; then
            git -C "$LINUX_MASTER" worktree add --no-track -b "$tree" "$path" "refs/remotes/bpf-next/$tree"
        else
            die "branch '$tree' is not available in the local Linux seed"
        fi
    done

    for child in "$LINUX_ROOT"/*; do
        [[ -e "$child" ]] || continue
        case "$(basename -- "$child")" in
            master|bpf|bpf-next)
                ;;
            *)
                die "unexpected Linux source directory: $child; only master, bpf, and bpf-next are allowed"
                ;;
        esac
    done

    if [[ "$FETCH_REMOTES" == 1 ]]; then
        log "fetching bpf and bpf-next remotes"
        git -C "$LINUX_MASTER" fetch --prune bpf
        git -C "$LINUX_MASTER" fetch --prune bpf-next
    fi
}

ensure_buildroot_source() {
    local created=0

    if [[ ! -e "$BUILDROOT_ROOT" ]]; then
        if [[ -n "$BUILDROOT_SEED" ]]; then
            [[ -d "$BUILDROOT_SEED" ]] || die "Buildroot seed directory not found: $BUILDROOT_SEED"
            git -C "$BUILDROOT_SEED" rev-parse --git-dir >/dev/null 2>&1 || die "Buildroot seed is not a Git repository: $BUILDROOT_SEED"
            log "creating local Buildroot clone from $BUILDROOT_SEED"
            git clone --local "$BUILDROOT_SEED" "$BUILDROOT_ROOT"
        else
            log "cloning Buildroot $BUILDROOT_REF"
            git clone --depth 1 --branch "$BUILDROOT_REF" "$BUILDROOT_REMOTE" "$BUILDROOT_ROOT"
        fi
        created=1
    fi

    git -C "$BUILDROOT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || die "invalid Buildroot repository: $BUILDROOT_ROOT"
    ensure_remote "$BUILDROOT_ROOT" origin "$BUILDROOT_REMOTE"
    requested_commit=$(git -C "$BUILDROOT_ROOT" rev-parse --verify "$BUILDROOT_REF^{commit}" 2>/dev/null) \
        || die "Buildroot ref '$BUILDROOT_REF' is not available in $BUILDROOT_ROOT"

    if (( created )); then
        git -C "$BUILDROOT_ROOT" checkout --detach "$requested_commit" >/dev/null
    elif [[ "$(git -C "$BUILDROOT_ROOT" rev-parse HEAD)" != "$requested_commit" ]]; then
        die "Buildroot HEAD is not $BUILDROOT_REF; checkout the locked ref or remove $BUILDROOT_ROOT"
    fi
    log "Buildroot HEAD: $(git -C "$BUILDROOT_ROOT" rev-parse HEAD)"
}

ensure_linux_worktree
ensure_buildroot_source
write_source_manifest
log "source setup complete"
