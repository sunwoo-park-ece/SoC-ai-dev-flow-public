#!/usr/bin/env bash
set -euo pipefail

TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TB_DIR}/../../../.." && pwd)"
RTL_DIR="${ROOT_DIR}/rtl/peripherals/aes_gcm/pipe0"
: "${RUN_ROOT:?Set RUN_ROOT to an output directory outside the public checkout}"
case "$(realpath -m "$RUN_ROOT")" in
  "$ROOT_DIR"|"$ROOT_DIR"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
OUT_DIR="${RUN_ROOT}/verification/aes_gcm_wrapper_timing"

mkdir -p "${OUT_DIR}"

iverilog -g2012 -Wall \
  -o "${OUT_DIR}/tb_apb_aes_gcm_wrapper_timing.vvp" \
  "${TB_DIR}/top_aes_gcm_mock.v" \
  "${RTL_DIR}/apb_aes_gcm_ip.v" \
  "${TB_DIR}/tb_apb_aes_gcm_wrapper_timing.sv"

vvp "${OUT_DIR}/tb_apb_aes_gcm_wrapper_timing.vvp" | tee "${OUT_DIR}/run.log"

grep -q "SUMMARY: PASS" "${OUT_DIR}/run.log"
