#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

require_cmd clang

SOURCE="$ROOT_DIR/tests/bpf/minimal_tracepoint.c"
OUTPUT="$ROOT_DIR/out/bpf/minimal_tracepoint.bpf.o"
[[ -f "$SOURCE" ]] || die "BPF smoke source is missing: $SOURCE"
ensure_directory "$(dirname -- "$OUTPUT")"

log "building minimal BPF tracepoint object"
clang -target bpf -O2 -g -c "$SOURCE" -o "$OUTPUT"
file "$OUTPUT"
