#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

TREE=master

usage() {
    cat <<'EOF'
Usage: gen-compile-commands.sh [--tree master|bpf|bpf-next]

Generate compile_commands.json from an existing kernel build.
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
require_cmd python3

SOURCE_TREE=$(tree_path "$TREE")
[[ -f "$SOURCE_TREE/Makefile" ]] || die "Linux source is missing: $SOURCE_TREE; run make fetch first"

OUTPUT="$ROOT_DIR/out/kernel/$TREE"
[[ -f "$OUTPUT/.config" ]] || die "kernel configuration is missing for $TREE; run make kernel TREE=$TREE first"
[[ -s "$OUTPUT/arch/x86/boot/bzImage" ]] || die "kernel image is missing for $TREE; run make kernel TREE=$TREE first"

KERNEL_MAKE=(
    make -C "$SOURCE_TREE"
    O="$OUTPUT"
    ARCH="$KERNEL_ARCH"
    LLVM="${KERNEL_LLVM:-1}"
)
DATABASE="$OUTPUT/compile_commands.json"
SOURCE_DATABASE="$SOURCE_TREE/compile_commands.json"

log "generating compile database for $TREE"
"${KERNEL_MAKE[@]}" compile_commands.json
[[ -s "$DATABASE" ]] || die "kernel build did not produce a non-empty database: $DATABASE"

if ! python3 - "$DATABASE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as database_file:
    entries = json.load(database_file)

if not isinstance(entries, list) or not entries:
    raise SystemExit("compile database must contain a non-empty JSON array")
if not all(
    isinstance(entry, dict)
    and isinstance(entry.get("directory"), str)
    and isinstance(entry.get("file"), str)
    for entry in entries
):
    raise SystemExit("compile database entries must include directory and file strings")
PY
then
    die "invalid compile database: $DATABASE"
fi

if [[ -e "$SOURCE_DATABASE" || -L "$SOURCE_DATABASE" ]]; then
    if [[ ! -L "$SOURCE_DATABASE" || "$(readlink -- "$SOURCE_DATABASE")" != "$DATABASE" ]]; then
        die "refusing to replace existing source path: $SOURCE_DATABASE"
    fi
fi

TEMP_LINK="$SOURCE_TREE/.compile_commands.json.$$"
[[ ! -e "$TEMP_LINK" && ! -L "$TEMP_LINK" ]] || die "temporary link already exists: $TEMP_LINK"
trap 'rm -f -- "$TEMP_LINK"' EXIT
ln -s -- "$DATABASE" "$TEMP_LINK"
mv -Tf -- "$TEMP_LINK" "$SOURCE_DATABASE"

log "compile database: $SOURCE_DATABASE"
