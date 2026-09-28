#!/usr/bin/env bash
#
# Collect verifier responses for every tests/bpf case inside the lab guest.
#
# The guest root filesystem already ships ebpf-lab-verifier and bpftool, so BPF
# objects are transferred over the existing SSH channel instead of being baked
# into the image. Adding a case therefore needs no rootfs rebuild. Raw asm
# cases (.bin) use the static loader built from tools/bpfload.c, which is
# transferred the same way.

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

ELF cases (.bpf.o) are loaded with ebpf-lab-verifier and bpftool. Raw asm cases
(.bin) are loaded with the static tools/bpfload.c loader. See the .expect grammar
in README.md (accept/reject/type/expect_log for both, map/run/expect_ret for
raw cases).
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

KERNEL_IMAGE=$(kernel_image_path "$TREE")
[[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found: $KERNEL_IMAGE; run make kernel TREE=$TREE${DEBUG:+ DEBUG=$DEBUG} first"
# shellcheck disable=SC2034  # validated for existence, the path itself is unused here
ROOTFS_IMAGE=$(rootfs_image)

shopt -s nullglob
elf_objects=("$OBJECT_DIR"/*.bpf.o)
raw_objects=("$OBJECT_DIR"/*.bin)
shopt -u nullglob
(( ${#elf_objects[@]} + ${#raw_objects[@]} > 0 )) || die "no BPF cases in $OBJECT_DIR; run make bpf-object first"

LOADER_BINARY="$OBJECT_DIR/bpfload"
if (( ${#raw_objects[@]} > 0 )); then
    [[ -s "$LOADER_BINARY" ]] || die "raw loader is missing: $LOADER_BINARY; run make bpf-object first"
fi

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
    # shellcheck disable=SC2029  # the remote command is expanded locally on purpose
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

# Read the .expect sidecar. Global outputs: EXPECTATION, EXPECTATION_TYPE,
# EXPECTATION_LOG, EXPECTATION_RUN, EXPECTATION_RET, MAP_SPECS.
parse_expectation() {
    local program=$1
    local file="$CASE_DIR/$program.expect"
    local line

    EXPECTATION=accept
    EXPECTATION_TYPE=
    EXPECTATION_LOG=
    EXPECTATION_RUN=
    EXPECTATION_RET=
    MAP_SPECS=()
    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        case "$line" in
            accept | reject) EXPECTATION=$line ;;
            type=*) EXPECTATION_TYPE=${line#type=} ;;
            expect_log=*) EXPECTATION_LOG=${line#expect_log=} ;;
            map=*) MAP_SPECS+=("${line#map=}") ;;
            run=*) EXPECTATION_RUN=${line#run=} ;;
            expect_ret=*) EXPECTATION_RET=${line#expect_ret=} ;;
            "" | " "*) ;;
            *) warn "ignoring unrecognized directive in $file: $line" ;;
        esac
    done < "$file"
}

# Print the verifier log section of a guest report (both the ebpf-lab-verifier
# and bpfload markers are understood).
extract_verifier_log() {
    awk '
        /^--- verifier log ---$/ { inside = 1; next }
        /^--- end (verifier )?log ---$/ { inside = 0 }
        inside
    ' "$1"
}

# assert_log FILE PATTERN -> prints "ok" or "fail"; empty PATTERN means "-"
assert_log() {
    local file=$1
    local pattern=$2

    if [[ -z "$pattern" ]]; then
        printf '%s\n' "-"
        return 0
    fi
    if extract_verifier_log "$file" | grep -q -F -- "$pattern"; then
        printf '%s\n' "ok"
    else
        printf '%s\n' "fail"
    fi
}

# assert_ret FILE EXPECTED -> prints "ok", "fail", or "-"
assert_ret() {
    local file=$1
    local expected=$2
    local value
    local seen=0

    if [[ -z "$expected" ]]; then
        printf '%s\n' "-"
        return 0
    fi

    while IFS= read -r value; do
        seen=1
        if (( value != expected )); then
            printf '%s\n' "fail"
            return 0
        fi
    done < <(grep -o 'retval=[0-9]*' "$file" | cut -d= -f2)

    if (( seen == 1 )); then
        printf '%s\n' "ok"
    else
        printf '%s\n' "fail"
    fi
}

collect_case() {
    local kind=$1
    local object=$2
    local program remote_name

    program=$(basename -- "$object")
    if [[ "$kind" == elf ]]; then
        program=${program%.bpf.o}
        remote_name="$program.bpf.o"
    else
        program=${program%.bin}
        remote_name="$program.bin"
    fi
    parse_expectation "$program"

    log "collecting $kind verifier response for $program (expect=$EXPECTATION)"
    if ! guest_ssh "cat > $REMOTE_DIR/$remote_name" < "$object"; then
        warn "failed to transfer $object into the guest"
        failed=1
        return
    fi

    local remote_command log_file guest_exit verdict load_exit match

    if [[ "$kind" == elf ]]; then
        remote_command="/usr/bin/ebpf-lab-verifier --object $REMOTE_DIR/$remote_name --expect $EXPECTATION"
        if [[ -n "$EXPECTATION_TYPE" ]]; then
            remote_command+=" --type $EXPECTATION_TYPE"
        fi
        if [[ -n "$EXPECTATION_RUN" || -n "$EXPECTATION_RET" ]]; then
            warn "$program: run=/expect_ret= are only supported for raw (.asm) cases; ignoring"
        fi
    else
        if [[ -n "$EXPECTATION_RUN" && ! "$EXPECTATION_RUN" =~ ^[0-9]+$ ]]; then
            warn "$program: run=$EXPECTATION_RUN is not numeric; ignoring"
            EXPECTATION_RUN=
        fi
        if [[ -n "$EXPECTATION_RET" && ! "$EXPECTATION_RET" =~ ^-?[0-9]+$ ]]; then
            warn "$program: expect_ret=$EXPECTATION_RET is not numeric; ignoring"
            EXPECTATION_RET=
        fi

        remote_command="$REMOTE_DIR/bpfload"
        if [[ -n "$EXPECTATION_TYPE" ]]; then
            remote_command+=" --type $EXPECTATION_TYPE"
        fi
        local spec
        for spec in ${MAP_SPECS[@]+"${MAP_SPECS[@]}"}; do
            remote_command+=" --map $spec"
        done
        remote_command+=" --log"
        if [[ -n "$EXPECTATION_RUN" || -n "$EXPECTATION_RET" ]]; then
            if [[ -z "$EXPECTATION_RUN" ]]; then
                EXPECTATION_RUN=1
            fi
            remote_command+=" --run $EXPECTATION_RUN"
        fi
        remote_command+=" $REMOTE_DIR/$remote_name"
    fi

    log_file="$RESULT_DIR/$program.log"
    guest_exit=0
    guest_ssh "$remote_command" > "$log_file" 2>&1 || guest_exit=$?

    if [[ "$kind" == elf ]]; then
        verdict=$(sed -n 's/^verdict=//p' "$log_file" | tail -n 1 || true)
        load_exit=$(sed -n 's/^load_exit=//p' "$log_file" | tail -n 1 || true)
        [[ -n "$verdict" ]] || verdict=ERROR
        [[ -n "$load_exit" ]] || load_exit=unknown
        match=$(assert_log "$log_file" "$EXPECTATION_LOG")
    else
        verdict=PASS
        if [[ "$EXPECTATION" == accept ]]; then
            if ! grep -q -F ': ACCEPT' "$log_file" || (( guest_exit != 0 )); then
                verdict=FAIL
            fi
        else
            if ! grep -q -F ': REJECT' "$log_file"; then
                verdict=FAIL
            fi
        fi
        load_exit=-
        match=$(assert_log "$log_file" "$EXPECTATION_LOG")
        ret_match=$(assert_ret "$log_file" "$EXPECTATION_RET")
        if [[ "$ret_match" == fail ]]; then
            match=fail
        elif [[ "$ret_match" == ok && "$match" == "-" ]]; then
            match=ok
        fi
    fi

    if [[ "$match" == fail && "$verdict" == PASS ]]; then
        verdict=FAIL
    fi

    printf '%s kind=%s expect=%s verdict=%s load_exit=%s ssh_exit=%s match=%s log=%s\n' \
        "$program" "$kind" "$EXPECTATION" "$verdict" "$load_exit" "$guest_exit" \
        "$match" "artifacts/verifier/$TREE/$program.log" >> "$SUMMARY"

    if [[ "$verdict" != PASS ]]; then
        warn "$program: verdict=$verdict (see $log_file)"
        failed=1
    fi
}

# Dropbear creates fresh host keys in the ephemeral rootfs on every boot.
rm -f -- "$KNOWN_HOSTS"
"$ROOT_DIR/scripts/run-qemu.sh" --tree "$TREE" --ssh-port "$SSH_PORT" --background --kernel "$KERNEL_IMAGE"

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
if (( ${#raw_objects[@]} > 0 )); then
    log "transferring the raw program loader"
    guest_ssh "cat > $REMOTE_DIR/bpfload" < "$LOADER_BINARY"
    guest_ssh "chmod +x $REMOTE_DIR/bpfload"
fi

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
    printf '# program kind expect verdict load_exit ssh_exit match log\n'
} > "$SUMMARY"

failed=0
for object in "${elf_objects[@]}"; do
    collect_case elf "$object"
done
for object in "${raw_objects[@]}"; do
    collect_case raw "$object"
done

log "summary: $SUMMARY"
if (( failed != 0 )); then
    exit 1
fi
log "all verifier responses matched their expectation for $TREE"
