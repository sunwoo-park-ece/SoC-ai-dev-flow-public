#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/gate0_trap_handler"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*)
        echo 'RUN_ROOT must be outside the public checkout' >&2
        exit 2
        ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

fw_run_root="${run_dir}/firmware_build"
RUN_ROOT="$fw_run_root" ./scripts/firmware/build_fw.sh final_main \
    > "$run_dir/final_main_build.log" 2>&1
fw_dir="${fw_run_root}/fw/final_main"

python3 scripts/firmware/verify_trap_image.py \
    --elf "$fw_dir/final_main.elf" \
    --map "$fw_dir/final_main.map" \
    --imem-bin "$fw_dir/imem.bin" \
    --word-hex "$run_dir/final_main.words.hex" \
    --result-json "$run_dir/image_integrity.json" \
    > "$run_dir/image_integrity.log" 2>&1

symbol_value() {
    riscv32-unknown-elf-nm -n "$fw_dir/final_main.elf" |
        awk -v symbol="$1" '$3 == symbol { print $1; found=1 } END { exit !found }'
}
main_pc="$(symbol_value main)"
trap_pc="$(symbol_value __trap_entry)"
loop_pc="$(symbol_value __trap_fail_stop)"

mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do
    includes+=("-I$dir")
done

iverilog -g2012 -s tb_p08b_trap_handler \
    -o "$run_dir/p08b_trap_handler.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/firmware/tb_p08b_trap_handler.sv \
    > "$run_dir/compile.log" 2>&1

for test_case in 0 1 2; do
    vvp "$run_dir/p08b_trap_handler.vvp" \
        "+CASE=${test_case}" \
        "+IMEM_HEX=${run_dir}/final_main.words.hex" \
        "+MAIN_PC=${main_pc}" \
        "+TRAP_PC=${trap_pc}" \
        "+LOOP_PC=${loop_pc}" \
        > "$run_dir/case_${test_case}.log" 2>&1
    grep -q "SUMMARY: PASS P08B firmware trap handler case ${test_case}" \
        "$run_dir/case_${test_case}.log"
done

sha256sum \
    "$fw_dir/final_main.elf" \
    "$fw_dir/final_main.map" \
    "$fw_dir/final_main.dis" \
    "$fw_dir/imem.bin" \
    "$fw_dir/IMEM.mif" \
    "$run_dir/final_main.words.hex" \
    > "$run_dir/artifact_hashes.sha256"

echo 'SUMMARY: PASS P08B firmware trap handler image and cases A/B/C/D'
