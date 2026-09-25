#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
out="$RUN_ROOT/p11c_c1_soc_adc_ownership"; mkdir -p "$out"

mapfile -t src < <(python3 "$root/scripts/wsl/source_list.py" OPEN_SIM_VERILOG)
mapfile -t dirs < <(find "$root/rtl/core/v" -type d | sort)
inc=()
for d in "${dirs[@]}"; do
    inc+=("-I$d")
done

# Verilator lint check on modified SoC top and testbench
verilator --lint-only --sv --timing --relative-includes -Wno-fatal \
    --top-module tb_soc_adc_ownership \
    "${inc[@]}" "${src[@]}" "$root/verification/directed/adc/tb_soc_adc_ownership.sv" \
    > "$out/verilator.log" 2>&1

# Icarus compile and run
iverilog -g2012 -s tb_soc_adc_ownership -o "$out/tb_soc_adc_ownership.vvp" \
    "${inc[@]}" "${src[@]}" "$root/verification/directed/adc/tb_soc_adc_ownership.sv" \
    > "$out/compile.log" 2>&1

vvp "$out/tb_soc_adc_ownership.vvp" > "$out/run.log" 2>&1

grep -q '^SUMMARY: PASS C1 SoC ADC ownership cutover$' "$out/run.log"
cat "$out/run.log"
echo "PASS p11c_c1_soc_adc_ownership"
