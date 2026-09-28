#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master
SSH_PORT=${SSH_PORT:-$QEMU_SSH_PORT}
GDB_PORT=${QEMU_GDB_PORT:-1234}
KERNEL_IMAGE=
KEEP=0
ATTACH=0
GDB_ARGS=()

usage() {
    cat <<'EOF'
Usage: gdb-session.sh [options] [-- GDB_ARGS...]

Boot a lab kernel in QEMU with a gdb stub and attach gdb to it. The kernel is
paused at the first instruction unless --attach is given.

Options:
  --tree NAME        Linux tree: master, bpf, or bpf-next.
  --kernel PATH      Boot PATH instead of the selected lab image.
  --ssh-port PORT    Forward host PORT to guest port 22.
  --gdb-port PORT    gdb stub port (default: 1234).
  --attach           Do not pause the kernel; attach to a running boot.
  --keep             Leave QEMU running after gdb exits.
  -h, --help         Show this help.

DEBUG=<profile> selects out/kernel/<tree>-<profile>. When the build provides
vmlinux-gdb.py (CONFIG_GDB_SCRIPTS), the lx-* helper commands such as lx-dmesg,
lx-ps, and lx-symbols are loaded automatically.
EOF
}

while (($# > 0)); do
    case "$1" in
        --tree)
            (($# >= 2)) || die "--tree requires a value"
            TREE=$2
            shift 2
            ;;
        --kernel)
            (($# >= 2)) || die "--kernel requires a value"
            KERNEL_IMAGE=$2
            shift 2
            ;;
        --ssh-port)
            (($# >= 2)) || die "--ssh-port requires a value"
            SSH_PORT=$2
            shift 2
            ;;
        --gdb-port)
            (($# >= 2)) || die "--gdb-port requires a value"
            GDB_PORT=$2
            shift 2
            ;;
        --attach)
            ATTACH=1
            shift
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            GDB_ARGS=("$@")
            break
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

validate_tree "$TREE"
require_cmd gdb

OUTPUT=$(kernel_output_dir "$TREE" "${DEBUG:-}")
if [[ -z "$KERNEL_IMAGE" ]]; then
    KERNEL_IMAGE=$(kernel_image_path "$TREE")
fi
[[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found: $KERNEL_IMAGE; run make kernel TREE=$TREE${DEBUG:+ DEBUG=$DEBUG} first"

VMLINUX="$OUTPUT/vmlinux"
[[ -f "$VMLINUX" ]] || die "vmlinux not found: $VMLINUX; run make kernel TREE=$TREE${DEBUG:+ DEBUG=$DEBUG} first"

cleanup() {
    local status=$?
    if (( KEEP == 0 )); then
        "$ROOT_DIR/scripts/run-qemu.sh" --tree "$TREE" --ssh-port "$SSH_PORT" --stop >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

boot_args=(
    --tree "$TREE"
    --ssh-port "$SSH_PORT"
    --gdb-port "$GDB_PORT"
    --kernel "$KERNEL_IMAGE"
    --background
)
if (( ATTACH == 0 )); then
    boot_args+=(--gdb-wait)
fi
"$ROOT_DIR/scripts/run-qemu.sh" "${boot_args[@]}"

log "waiting for the gdb stub on port $GDB_PORT"
hex_port=$(printf '%04X' "$GDB_PORT")
stub_ready=0
for _ in {1..100}; do
    if [[ -r /proc/net/tcp ]] && awk -v port="$hex_port" \
        '$4 == "0A" && $2 ~ (":" port "$") { found = 1 } END { exit !found }' \
        /proc/net/tcp 2>/dev/null; then
        stub_ready=1
        break
    fi
    sleep 0.1
done
if (( stub_ready == 0 )); then
    die "gdb stub did not listen on port $GDB_PORT"
fi

gdb_cmd=(-q "$VMLINUX")

gdb_scripts=0
if [[ -f "$OUTPUT/vmlinux-gdb.py" ]]; then
    if gdb -q -batch -ex 'python 1' >/dev/null 2>&1; then
        gdb_scripts=1
    else
        warn "gdb has no Python support; skipping vmlinux-gdb.py"
    fi
fi
if (( gdb_scripts )); then
    # -iex runs before the executable is opened, so gdb auto-loads the helper
    # script without the safe-path warning.
    gdb_cmd+=(-iex "set auto-load safe-path $OUTPUT")
    gdb_cmd+=(-ex "source $OUTPUT/vmlinux-gdb.py")
fi

gdb_cmd+=(-ex "target remote 127.0.0.1:$GDB_PORT")

log "vmlinux: $VMLINUX"
if (( ATTACH )); then
    log "kernel is running; set breakpoints and continue as needed"
else
    log "kernel is paused; early breakpoints must use hbreak until it has started"
fi
if (( gdb_scripts )); then
    log "lx-* helpers are loaded; memory readers such as lx-symbols need a started kernel"
fi

gdb "${gdb_cmd[@]}" "${GDB_ARGS[@]+"${GDB_ARGS[@]}"}"
