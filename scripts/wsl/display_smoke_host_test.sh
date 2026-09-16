#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT to an output directory outside the public checkout}"
case "$(realpath -m "$RUN_ROOT")" in
  "$ROOT_DIR"|"$ROOT_DIR"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
OUT="$RUN_ROOT/display_smoke/host"
mkdir -p "$OUT"
FLAGS=(-std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined
       -I "$ROOT_DIR/firmware/include"
       -include "$ROOT_DIR/verification/firmware/display_smoke_mmio.h")
"${HOST_CC:-gcc}" "${FLAGS[@]}" -Dmain=display_smoke_entry \
    -c "$ROOT_DIR/firmware/apps/display_smoke.c" -o "$OUT/app.o"
"${HOST_CC:-gcc}" "${FLAGS[@]}" "$OUT/app.o" \
    "$ROOT_DIR/firmware/drivers/led.c" \
    "$ROOT_DIR/firmware/drivers/hex_display.c" \
    "$ROOT_DIR/firmware/drivers/vga_text.c" \
    "$ROOT_DIR/firmware/drivers/vram.c" \
    "$ROOT_DIR/verification/firmware/display_smoke_host.c" -o "$OUT/test"
"$OUT/test"
