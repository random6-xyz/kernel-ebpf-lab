#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master
SSH_PORT=${SSH_PORT:-$QEMU_SSH_PORT}
KEEP_QEMU=${KEEP_QEMU:-0}

usage() {
    cat <<'EOF'
Usage: test.sh [options]

Options:
  --tree NAME              Linux tree: master, bpf, or bpf-next.
  --ssh-port PORT          Forward host PORT to guest port 22.
  --keep                   Leave QEMU running after the test.
  -h, --help               Show this help.
EOF
}

while (($# > 0)); do
    case "$1" in
        --tree)
            (($# >= 2)) || die "--tree requires a value"
            TREE=$2
            shift 2
            ;;
        --ssh-port)
            (($# >= 2)) || die "--ssh-port requires a value"
            SSH_PORT=$2
            shift 2
            ;;
        --keep)
            KEEP_QEMU=1
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

validate_tree "$TREE"
require_cmd ssh
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be numeric: $SSH_PORT"

PRIVATE_KEY=$(ensure_ssh_key)
KNOWN_HOSTS="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.known_hosts"
PID_FILE="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.pid"
SERIAL_LOG="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.serial.log"
SSH_OPTIONS=(
    -i "$PRIVATE_KEY"
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=2
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o IdentitiesOnly=yes
)

cleanup() {
    local status=$?
    if (( KEEP_QEMU == 0 )); then
        "$ROOT_DIR/scripts/run-qemu.sh" --tree "$TREE" --ssh-port "$SSH_PORT" --stop >/dev/null 2>&1 || true
    fi
    if [[ -f "$SERIAL_LOG" ]]; then
        ensure_directory "$ARTIFACTS_OUTPUT"
        cp -- "$SERIAL_LOG" "$ARTIFACTS_OUTPUT/qemu-${TREE}-${SSH_PORT}.serial.log"
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

# Dropbear creates fresh host keys in the ephemeral rootfs on every boot.
rm -f -- "$KNOWN_HOSTS"
"$ROOT_DIR/scripts/run-qemu.sh" --tree "$TREE" --ssh-port "$SSH_PORT" --background

connected=0
for _ in {1..120}; do
    if [[ -s "$PID_FILE" ]]; then
        pid=$(<"$PID_FILE")
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
    fi
    if ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 true >/dev/null 2>&1; then
        connected=1
        break
    fi
    sleep 1
done

if (( connected == 0 )); then
    warn "QEMU did not become reachable over SSH"
    if [[ -f "$SERIAL_LOG" ]]; then
        tail -n 80 "$SERIAL_LOG" >&2 || true
    fi
    exit 1
fi

log "SSH connection established"
ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 /usr/bin/ebpf-lab-smoke
log "guest smoke test passed for $TREE"
