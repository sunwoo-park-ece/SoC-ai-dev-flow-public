#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
mode="${1:-}"
case "$mode" in ""|--inject-bad-expectation) ;; *) echo "usage: $0 [--inject-bad-expectation]" >&2; exit 2 ;; esac
run_name="hex_s3_shadow_host"
[[ "$mode" == "--inject-bad-expectation" ]] && run_name="hex_s3_shadow_host_injected_bad_expectation"
run_dir="$RUN_ROOT/p10-hex/$run_name"
case "$(realpath -m "$run_dir")" in "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside public checkout" >&2; exit 2 ;; esac
mkdir -p "$run_dir"

compile_exit=null; target_exit=null; guard_exit=null; status=FAIL
finalize() {
    local final_exit=$?
    trap - EXIT
    printf '{"status":"%s","compile_exit":%s,"target_exit":%s,"guard_exit":%s,"final_exit":%d}\n' "$status" "$compile_exit" "$target_exit" "$guard_exit" "$final_exit" > "$run_dir/result.json"
    exit "$final_exit"
}
trap finalize EXIT

cd "$repo_root"
sha256sum firmware/drivers/hex_display.c firmware/include/hex_display.h \
    verification/firmware/hex_s3_shadow_host.c verification/firmware/hex_s3_shadow_mmio.h \
    scripts/wsl/hex_s3_shadow_host_test.sh > "$run_dir/source_hashes.sha256"
if gcc -std=c11 -Wall -Wextra -Werror -I firmware/include \
    -include verification/firmware/hex_s3_shadow_mmio.h firmware/drivers/hex_display.c \
    verification/firmware/hex_s3_shadow_host.c -o "$run_dir/test" > "$run_dir/compile.log" 2>&1; then
    compile_exit=0
else compile_exit=$?; exit "$compile_exit"; fi
if [[ "$mode" == "--inject-bad-expectation" ]]; then
    if "$run_dir/test" inject > "$run_dir/run.log" 2>&1; then target_exit=0; else target_exit=$?; exit "$target_exit"; fi
else
    if "$run_dir/test" > "$run_dir/run.log" 2>&1; then target_exit=0; else target_exit=$?; exit "$target_exit"; fi
fi
if grep -Fxq 'SUMMARY: PASS HEX S3 shadow checks=24 writes=10 reads=3' "$run_dir/run.log" > "$run_dir/guard.log" 2>&1; then guard_exit=0; else guard_exit=$?; exit "$guard_exit"; fi
status=PASS
echo "PASS $run_name"
