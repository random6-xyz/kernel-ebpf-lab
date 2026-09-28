#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master
PROFILE=${DEBUG:-}
CONFIG_ONLY=0

usage() {
    cat <<'EOF'
Usage: build-kernel.sh [--tree master|bpf|bpf-next] [--profile NAME]
                       [--config-only]

Options:
  --tree NAME     Linux tree: master, bpf, or bpf-next.
  --profile NAME  Apply configs/kernel/profiles/NAME.config on top of the base
                  fragment and build into out/kernel/<tree>-<NAME>.
  --config-only   Regenerate .config without building an image.
  -h, --help      Show this help.
EOF
}

while (($# > 0)); do
    case "$1" in
        --tree)
            (($# >= 2)) || die "--tree requires a value"
            TREE=$2
            shift 2
            ;;
        --profile)
            (($# >= 2)) || die "--profile requires a value"
            PROFILE=$2
            shift 2
            ;;
        --config-only)
            CONFIG_ONLY=1
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
require_cmd make

FRAGMENT="$ROOT_DIR/configs/kernel/qemu-x86_64.config"
[[ -f "$FRAGMENT" ]] || die "kernel config fragment is missing: $FRAGMENT"

PROFILE_FRAGMENT=
if [[ -n "$PROFILE" ]]; then
    [[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid profile name: $PROFILE"
    PROFILE_FRAGMENT="$ROOT_DIR/configs/kernel/profiles/$PROFILE.config"
    [[ -f "$PROFILE_FRAGMENT" ]] || die "unknown debug profile '$PROFILE'; see configs/kernel/profiles"
fi

SOURCE_TREE=$(tree_path "$TREE")
[[ -f "$SOURCE_TREE/Makefile" ]] || die "Linux source is missing: $SOURCE_TREE; run make fetch first"

OUTPUT=$(kernel_output_dir "$TREE" "$PROFILE")
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
    log "creating a baseline kernel configuration for ${TREE}${PROFILE:+ (profile $PROFILE)}"
    "${KERNEL_MAKE[@]}" defconfig
fi

apply_kernel_fragment "$FRAGMENT" "$OUTPUT/.config"
if [[ -n "$PROFILE_FRAGMENT" ]]; then
    log "applying debug profile: $PROFILE"
    apply_kernel_fragment "$PROFILE_FRAGMENT" "$OUTPUT/.config"
fi
log "normalizing kernel configuration for ${TREE}${PROFILE:+ (profile $PROFILE)}"
"${KERNEL_MAKE[@]}" olddefconfig

if (( CONFIG_ONLY != 0 )); then
    log "configuration ready: $OUTPUT/.config"
    exit 0
fi

log "building kernel image for ${TREE}${PROFILE:+ (profile $PROFILE)}"
"${KERNEL_MAKE[@]}" -j"$(number_of_jobs)" bzImage

if grep -q '^CONFIG_GDB_SCRIPTS=y$' "$OUTPUT/.config"; then
    # bzImage does not pull in the default target's scripts_gdb dependency, so
    # the vmlinux-gdb.py helper script has to be generated explicitly.
    log "generating the kernel gdb helper script"
    "${KERNEL_MAKE[@]}" scripts_gdb
fi

KERNEL_IMAGE="$OUTPUT/arch/x86/boot/bzImage"
[[ -f "$KERNEL_IMAGE" ]] || die "kernel image was not produced: $KERNEL_IMAGE"

if [[ -n "$PROFILE" ]]; then
    "$ROOT_DIR/scripts/gen-compile-commands.sh" --tree "$TREE" --profile "$PROFILE"
else
    "$ROOT_DIR/scripts/gen-compile-commands.sh" --tree "$TREE"
fi

ensure_directory "$ARTIFACTS_OUTPUT"
SUFFIX=
if [[ -n "$PROFILE" ]]; then
    SUFFIX="-$PROFILE"
fi
cp -- "$OUTPUT/.config" "$ARTIFACTS_OUTPUT/kernel-$TREE$SUFFIX.config"
printf '%s\n' "$KERNEL_IMAGE" > "$ARTIFACTS_OUTPUT/kernel-$TREE$SUFFIX-image.path"
log "kernel image: $KERNEL_IMAGE"
