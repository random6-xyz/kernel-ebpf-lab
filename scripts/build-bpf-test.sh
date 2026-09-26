#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

SOURCE_DIR="$ROOT_DIR/tests/bpf"
OUTPUT_DIR="$ROOT_DIR/out/bpf"
BPF_SRC=${BPF_SRC:-}

usage() {
    cat <<'EOF'
Usage: build-bpf-test.sh

Builds every tests/bpf/*.c case into out/bpf/<name>.bpf.o.

Set BPF_SRC=/path/to/case.c to build a single source instead.
EOF
}

while (($# > 0)); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

require_cmd clang
[[ -d "$SOURCE_DIR" ]] || die "BPF case directory is missing: $SOURCE_DIR"
ensure_directory "$OUTPUT_DIR"

sources=()
if [[ -n "$BPF_SRC" ]]; then
    [[ -f "$BPF_SRC" ]] || die "BPF source is missing: $BPF_SRC"
    sources+=("$BPF_SRC")
else
    shopt -s nullglob
    sources=("$SOURCE_DIR"/*.c)
    shopt -u nullglob
    (( ${#sources[@]} > 0 )) || die "no BPF cases found in $SOURCE_DIR"
fi

for source in "${sources[@]}"; do
    name=$(basename -- "$source" .c)
    output="$OUTPUT_DIR/$name.bpf.o"

    log "building $name from $source"
    clang -target bpf -O2 -g -c "$source" -o "$output"
    [[ -s "$output" ]] || die "compiler produced an empty object: $output"
    printf '  %s\n' "$(file -b -- "$output")"
done

log "built ${#sources[@]} BPF object(s) in $OUTPUT_DIR"
