#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

SOURCE_DIR="$ROOT_DIR/tests/bpf"
OUTPUT_DIR="$ROOT_DIR/out/bpf"
ASSEMBLER="$ROOT_DIR/tools/bpfasm.py"
LOADER_SOURCE="$ROOT_DIR/tools/bpfload.c"
LOADER_BINARY="$OUTPUT_DIR/bpfload"
BPF_SRC=${BPF_SRC:-}

usage() {
    cat <<'EOF'
Usage: build-bpf-test.sh

Builds every tests/bpf/*.c case into out/bpf/<name>.bpf.o and every
tests/bpf/*.asm case into out/bpf/<name>.bin. Raw cases also get the static
guest loader out/bpf/bpfload, built from tools/bpfload.c.

Set BPF_SRC=/path/to/case.c or /path/to/case.asm to build a single case.
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

c_sources=()
asm_sources=()
if [[ -n "$BPF_SRC" ]]; then
    [[ -f "$BPF_SRC" ]] || die "BPF source is missing: $BPF_SRC"
    case "$BPF_SRC" in
        *.asm) asm_sources+=("$BPF_SRC") ;;
        *.c) c_sources+=("$BPF_SRC") ;;
        *) die "unsupported BPF source: $BPF_SRC" ;;
    esac
else
    shopt -s nullglob
    c_sources=("$SOURCE_DIR"/*.c)
    asm_sources=("$SOURCE_DIR"/*.asm)
    shopt -u nullglob
    (( ${#c_sources[@]} + ${#asm_sources[@]} > 0 )) || die "no BPF cases found in $SOURCE_DIR"
fi

for source in "${c_sources[@]}"; do
    name=$(basename -- "$source" .c)
    output="$OUTPUT_DIR/$name.bpf.o"

    log "building $name from $source"
    clang -target bpf -O2 -g -c "$source" -o "$output"
    [[ -s "$output" ]] || die "compiler produced an empty object: $output"
    printf '  %s\n' "$(file -b -- "$output")"
done

if (( ${#asm_sources[@]} > 0 )); then
    require_cmd python3
    for source in "${asm_sources[@]}"; do
        name=$(basename -- "$source" .asm)
        output="$OUTPUT_DIR/$name.bin"

        log "assembling $name from $source"
        python3 "$ASSEMBLER" "$source" -o "$output"
        [[ -s "$output" ]] || die "assembler produced an empty image: $output"
        printf '  %s\n' "$(file -b -- "$output")"
    done

    require_cmd "${CC:-gcc}"
    log "building the raw program loader: $LOADER_BINARY"
    "${CC:-gcc}" -O2 -static -o "$LOADER_BINARY" "$LOADER_SOURCE" \
        || die "failed to link a static loader; install the static libc (for example glibc-static)"
    [[ -s "$LOADER_BINARY" ]] || die "loader build produced an empty binary: $LOADER_BINARY"
    printf '  %s\n' "$(file -b -- "$LOADER_BINARY")"
fi

log "built ${#c_sources[@]} ELF case(s) and ${#asm_sources[@]} raw case(s) in $OUTPUT_DIR"
