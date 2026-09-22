#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
mode="${1:-}"
case "$mode" in ""|--inject-bad-expectation) ;; *) echo "usage: $0 [--inject-bad-expectation]" >&2; exit 2 ;; esac
run_name="hex_s2_exact_decode"
[[ "$mode" == "--inject-bad-expectation" ]] && run_name="hex_s2_exact_decode_injected_bad_expectation"
run_dir="$RUN_ROOT/p10-hex/$run_name"
case "$(realpath -m "$run_dir")" in "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside public checkout" >&2; exit 2 ;; esac
mkdir -p "$run_dir"

compile_exit=null
target_exit=null
guard_exit=null
status=FAIL
finalize() {
    local final_exit=$?
    trap - EXIT
    printf '{"status":"%s","compile_exit":%s,"target_exit":%s,"guard_exit":%s,"final_exit":%d}\n' \
        "$status" "$compile_exit" "$target_exit" "$guard_exit" "$final_exit" > "$run_dir/result.json"
    exit "$final_exit"
}
trap finalize EXIT

cd "$repo_root"
sha256sum rtl/peripherals/APB_HEX_display.v verification/directed/hex/tb_hex_s2_exact_decode.sv \
    scripts/wsl/hex_s2_exact_decode_test.sh scripts/wsl/hex_s0_test.sh \
    scripts/wsl/hex_s1_ctrl_razwi_test.sh verification/directed/hex/tb_hex_s0_apb.sv \
    verification/directed/hex/tb_hex_s1_ctrl_razwi.sv > "$run_dir/source_hashes.sha256"

if iverilog -g2012 -s tb_hex_s2_exact_decode -o "$run_dir/tb_hex_s2_exact_decode.vvp" \
    rtl/peripherals/APB_HEX_display.v verification/directed/hex/tb_hex_s2_exact_decode.sv > "$run_dir/compile.log" 2>&1; then
    compile_exit=0
else
    compile_exit=$?
    exit "$compile_exit"
fi

if [[ "$mode" == "--inject-bad-expectation" ]]; then
    if vvp "$run_dir/tb_hex_s2_exact_decode.vvp" +INJECT_BAD_EXPECTATION > "$run_dir/run.log" 2>&1; then
        target_exit=0
    else
        target_exit=$?
        exit "$target_exit"
    fi
else
    if vvp "$run_dir/tb_hex_s2_exact_decode.vvp" > "$run_dir/run.log" 2>&1; then
        target_exit=0
    else
        target_exit=$?
        exit "$target_exit"
    fi
fi

if grep -Fxq 'SUMMARY: PASS HEX S2 exact-decode checks=187' "$run_dir/run.log" > "$run_dir/guard.log" 2>&1; then
    guard_exit=0
else
    guard_exit=$?
    exit "$guard_exit"
fi
status=PASS
echo "PASS $run_name"
