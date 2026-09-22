#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master
SSH_PORT=${SSH_PORT:-$QEMU_SSH_PORT}
BACKGROUND=0
STOP=0
QEMU_KVM_MODE=${QEMU_KVM:-auto}

usage() {
    cat <<'EOF'
Usage: run-qemu.sh [options]

Options:
  --tree NAME              Linux tree: master, bpf, or bpf-next.
  --ssh-port PORT          Forward host PORT to guest port 22.
  --background             Start QEMU as a daemon.
  --stop                   Stop the matching background QEMU instance.
  --no-kvm                 Disable KVM acceleration.
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
        --background|--daemon)
            BACKGROUND=1
            shift
            ;;
        --stop)
            STOP=1
            shift
            ;;
        --no-kvm)
            QEMU_KVM_MODE=0
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
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be numeric: $SSH_PORT"
(( SSH_PORT > 0 && SSH_PORT < 65536 )) || die "SSH port out of range: $SSH_PORT"

ensure_directory "$QEMU_OUTPUT"
PID_FILE="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.pid"
SERIAL_LOG="$QEMU_OUTPUT/${TREE}-${SSH_PORT}.serial.log"

if (( STOP )); then
    if [[ ! -s "$PID_FILE" ]]; then
        log "no QEMU pid file: $PID_FILE"
        exit 0
    fi

    pid=$(<"$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        log "stopping QEMU pid $pid"
        kill "$pid"
        for _ in {1..50}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
done
    fi
    rm -f -- "$PID_FILE"
    exit 0
fi

require_cmd "$QEMU_SYSTEM_X86_64"
KERNEL_IMAGE="$ROOT_DIR/out/kernel/$TREE/arch/x86/boot/bzImage"
[[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found: $KERNEL_IMAGE; run make kernel TREE=$TREE"
ROOTFS_IMAGE=$(rootfs_image)

if [[ -s "$PID_FILE" ]]; then
    old_pid=$(<"$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        die "QEMU is already running for $TREE on port $SSH_PORT (pid $old_pid)"
    fi
    rm -f -- "$PID_FILE"
fi

# shellcheck disable=SC2054
qemu_args=(
    "$QEMU_SYSTEM_X86_64"
    -name "ebpf-lab-$TREE"
    -machine "$QEMU_MACHINE"
    -m "$QEMU_MEMORY"
    -smp "$QEMU_SMP"
    -kernel "$KERNEL_IMAGE"
    -initrd "$ROOTFS_IMAGE"
    -append "console=ttyS0,115200 root=/dev/ram0 rw"
    -no-reboot
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0
)

case "$QEMU_KVM_MODE" in
    1|yes|true)
        qemu_args+=(-enable-kvm -cpu host)
        ;;
    0|no|false)
        qemu_args+=(-cpu max)
        ;;
    auto)
        if [[ -r /dev/kvm ]]; then
            qemu_args+=(-enable-kvm -cpu host)
        else
            qemu_args+=(-cpu max)
        fi
        ;;
    *)
        die "invalid QEMU_KVM value: $QEMU_KVM_MODE"
        ;;
esac

if (( BACKGROUND )); then
    rm -f -- "$SERIAL_LOG"
    qemu_args+=(
        -display none
        -monitor none
        -serial "file:$SERIAL_LOG"
        -daemonize
        -pidfile "$PID_FILE"
    )
    log "starting QEMU in background"
    "${qemu_args[@]}"
    [[ -s "$PID_FILE" ]] || die "QEMU did not create pid file: $PID_FILE"
    log "pid=$(<"$PID_FILE")"
    log "serial log=$SERIAL_LOG"
else
    qemu_args+=(
        -nographic
        -monitor none
        -serial stdio
    )
    exec "${qemu_args[@]}"
fi
