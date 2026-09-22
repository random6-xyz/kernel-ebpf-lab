#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

required_commands=(
    git make gcc clang ld.lld
    bc bison flex openssl perl rsync cpio gzip pahole
    qemu-system-x86_64 ssh ssh-keygen python3
)

missing=()
for command in "${required_commands[@]}"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        missing+=("$command")
    fi
done

if (( ${#missing[@]} != 0 )); then
    printf 'Missing host commands:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf '\nInstall the missing packages using the host distribution package manager, then rerun make check-host.\n' >&2
    exit 1
fi

if ! pahole_version=$(pahole --version 2>&1); then
    printf 'pahole is installed but cannot be executed:\n%s\n' "$pahole_version" >&2
    exit 1
fi

if [[ ! -r /dev/kvm ]]; then
    warn '/dev/kvm is not accessible; QEMU will use software emulation'
fi

printf 'Host prerequisites look complete.\n'
printf 'clang=%s\n' "$(clang --version | head -n 1)"
printf 'qemu=%s\n' "$(qemu-system-x86_64 --version | head -n 1)"
printf 'pahole=%s\n' "$(printf '%s\n' "$pahole_version" | head -n 1)"
