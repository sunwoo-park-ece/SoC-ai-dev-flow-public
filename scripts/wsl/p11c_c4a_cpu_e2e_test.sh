#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
OUT_DIR="${RUN_ROOT}/p11c_c4a_cpu_e2e"
mkdir -p "${OUT_DIR}"

echo "================================================================="
echo "  [P11C-C4-A] soc_health_main Real RV32I CPU End-to-End Suite   "
echo "================================================================="

# 1. Build canonical integration firmware soc_health_main
echo "[1/4] Building production soc_health_main firmware..."
RUN_ROOT="${OUT_DIR}/fw_build" "${ROOT_DIR}/scripts/firmware/build_fw.sh" soc_health_main > "${OUT_DIR}/build_health.log" 2>&1
FW_HEALTH="${OUT_DIR}/fw_build/fw/soc_health_main"

od -An -tx4 -w4 -v "${FW_HEALTH}/imem.bin" | tr -d ' ' > "${OUT_DIR}/health_imem.hex"
if [[ -s "${FW_HEALTH}/dmem.bin" ]]; then
    od -An -tx4 -w4 -v "${FW_HEALTH}/dmem.bin" | tr -d ' ' > "${OUT_DIR}/health_dmem.hex"
else
    : > "${OUT_DIR}/health_dmem.hex"
fi

# 2. Build dedicated ADC lifecycle test firmware
echo "[2/4] Building dedicated ADC lifecycle firmware..."
RUN_ROOT="${OUT_DIR}/fw_build" "${ROOT_DIR}/scripts/firmware/build_fw.sh" p11c_adc_lifecycle_e2e > "${OUT_DIR}/build_lifecycle.log" 2>&1
FW_LIFECYCLE="${OUT_DIR}/fw_build/fw/p11c_adc_lifecycle_e2e"

od -An -tx4 -w4 -v "${FW_LIFECYCLE}/imem.bin" | tr -d ' ' > "${OUT_DIR}/lifecycle_imem.hex"
if [[ -s "${FW_LIFECYCLE}/dmem.bin" ]]; then
    od -An -tx4 -w4 -v "${FW_LIFECYCLE}/dmem.bin" | tr -d ' ' > "${OUT_DIR}/lifecycle_dmem.hex"
else
    : > "${OUT_DIR}/lifecycle_dmem.hex"
fi

SIG_WORD=$(riscv32-unknown-elf-nm -n "${FW_LIFECYCLE}/p11c_adc_lifecycle_e2e.elf" | awk '$3=="g_test_signature" {printf "%d", strtonum("0x"$1)/4 - strtonum("0x10000000")/4}')
STEP_WORD=$(riscv32-unknown-elf-nm -n "${FW_LIFECYCLE}/p11c_adc_lifecycle_e2e.elf" | awk '$3=="g_test_step" {printf "%d", strtonum("0x"$1)/4 - strtonum("0x10000000")/4}')
test -n "${SIG_WORD}"
test -n "${STEP_WORD}"

sha256sum "${FW_HEALTH}/soc_health_main.elf" "${FW_HEALTH}/imem.bin" "${OUT_DIR}/health_imem.hex" \
          "${FW_LIFECYCLE}/p11c_adc_lifecycle_e2e.elf" "${FW_LIFECYCLE}/imem.bin" "${OUT_DIR}/lifecycle_imem.hex" \
          > "${OUT_DIR}/image_hashes.sha256"

# Source discovery
mapfile -t src < <(python3 "${ROOT_DIR}/scripts/wsl/source_list.py" OPEN_SIM_VERILOG)
mapfile -t dirs < <(find "${ROOT_DIR}/rtl/core/v" -type d | sort)
inc=()
for d in "${dirs[@]}"; do
    inc+=("-I$d")
done

# 3. Execute tb_soc_health_cpu_e2e (Canonical soc_health_main integration)
echo "[3/4] Compiling and running tb_soc_health_cpu_e2e..."
iverilog -g2012 -s tb_soc_health_cpu_e2e -o "${OUT_DIR}/soc_health.vvp" \
    "${inc[@]}" "${src[@]}" "${ROOT_DIR}/verification/directed/adc/tb_soc_health_cpu_e2e.sv" \
    > "${OUT_DIR}/compile_soc_health.log" 2>&1

vvp "${OUT_DIR}/soc_health.vvp" \
    +IMEM_HEX="${OUT_DIR}/health_imem.hex" \
    +DMEM_HEX="${OUT_DIR}/health_dmem.hex" \
    +MAX_CYCLES=500000 \
    > "${OUT_DIR}/run_soc_health.log" 2>&1

grep -q '^SUMMARY: PASS tb_soc_health_cpu_e2e$' "${OUT_DIR}/run_soc_health.log"
cat "${OUT_DIR}/run_soc_health.log"
echo "PASS tb_soc_health_cpu_e2e"

# 4. Execute tb_p11c_adc_lifecycle_cpu_e2e (Dedicated lifecycle & policy matrix)
echo "[4/4] Compiling and running tb_p11c_adc_lifecycle_cpu_e2e..."
iverilog -g2012 -s tb_p11c_adc_lifecycle_cpu_e2e -o "${OUT_DIR}/lifecycle.vvp" \
    "${inc[@]}" "${src[@]}" "${ROOT_DIR}/verification/directed/adc/tb_p11c_adc_lifecycle_cpu_e2e.sv" \
    > "${OUT_DIR}/compile_lifecycle.log" 2>&1

vvp "${OUT_DIR}/lifecycle.vvp" \
    +IMEM_HEX="${OUT_DIR}/lifecycle_imem.hex" \
    +DMEM_HEX="${OUT_DIR}/lifecycle_dmem.hex" \
    +SIG_WORD="${SIG_WORD}" \
    +STEP_WORD="${STEP_WORD}" \
    +MAX_CYCLES=200000 \
    > "${OUT_DIR}/run_lifecycle.log" 2>&1

grep -q '^SUMMARY: PASS tb_p11c_adc_lifecycle_cpu_e2e$' "${OUT_DIR}/run_lifecycle.log"
cat "${OUT_DIR}/run_lifecycle.log"
echo "PASS tb_p11c_adc_lifecycle_cpu_e2e"

echo ""
echo "================================================================="
echo "  [P11C-C4-A] ALL CPU END-TO-END VERIFICATION LANES PASSED!      "
echo "================================================================="
