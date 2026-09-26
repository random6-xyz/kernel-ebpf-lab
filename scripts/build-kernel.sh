#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master

usage() {
    cat <<'EOF'
Usage: build-kernel.sh [--tree master|bpf|bpf-next]
EOF
}

while (($# > 0)); do
    case "$1" in
        --tree)
            (($# >= 2)) || die "--tree requires a value"
            TREE=$2
            shift 2
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
require_cmd make

SOURCE_TREE=$(tree_path "$TREE")
[[ -f "$SOURCE_TREE/Makefile" ]] || die "Linux source is missing: $SOURCE_TREE; run make fetch first"

OUTPUT="$ROOT_DIR/out/kernel/$TREE"
FRAGMENT="$ROOT_DIR/configs/kernel/qemu-x86_64.config"
ensure_directory "$OUTPUT"

KERNEL_MAKE=(
    make -C "$SOURCE_TREE"
    O="$OUTPUT"
    ARCH="$KERNEL_ARCH"
    LLVM="${KERNEL_LLVM:-1}"
)

set_kernel_config() {
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

apply_kernel_fragment() {
    local fragment=$1
    local config=$2
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^CONFIG_[A-Za-z0-9_]+= ]] || continue
        key=${line%%=*}
        value=${line#*=}
        set_kernel_config "$key" "$value" "$config"
    done < "$fragment"
}

if [[ ! -f "$OUTPUT/.config" ]]; then
    log "creating a baseline kernel configuration for $TREE"
    "${KERNEL_MAKE[@]}" defconfig
fi

apply_kernel_fragment "$FRAGMENT" "$OUTPUT/.config"
log "normalizing kernel configuration for $TREE"
"${KERNEL_MAKE[@]}" olddefconfig

log "building kernel image for $TREE"
"${KERNEL_MAKE[@]}" -j"$(number_of_jobs)" bzImage

KERNEL_IMAGE="$OUTPUT/arch/x86/boot/bzImage"
[[ -f "$KERNEL_IMAGE" ]] || die "kernel image was not produced: $KERNEL_IMAGE"

"$ROOT_DIR/scripts/gen-compile-commands.sh" --tree "$TREE"

ensure_directory "$ARTIFACTS_OUTPUT"
cp -- "$OUTPUT/.config" "$ARTIFACTS_OUTPUT/kernel-$TREE.config"
printf '%s\n' "$KERNEL_IMAGE" > "$ARTIFACTS_OUTPUT/kernel-$TREE-image.path"
log "kernel image: $KERNEL_IMAGE"
