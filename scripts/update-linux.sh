#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

FETCH_ONLY=0

usage() {
    cat <<'EOF'
Usage: update-linux.sh [--fetch-only] [-h|--help]

Fetch the configured bpf and bpf-next remotes, then rebase the local master,
bpf, and bpf-next branches onto their upstream branches. Every worktree must
be clean and checked out on its corresponding branch; local changes are never
stashed, discarded, or pushed.

Options:
  --fetch-only  Fetch both remotes without rebasing any worktree.
  -h, --help    Show this help.

Upstream selection defaults:
  bpf       bpf/master, then bpf/bpf, then bpf-next/bpf
  bpf-next  bpf-next/bpf-next, then bpf-next/master
  master    bpf-next/master

Set BPF_UPSTREAM, BPF_NEXT_UPSTREAM, or MASTER_UPSTREAM to override a target
with a remote-tracking ref such as bpf-next/master.
EOF
}

while (($# > 0)); do
    case "$1" in
        --fetch-only)
            FETCH_ONLY=1
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

require_cmd git

COMMON_REPO="$LINUX_ROOT/master"
[[ -d "$COMMON_REPO" ]] || die "Linux master worktree not found: $COMMON_REPO"
git -C "$COMMON_REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a Git worktree: $COMMON_REPO"

for remote in bpf bpf-next; do
    git -C "$COMMON_REPO" remote get-url "$remote" >/dev/null 2>&1 \
        || die "required Git remote is not configured: $remote"
done

preflight_worktree() {
    local tree=$1
    local path="$LINUX_ROOT/$tree"
    local branch
    local status

    [[ -d "$path" ]] || die "Linux $tree worktree not found: $path"
    git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1 \
        || die "not a Git worktree: $path"

    branch=$(git -C "$path" branch --show-current)
    [[ "$branch" == "$tree" ]] \
        || die "$path is checked out on '$branch', expected '$tree'"

    status=$(git -C "$path" status --porcelain --untracked-files=all)
    [[ -z "$status" ]] \
        || die "$path has local changes; commit or clean them before updating"

    if git -C "$path" rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1 \
        || git -C "$path" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "$path has an in-progress rebase or merge"
    fi
}

if (( ! FETCH_ONLY )); then
    for tree in master bpf bpf-next; do
        preflight_worktree "$tree"
    done
fi

log "fetching bpf remote"
git -C "$COMMON_REPO" fetch --prune bpf
log "fetching bpf-next remote"
git -C "$COMMON_REPO" fetch --prune bpf-next

if (( FETCH_ONLY )); then
    log "fetch complete; worktrees were not rebased"
    exit 0
fi

resolve_upstream() {
    local tree=$1
    local override=
    local candidate
    local -a candidates=()

    case "$tree" in
        bpf)
            override=${BPF_UPSTREAM:-}
            candidates=(bpf/master bpf/bpf bpf-next/bpf)
            ;;
        bpf-next)
            override=${BPF_NEXT_UPSTREAM:-}
            candidates=(bpf-next/bpf-next bpf-next/master)
            ;;
        master)
            override=${MASTER_UPSTREAM:-}
            candidates=(bpf-next/master)
            ;;
        *)
            die "internal error: unknown Linux tree '$tree'"
            ;;
    esac

    if [[ -n "$override" ]]; then
        candidates=("$override")
    fi

    for candidate in "${candidates[@]}"; do
        if git -C "$COMMON_REPO" rev-parse --verify --quiet \
            "refs/remotes/$candidate^{commit}" >/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    die "no upstream ref found for '$tree'; set its *_UPSTREAM variable to a valid remote-tracking ref"
}

rebase_worktree() {
    local tree=$1
    local path="$LINUX_ROOT/$tree"
    local upstream
    local before
    local after

    upstream=$(resolve_upstream "$tree")
    before=$(git -C "$path" rev-parse HEAD)
    log "rebasing $tree onto $upstream"

    if ! git -C "$path" rebase "refs/remotes/$upstream"; then
        die "rebase of '$tree' failed; resolve conflicts and run 'git -C $path rebase --continue', or abort with 'git -C $path rebase --abort'"
    fi

    after=$(git -C "$path" rev-parse HEAD)
    if [[ "$before" == "$after" ]]; then
        log "$tree is already up to date"
    else
        log "$tree updated: $before -> $after"
    fi
}

for tree in master bpf bpf-next; do
    rebase_worktree "$tree"
done

log "Linux worktrees are up to date"
