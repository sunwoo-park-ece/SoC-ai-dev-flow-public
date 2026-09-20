#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT to an output directory outside the public checkout}"
run_dir="${RUN_ROOT}/open_sim/${1:-manual}"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
iverilog_includes=()
verilator_includes=()
for dir in "${cpu_dirs[@]}"; do
    iverilog_includes+=("-I$dir")
    verilator_includes+=("-I$dir")
done

verilator --lint-only --sv --relative-includes -Wno-fatal \
    --top-module AMBA_SoC_TOP \
    "${verilator_includes[@]}" "${all_sources[@]}" \
    > "$run_dir/verilator.log" 2>&1
iverilog -g2012 -tnull -s AMBA_SoC_TOP \
    "${iverilog_includes[@]}" "${all_sources[@]}" \
    > "$run_dir/icarus_elaboration.log" 2>&1

run_test() {
    local name="$1" top="$2"; shift 2
    iverilog -g2012 -s "$top" -o "$run_dir/$name.vvp" "$@" \
        > "$run_dir/$name.compile.log" 2>&1
    vvp "$run_dir/$name.vvp" > "$run_dir/$name.run.log" 2>&1
    grep -q 'SUMMARY: PASS' "$run_dir/$name.run.log"
    echo "PASS $name"
}
run_test memory tb_memory_models \
    verification/models/memory/IMEM.sv verification/models/memory/memory.sv \
    verification/directed/models/memory/tb_memory_models.sv
run_test ahb_memory_bypass tb_ahb_memory_bypass \
    verification/models/memory/memory.sv rtl/bus/AHB_MEMORY_SLAVE.v \
    verification/directed/models/memory/tb_ahb_memory_bypass.sv
run_test vram tb_vram_model \
    verification/models/memory/VRAM.sv verification/directed/models/memory/tb_vram_model.sv
run_test vga tb_vga_sync \
    rtl/video/vga/VGA_SyncGen.v verification/directed/models/vga/tb_vga_sync.sv
run_test clock tb_clock_models \
    verification/models/clock/vga_pll.sv verification/models/clock/spi_pll.sv \
    verification/directed/models/clock/tb_clock_models.sv
run_test p05b_reset_adc_aux tb_p05b_reset_adc_aux \
    rtl/soc/system_reset_controller.v rtl/soc/reset_release_sync.v \
    rtl/soc/adc_command_sequencer.v rtl/peripherals/APB_UART_LORA_RT.v \
    verification/directed/reset_clock/tb_p05b_reset_adc_aux.sv
run_test p05b_vga_reset tb_p05b_vga_reset \
    rtl/soc/reset_release_sync.v rtl/video/vga/VGA_SyncGen.v \
    rtl/video/vram/HW_Cleaner.v rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v \
    verification/models/memory/VRAM.sv verification/models/clock/vga_pll.sv \
    verification/directed/reset_clock/tb_p05b_vga_reset.sv
run_test p05b_uart_rx tb_p05b_uart_rx_regression \
    rtl/peripherals/APB_UART_LORA_RT.v rtl/peripherals/APB_UART_RT.v \
    verification/directed/reset_clock/tb_p05b_uart_rx_regression.sv
run_test adc tb_adc_qsys \
    verification/models/adc/adc_qsys.sv verification/directed/models/adc/tb_adc_qsys.sv
run_test gsensor_single_pclk tb_gsensor_single_pclk \
    rtl/peripherals/gsensor/APB_GSENSOR_MB.v \
    rtl/peripherals/gsensor/spi_ee_config.v \
    verification/directed/models/gsensor/tb_gsensor_single_pclk.sv
run_test gsensor_snapshot tb_gsensor_snapshot \
    rtl/peripherals/gsensor/APB_GSENSOR_MB.v \
    rtl/peripherals/gsensor/spi_ee_config.v \
    verification/directed/models/gsensor/tb_gsensor_snapshot.sv
run_test gsensor_scheduler tb_gsensor_scheduler \
    rtl/peripherals/gsensor/spi_ee_config.v \
    verification/directed/models/gsensor/tb_gsensor_scheduler.sv
run_test register_file tb_register_file \
    rtl/core/v/id_stage/Register_File.v verification/directed/cpu/tb_register_file.sv
run_test cpu_commit_minstret tb_commit_minstret \
    "${iverilog_includes[@]}" "${all_sources[@]}" \
    verification/directed/cpu/tb_commit_minstret.sv
run_test cpu_commit_fault tb_precise_ordering_fault \
    "${iverilog_includes[@]}" "${all_sources[@]}" \
    verification/directed/cpu/tb_precise_ordering_fault.sv

check_image_rejection() {
    local model="$1" case_name="$2" image="$3" expected="$4"
    local log="$run_dir/${model}_${case_name}.log"
    iverilog -g2012 -s "$model" "-P${model}.INIT_FILE=\"$image\"" \
        -o "$run_dir/${model}_${case_name}.vvp" "verification/models/memory/$model.sv" \
        > "$run_dir/${model}_${case_name}.compile.log" 2>&1
    if vvp "$run_dir/${model}_${case_name}.vvp" > "$log" 2>&1; then
        echo "FAIL: $model accepted $case_name image" >&2; exit 1
    fi
    grep -q "$expected" "$log"
    echo "PASS ${model}_${case_name}_rejection"
}
printf 'NOT_HEX\n' > "$run_dir/invalid_image.hex"
awk 'BEGIN { for (i=0; i<4097; i++) print "00000013" }' > "$run_dir/oversized_imem.hex"
awk 'BEGIN { for (i=0; i<8193; i++) print "00000000" }' > "$run_dir/oversized_dmem.hex"
for model in IMEM memory; do
    check_image_rejection "$model" missing "$run_dir/nonexistent_image.hex" 'cannot be opened'
    check_image_rejection "$model" invalid "$run_dir/invalid_image.hex" 'invalid hex word'
done
check_image_rejection IMEM oversize "$run_dir/oversized_imem.hex" 'exceeds 4096 words'
check_image_rejection memory oversize "$run_dir/oversized_dmem.hex" 'exceeds 8192 words'

RUN_ROOT="$run_dir" bash verification/directed/firmware/aes_gcm_wrapper_timing/run_apb_aes_gcm_wrapper_timing.sh \
    > "$run_dir/aes_apb_focus.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/aes_apb_focus.log"
echo 'PASS aes_apb_focus'

mkdir -p "$run_dir/ghdl"
mapfile -t mixed_groups < <(python3 scripts/wsl/source_list.py OPEN_SIM_MIXED_MODELSIM --group)
for group_line in "${mixed_groups[@]}"; do
    if [[ ${group_line%%$'\t'*} == aes_vhdl_dependency_order ]]; then
        source_file=${group_line#*$'\t'}
        (cd "$run_dir/ghdl" && ghdl -a --std=08 -fsynopsys "$source_file") \
            >> "$run_dir/ghdl_analysis.log" 2>&1
    fi
done
echo 'PASS ghdl_aes_analysis'
echo 'SUMMARY: PASS open simulation lanes'
