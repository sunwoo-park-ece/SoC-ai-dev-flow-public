#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
case "$(realpath -m "$RUN_ROOT")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the checkout' >&2; exit 2 ;;
esac
out="$RUN_ROOT/p04_boardio_host"
mkdir -p "$out"
"${HOST_CC:-gcc}" -std=c11 -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined -I "$repo_root/firmware/include" \
    -include "$repo_root/verification/firmware/p04_boardio_mmio.h" \
    "$repo_root/firmware/drivers/gpio.c" \
    "$repo_root/firmware/drivers/sw.c" \
    "$repo_root/firmware/drivers/led.c" \
    "$repo_root/verification/firmware/p04_boardio_host.c" -o "$out/test"
"$out/test"
