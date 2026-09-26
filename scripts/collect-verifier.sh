#!/usr/bin/env bash
#
# Collect verifier responses for every tests/bpf case inside the lab guest.
#
# The guest root filesystem already ships ebpf-lab-verifier and bpftool, so BPF
# objects are transferred over the existing SSH channel instead of being baked
# into the image. Adding a case therefore needs no rootfs rebuild.

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master
SSH_PORT=${SSH_PORT:-$QEMU_SSH_PORT}
KEEP_QEMU=${KEEP_QEMU:-0}
REMOTE_DIR=/root/lab-bpf
CASE_DIR="$ROOT_DIR/tests/bpf"
OBJECT_DIR="$ROOT_DIR/out/bpf"

usage() {
    cat <<'EOF'
Usage: collect-verifier.sh [options]

Options:
  --tree NAME              Linux tree: master, bpf, or bpf-next.
  --ssh-port PORT          Forward host PORT to guest port 22.
  --keep                   Leave QEMU running after collection.
  -h, --help               Show this help.

Requires a completed kernel and rootfs for the selected tree:
  make image TREE=<name>
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

KERNEL_IMAGE="$ROOT_DIR/out/kernel/$TREE/arch/x86/boot/bzImage"
[[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found: $KERNEL_IMAGE; run make kernel TREE=$TREE first"
# shellcheck disable=SC2034  # validated for existence, the path itself is unused here
ROOTFS_IMAGE=$(rootfs_image)

shopt -s nullglob
objects=("$OBJECT_DIR"/*.bpf.o)
shopt -u nullglob
(( ${#objects[@]} > 0 )) || die "no BPF objects in $OBJECT_DIR; run make bpf-object first"

PRIVATE_KEY=$(ensure_ssh_key)
KNOWN_HOSTS="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.known_hosts"
PID_FILE="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.pid"
SERIAL_LOG="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.serial.log"
RESULT_DIR="$ARTIFACTS_OUTPUT/verifier/$TREE"
SUMMARY="$RESULT_DIR/summary.txt"
SSH_OPTIONS=(
    -i "$PRIVATE_KEY"
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=2
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o IdentitiesOnly=yes
)

guest_ssh() {
    ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 "$@"
}

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

# Read the accept/reject expectation and optional bpftool program type.
parse_expectation() {
    local program=$1
    local file="$CASE_DIR/$program.expect"
    local line

    EXPECTATION=accept
    EXPECTATION_TYPE=
    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        case "$line" in
            accept | reject) EXPECTATION=$line ;;
            type=*) EXPECTATION_TYPE=${line#type=} ;;
            "" | " "*) ;;
            *) warn "ignoring unrecognized directive in $file: $line" ;;
        esac
    done < "$file"
}

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
    if guest_ssh true >/dev/null 2>&1; then
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

guest_ssh "mkdir -p $REMOTE_DIR" >/dev/null
GUEST_KERNEL=$(guest_ssh uname -r | tr -d '\r')
HOST_COMMIT=unknown
if [[ -f "$ARTIFACTS_OUTPUT/source-manifest.txt" ]]; then
    HOST_COMMIT=$(awk -v tree="$TREE" '
        $0 == "[" tree "]" { inside = 1; next }
        /^\[/ { inside = 0 }
        inside && /^commit=/ { sub(/^commit=/, ""); print; exit }
    ' "$ARTIFACTS_OUTPUT/source-manifest.txt")
    [[ -n "$HOST_COMMIT" ]] || HOST_COMMIT=unknown
fi

ensure_directory "$RESULT_DIR"
{
    printf 'tree=%s\n' "$TREE"
    printf 'kernel_image=%s\n' "$KERNEL_IMAGE"
    printf 'guest_kernel=%s\n' "$GUEST_KERNEL"
    printf 'source_commit=%s\n' "$HOST_COMMIT"
    printf 'collected_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# program expect verdict load_exit ssh_exit log\n'
} > "$SUMMARY"

failed=0
for object in "${objects[@]}"; do
    program=$(basename -- "$object" .bpf.o)
    parse_expectation "$program"

    log "collecting verifier response for $program (expect=$EXPECTATION)"
    if ! guest_ssh "cat > $REMOTE_DIR/$program.bpf.o" < "$object"; then
        warn "failed to transfer $object into the guest"
        failed=1
    fi

    remote_command="/usr/bin/ebpf-lab-verifier --object $REMOTE_DIR/$program.bpf.o --expect $EXPECTATION"
    if [[ -n "$EXPECTATION_TYPE" ]]; then
        remote_command+=" --type $EXPECTATION_TYPE"
    fi

    log_file="$RESULT_DIR/$program.log"
    guest_exit=0
    guest_ssh "$remote_command" > "$log_file" 2>&1 || guest_exit=$?

    verdict=$(sed -n 's/^verdict=//p' "$log_file" | tail -n 1 || true)
    load_exit=$(sed -n 's/^load_exit=//p' "$log_file" | tail -n 1 || true)
    [[ -n "$verdict" ]] || verdict=ERROR
    [[ -n "$load_exit" ]] || load_exit=unknown

    printf '%s expect=%s verdict=%s load_exit=%s ssh_exit=%s log=%s\n' \
        "$program" "$EXPECTATION" "$verdict" "$load_exit" "$guest_exit" \
        "artifacts/verifier/$TREE/$program.log" >> "$SUMMARY"

    if [[ "$verdict" != PASS ]]; then
        warn "$program: verdict=$verdict (see $log_file)"
        failed=1
    fi
done

log "summary: $SUMMARY"
if (( failed != 0 )); then
    exit 1
fi
log "all verifier responses matched their expectation for $TREE"
