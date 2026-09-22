#!/usr/bin/env bash
set -euo pipefail

# S5 Production Bridge & CPU E2E Integration Test Runner.
# Supports four modes:
#   (default)             -- normal S5 run across L1, L2, L3
#   --inject-l1-fault     -- Mutation: L1 Bridge PSEL suppression leakage fault
#   --inject-l2-fault     -- Mutation: L2 SoC Bus register/pin glitch side-effect fault
#   --inject-l3-fault     -- Mutation: L3 CPU Bridge HRESP error masking fault
#
# Usage:
#   RUN_ROOT=/path/outside/repo bash scripts/wsl/hex_s5_integration_test.sh [MODE]

repo_root="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
: "${RUN_ROOT:?Set RUN_ROOT to a path outside the public checkout}"

mode="${1:-}"
case "$mode" in
    ""|--inject-l1-fault|--inject-l2-fault|--inject-l3-fault) ;;
    *) echo "usage: $0 [--inject-l1-fault|--inject-l2-fault|--inject-l3-fault]" >&2; exit 2 ;;
esac

run_name="hex_s5_integration"
case "$mode" in
    --inject-l1-fault) run_name="hex_s5_integration_mut_l1" ;;
    --inject-l2-fault) run_name="hex_s5_integration_mut_l2" ;;
    --inject-l3-fault) run_name="hex_s5_integration_mut_l3" ;;
esac

run_dir="$RUN_ROOT/p10-hex/$run_name"

# Safety: run_dir must not be inside the repo
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"

# --- Detailed per-tier exit code tracking ---
l1_compile_exit=null
l1_sim_exit=null
l1_guard_exit=null

l2_compile_exit=null
l2_sim_exit=null
l2_guard_exit=null

l3_compile_exit=null
l3_sim_exit=null
l3_guard_exit=null

overall_status=FAIL
mutation_signature_found=false
expected_signature=""

finalize() {
    local final_exit=$?
    trap - EXIT
    printf '{"status":"%s","mode":"%s","l1_compile_exit":%s,"l1_sim_exit":%s,"l1_guard_exit":%s,"l2_compile_exit":%s,"l2_sim_exit":%s,"l2_guard_exit":%s,"l3_compile_exit":%s,"l3_sim_exit":%s,"l3_guard_exit":%s,"mutation_signature_found":%s,"expected_signature":"%s","final_exit":%d}\n' \
        "$overall_status" "${mode:-normal}" \
        "$l1_compile_exit" "$l1_sim_exit" "$l1_guard_exit" \
        "$l2_compile_exit" "$l2_sim_exit" "$l2_guard_exit" \
        "$l3_compile_exit" "$l3_sim_exit" "$l3_guard_exit" \
        "$mutation_signature_found" "$expected_signature" "$final_exit" \
        > "$run_dir/result.json"
    exit "$final_exit"
}
trap finalize EXIT

cd "$repo_root"

# --- Source hashes ---
sha256sum \
    rtl/bus/AHB_APB_bridge.v \
    rtl/peripherals/APB_HEX_display.v \
    verification/directed/hex/tb_hex_s5_bridge.sv \
    verification/directed/hex/tb_hex_s5_soc_bus.sv \
    verification/directed/hex/tb_hex_s5_cpu_e2e.sv \
    scripts/wsl/hex_s5_integration_test.sh \
    > "$run_dir/source_hashes.sha256"

mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done

# ==============================================================================
# Tier L1: Bridge Unit Test (Bridge Address Decode & AHB/APB Protocol)
# ==============================================================================
echo "=== Running Tier L1: Bridge Unit ==="
l1_args=()
if [[ "$mode" == "--inject-l1-fault" ]]; then
    l1_args=(+INJECT_L1_SUPPRESSION_FAULT)
    expected_signature="L1_SUPPRESSION_FAIL"
fi

if iverilog -g2012 -s tb_hex_s5_bridge \
    -o "$run_dir/tb_hex_s5_bridge.vvp" \
    rtl/bus/AHB_APB_bridge.v \
    verification/directed/hex/tb_hex_s5_bridge.sv \
    > "$run_dir/l1_compile.log" 2>&1; then
    l1_compile_exit=0
else
    l1_compile_exit=$?
    echo "ERROR: Tier L1 compilation failed (exit $l1_compile_exit)" >&2
    exit "$l1_compile_exit"
fi

if vvp "$run_dir/tb_hex_s5_bridge.vvp" "${l1_args[@]}" \
    > "$run_dir/l1_run.log" 2>&1; then
    l1_sim_exit=0
    if [[ "$mode" == "--inject-l1-fault" ]]; then
        echo "FAIL: L1 mutation did not trigger failure" >&2
        exit 1
    fi
else
    l1_sim_exit=$?
    if [[ "$mode" == "--inject-l1-fault" ]]; then
        if grep -Fq "$expected_signature" "$run_dir/l1_run.log"; then
            mutation_signature_found=true
            echo "PASS: L1 mutation detected with expected signature '$expected_signature' (exit $l1_sim_exit)"
            overall_status=MUTATION_DETECTED
            exit "$l1_sim_exit"
        else
            echo "FAIL: L1 mutation failed without expected signature '$expected_signature'" >&2
            exit 1
        fi
    else
        echo "ERROR: Tier L1 simulation failed (exit $l1_sim_exit)" >&2
        exit "$l1_sim_exit"
    fi
fi

if grep -Fq 'SUMMARY: PASS HEX S5 L1 bridge' "$run_dir/l1_run.log"; then
    l1_guard_exit=0
else
    l1_guard_exit=1
    echo "ERROR: Tier L1 pass marker missing" >&2
    exit 1
fi

# ==============================================================================
# Tier L2: SoC Bus Test (AMBA_SoC_TOP Interconnect & Immutability Monitoring)
# ==============================================================================
echo "=== Running Tier L2: SoC Bus ==="
l2_args=()
if [[ "$mode" == "--inject-l2-fault" ]]; then
    l2_args=(+INJECT_L2_SIDE_EFFECT_FAULT)
    expected_signature="L2_V04_EVENT_GLITCH"
fi

if iverilog -g2012 -s tb_hex_s5_soc_bus \
    -o "$run_dir/tb_hex_s5_soc_bus.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/hex/tb_hex_s5_soc_bus.sv \
    > "$run_dir/l2_compile.log" 2>&1; then
    l2_compile_exit=0
else
    l2_compile_exit=$?
    echo "ERROR: Tier L2 compilation failed (exit $l2_compile_exit)" >&2
    exit "$l2_compile_exit"
fi

if vvp "$run_dir/tb_hex_s5_soc_bus.vvp" "${l2_args[@]}" \
    > "$run_dir/l2_run.log" 2>&1; then
    l2_sim_exit=0
    if [[ "$mode" == "--inject-l2-fault" ]]; then
        echo "FAIL: L2 mutation did not trigger failure" >&2
        exit 1
    fi
else
    l2_sim_exit=$?
    if [[ "$mode" == "--inject-l2-fault" ]]; then
        if grep -Fq "$expected_signature" "$run_dir/l2_run.log" || grep -Fq "L2_V04_SETUP_GLITCH" "$run_dir/l2_run.log"; then
            mutation_signature_found=true
            echo "PASS: L2 mutation detected with expected signature '$expected_signature' (exit $l2_sim_exit)"
            overall_status=MUTATION_DETECTED
            exit "$l2_sim_exit"
        else
            echo "FAIL: L2 mutation failed without expected signature '$expected_signature'" >&2
            exit 1
        fi
    else
        echo "ERROR: Tier L2 simulation failed (exit $l2_sim_exit)" >&2
        exit "$l2_sim_exit"
    fi
fi

if grep -Fq 'SUMMARY: PASS HEX S5 L2 soc bus' "$run_dir/l2_run.log"; then
    l2_guard_exit=0
else
    l2_guard_exit=1
    echo "ERROR: Tier L2 pass marker missing" >&2
    exit 1
fi

# ==============================================================================
# Tier L3: CPU E2E Test (RV32I 5-stage CPU Machine Code Execution)
# ==============================================================================
echo "=== Running Tier L3: CPU E2E ==="
l3_args=()
if [[ "$mode" == "--inject-l3-fault" ]]; then
    l3_args=(+INJECT_L3_BUS_FAULT)
    expected_signature="L3_TRAP_TIMEOUT"
fi

if iverilog -g2012 -s tb_hex_s5_cpu_e2e \
    -o "$run_dir/tb_hex_s5_cpu_e2e.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/hex/tb_hex_s5_cpu_e2e.sv \
    > "$run_dir/l3_compile.log" 2>&1; then
    l3_compile_exit=0
else
    l3_compile_exit=$?
    echo "ERROR: Tier L3 compilation failed (exit $l3_compile_exit)" >&2
    exit "$l3_compile_exit"
fi

if vvp "$run_dir/tb_hex_s5_cpu_e2e.vvp" "${l3_args[@]}" \
    > "$run_dir/l3_run.log" 2>&1; then
    l3_sim_exit=0
    if [[ "$mode" == "--inject-l3-fault" ]]; then
        echo "FAIL: L3 mutation did not trigger failure" >&2
        exit 1
    fi
else
    l3_sim_exit=$?
    if [[ "$mode" == "--inject-l3-fault" ]]; then
        if grep -Fq "$expected_signature" "$run_dir/l3_run.log"; then
            mutation_signature_found=true
            echo "PASS: L3 mutation detected with expected signature '$expected_signature' (exit $l3_sim_exit)"
            overall_status=MUTATION_DETECTED
            exit "$l3_sim_exit"
        else
            echo "FAIL: L3 mutation failed without expected signature '$expected_signature'" >&2
            exit 1
        fi
    else
        echo "ERROR: Tier L3 simulation failed (exit $l3_sim_exit)" >&2
        exit "$l3_sim_exit"
    fi
fi

if grep -Fq 'SUMMARY: PASS HEX S5 L3 cpu e2e' "$run_dir/l3_run.log"; then
    l3_guard_exit=0
else
    l3_guard_exit=1
    echo "ERROR: Tier L3 pass marker missing" >&2
    exit 1
fi

overall_status=PASS
echo "PASS $run_name (L1, L2, L3 all passed)"
