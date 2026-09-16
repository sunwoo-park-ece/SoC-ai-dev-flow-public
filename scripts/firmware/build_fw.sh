#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FW_NAME="${1:?usage: build_fw.sh <app-name>}"
FW_SRC="${ROOT_DIR}/firmware/apps/${FW_NAME}.c"
BSP_DIR="${ROOT_DIR}/firmware/bsp"
INCLUDE_DIR="${ROOT_DIR}/firmware/include"
PROTOCOL_DIR="${ROOT_DIR}/firmware/protocol"
DRIVER_DIR="${ROOT_DIR}/firmware/drivers"
: "${RUN_ROOT:?Set RUN_ROOT to an output directory outside the public checkout}"
case "$(realpath -m "$RUN_ROOT")" in
  "$ROOT_DIR"|"$ROOT_DIR"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
OUT_DIR="${RUN_ROOT}/fw/${FW_NAME}"
BENCH_APP_DIR="${ROOT_DIR}/firmware/bench/${FW_NAME}"

IMEM_DEPTH="${IMEM_DEPTH:-4096}"
DMEM_DEPTH="${DMEM_DEPTH:-8192}"

CC="${CC:-riscv32-unknown-elf-gcc}"
OBJCOPY="${OBJCOPY:-riscv32-unknown-elf-objcopy}"
OBJDUMP="${OBJDUMP:-riscv32-unknown-elf-objdump}"

if [[ ! -f "${FW_SRC}" ]]; then
  echo "[ERR] firmware source not found: ${FW_SRC}" >&2
  echo "      usage: ./scripts/firmware/build_fw.sh <app-name>" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

CFLAGS=(
  -march=rv32i
  -mabi=ilp32
  -mstrict-align
  -msmall-data-limit=0
  -O2
  -g3
  -ffreestanding
  -fno-builtin
  -ffunction-sections
  -fdata-sections
  -fno-pic
  -fno-pie
  -Wall
  -Wextra
  -I "${INCLUDE_DIR}"
  -I "${PROTOCOL_DIR}"
)

if [[ -d "${BENCH_APP_DIR}" ]]; then
  CFLAGS+=(-I "${BENCH_APP_DIR}")
fi

if [[ -n "${EXTRA_CFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_cflags_array=(${EXTRA_CFLAGS})
  CFLAGS+=("${extra_cflags_array[@]}")
fi

LDFLAGS=(
  -T "${BSP_DIR}/linker.ld"
  -nostartfiles
  -nostdlib
  -Wl,--gc-sections
  -Wl,-Map,"${OUT_DIR}/${FW_NAME}.map"
)

echo "[1/6] compile startup"
"${CC}" "${CFLAGS[@]}" -c "${BSP_DIR}/start.S" -o "${OUT_DIR}/start.o"

echo "[2/6] compile drivers and protocol"
objects=("${OUT_DIR}/start.o")
while IFS= read -r src; do
  obj="${OUT_DIR}/$(basename "${src%.c}").o"
  "${CC}" "${CFLAGS[@]}" -c "${src}" -o "${obj}"
  objects+=("${obj}")
done < <(find "${DRIVER_DIR}" "${PROTOCOL_DIR}" -maxdepth 1 -name '*.c' | sort)

echo "[3/6] compile firmware app"
if [[ -d "${BENCH_APP_DIR}" ]]; then
  while IFS= read -r src; do
    obj="${OUT_DIR}/$(basename "${src%.c}").o"
    "${CC}" "${CFLAGS[@]}" -c "${src}" -o "${obj}"
    objects+=("${obj}")
  done < <(find "${BENCH_APP_DIR}" -maxdepth 1 -name '*.c' | sort)
  while IFS= read -r src; do
    obj="${OUT_DIR}/$(basename "${src%.S}").o"
    "${CC}" "${CFLAGS[@]}" -c "${src}" -o "${obj}"
    objects+=("${obj}")
  done < <(find "${BENCH_APP_DIR}" -maxdepth 1 -name '*.S' | sort)
fi
"${CC}" "${CFLAGS[@]}" -c "${FW_SRC}" -o "${OUT_DIR}/${FW_NAME}.o"
objects+=("${OUT_DIR}/${FW_NAME}.o")

echo "[4/6] link ELF"
libs=()
if [[ "${USE_LIBGCC:-0}" == "1" ]]; then
  libs+=(-lgcc)
fi
"${CC}" "${CFLAGS[@]}" "${LDFLAGS[@]}" -o "${OUT_DIR}/${FW_NAME}.elf" "${objects[@]}" "${libs[@]}"

echo "[5/6] extract sections and generate MIF"
"${OBJCOPY}" --dump-section .imem="${OUT_DIR}/imem.bin" "${OUT_DIR}/${FW_NAME}.elf"
if "${OBJDUMP}" -h "${OUT_DIR}/${FW_NAME}.elf" | grep -q "\\.dmem_init"; then
  "${OBJCOPY}" --dump-section .dmem_init="${OUT_DIR}/dmem.bin" "${OUT_DIR}/${FW_NAME}.elf"
else
  : > "${OUT_DIR}/dmem.bin"
fi

python3 "${SCRIPT_DIR}/bin_to_mif.py" --bin "${OUT_DIR}/imem.bin" --depth "${IMEM_DEPTH}" --out "${OUT_DIR}/IMEM.mif"
python3 "${SCRIPT_DIR}/bin_to_mif.py" --bin "${OUT_DIR}/dmem.bin" --depth "${DMEM_DEPTH}" --out "${OUT_DIR}/DMEM.mif"

"${OBJDUMP}" -d -S -M no-aliases,numeric --disassemble-zeroes \
  "${OUT_DIR}/${FW_NAME}.elf" > "${OUT_DIR}/${FW_NAME}.dis"

echo "[6/6] generated images remain in the build directory"
echo "[DONE] firmware built: ${OUT_DIR}"
echo "Provide generated images to a private vendor build through explicit local configuration."
