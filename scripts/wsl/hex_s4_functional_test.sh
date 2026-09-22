#!/usr/bin/env bash
set -euo pipefail

# S4 Directed Functional Test Runner.
# Supports four modes:
#   (default)                  -- normal S4 run against original RTL
#   --inject-bad-expectation   -- Mutation A: oracle corruption
#   --inject-raw-map-fault     -- Mutation B: HEX0/HEX1 field swap in isolated RTL copy
#   --inject-dec-fault         -- Mutation C: digit-5 decoder corruption in isolated RTL copy
#
# Usage:
#   RUN_ROOT=/path/outside/repo bash scripts/wsl/hex_s4_functional_test.sh [MODE]

repo_root="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
: "${RUN_ROOT:?Set RUN_ROOT to a path outside the public checkout}"

mode="${1:-}"
case "$mode" in
    ""|--inject-bad-expectation|--inject-raw-map-fault|--inject-dec-fault) ;;
    *) echo "usage: $0 [--inject-bad-expectation|--inject-raw-map-fault|--inject-dec-fault]" >&2; exit 2 ;;
esac

# Determine run name and DUT source
run_name="hex_s4_functional"
dut_src="rtl/peripherals/APB_HEX_display.v"
case "$mode" in
    --inject-bad-expectation) run_name="hex_s4_functional_mut_a_bad_expectation" ;;
    --inject-raw-map-fault)   run_name="hex_s4_functional_mut_b_raw_map"
                              dut_src="verification/directed/hex/mutations/APB_HEX_display_mut_raw.v" ;;
    --inject-dec-fault)       run_name="hex_s4_functional_mut_c_dec"
                              dut_src="verification/directed/hex/mutations/APB_HEX_display_mut_dec.v" ;;
esac

run_dir="$RUN_ROOT/p10-hex/$run_name"

# Safety: run_dir must not be inside the repo
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"

# --- result.json finalization ---
compile_exit=null
target_exit=null
guard_exit=null
status=FAIL
finalize() {
    local final_exit=$?
    trap - EXIT
    printf '{"status":"%s","compile_exit":%s,"target_exit":%s,"guard_exit":%s,"final_exit":%d}\n' \
        "$status" "$compile_exit" "$target_exit" "$guard_exit" "$final_exit" \
        > "$run_dir/result.json"
    exit "$final_exit"
}
trap finalize EXIT

cd "$repo_root"

# --- Source hashes ---
sha256sum \
    rtl/peripherals/APB_HEX_display.v \
    verification/directed/hex/mutations/APB_HEX_display_mut_raw.v \
    verification/directed/hex/mutations/APB_HEX_display_mut_dec.v \
    verification/directed/hex/tb_hex_s4_functional.sv \
    scripts/wsl/hex_s4_functional_test.sh \
    > "$run_dir/source_hashes.sha256"

# --- Compile ---
if iverilog -g2012 -s tb_hex_s4_functional \
    -o "$run_dir/tb_hex_s4_functional.vvp" \
    "$dut_src" \
    verification/directed/hex/tb_hex_s4_functional.sv \
    > "$run_dir/compile.log" 2>&1; then
    compile_exit=0
else
    compile_exit=$?
    exit "$compile_exit"
fi

# --- Simulate ---
vvp_args=()
case "$mode" in
    --inject-bad-expectation) vvp_args=(+INJECT_BAD_EXPECTATION) ;;
    --inject-raw-map-fault)   vvp_args=(+INJECT_RAW_MAP_FAULT) ;;
    --inject-dec-fault)       vvp_args=(+INJECT_DEC_FAULT) ;;
esac

if vvp "$run_dir/tb_hex_s4_functional.vvp" "${vvp_args[@]}" \
    > "$run_dir/run.log" 2>&1; then
    target_exit=0
else
    target_exit=$?
    exit "$target_exit"
fi

# --- Guard: for normal run, expect PASS string; mutations must NOT reach here ---
if [[ "$mode" == "" ]]; then
    if grep -Fq 'SUMMARY: PASS HEX S4 functional' "$run_dir/run.log" \
        > "$run_dir/guard.log" 2>&1; then
        guard_exit=0
    else
        guard_exit=1
        exit "$guard_exit"
    fi
else
    # Mutation mode: simulation must have already exited nonzero above.
    # If we reach here, the mutation was not detected — that is a failure.
    guard_exit=1
    echo "MUTATION_NOT_DETECTED: $mode — simulation exited 0, expected failure" \
        > "$run_dir/guard.log"
    exit "$guard_exit"
fi

status=PASS
echo "PASS $run_name"
