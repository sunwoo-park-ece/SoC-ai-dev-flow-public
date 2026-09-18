#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/p08b_vram_host"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) exit 2 ;;
esac
mkdir -p "$run_dir"

gcc -std=c11 -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined \
    -I "$repo_root/firmware/include" \
    -include "$repo_root/verification/firmware/display_smoke_mmio.h" \
    "$repo_root/firmware/drivers/vram.c" \
    "$repo_root/verification/firmware/p08b_vram_host.c" \
    -o "$run_dir/test" > "$run_dir/compile.log" 2>&1
"$run_dir/test" > "$run_dir/run.log" 2>&1
grep -q 'SUMMARY: PASS P08B bounded VRAM firmware API' "$run_dir/run.log"
sha256sum "$repo_root/firmware/drivers/vram.c" \
    "$repo_root/firmware/include/vram.h" \
    "$repo_root/verification/firmware/p08b_vram_host.c" \
    > "$run_dir/source_hashes.sha256"
cat "$run_dir/run.log"
