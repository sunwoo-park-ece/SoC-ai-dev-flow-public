#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/p08b_vga_cpu_fault"
case "$(realpath -m "$run_dir")" in "$repo_root"|"$repo_root"/*) exit 2;; esac
mkdir -p "$run_dir"
cd "$repo_root"

fw_root="${run_dir}/firmware"
RUN_ROOT="$fw_root" ./scripts/firmware/build_fw.sh final_main \
    > "$run_dir/firmware_build.log" 2>&1
fw_dir="$fw_root/fw/final_main"
python3 scripts/firmware/verify_trap_image.py \
    --elf "$fw_dir/final_main.elf" --map "$fw_dir/final_main.map" \
    --imem-bin "$fw_dir/imem.bin" --word-hex "$run_dir/final_main.words.hex" \
    --result-json "$run_dir/image_integrity.json" \
    > "$run_dir/image_integrity.log" 2>&1

symbol() { riscv32-unknown-elf-nm -n "$fw_dir/final_main.elf" | awk -v s="$1" '$3==s{print $1;ok=1} END{exit !ok}'; }
main_pc="$(symbol main)"
trap_pc="$(symbol __trap_entry)"
loop_pc="$(symbol __trap_fail_stop)"

mapfile -t sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=(); for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done

iverilog -g2012 -s tb_p08b_vga_cpu_fault -o "$run_dir/test.vvp" \
    "${includes[@]}" "${sources[@]}" \
    verification/directed/vga/tb_p08b_vga_cpu_fault.sv \
    > "$run_dir/compile.log" 2>&1
vvp "$run_dir/test.vvp" \
    "+IMEM_HEX=$run_dir/final_main.words.hex" \
    "+MAIN_PC=$main_pc" "+TRAP_PC=$trap_pc" "+LOOP_PC=$loop_pc" \
    > "$run_dir/run.log" 2>&1
grep -q 'SUMMARY: PASS P08B actual VGA ERROR to CPU fail-stop' "$run_dir/run.log"
sha256sum "$fw_dir/final_main.elf" "$run_dir/final_main.words.hex" \
    verification/directed/vga/tb_p08b_vga_cpu_fault.sv \
    > "$run_dir/artifact_hashes.sha256"
echo 'SUMMARY: PASS P08B actual VGA ERROR to CPU fail-stop'
