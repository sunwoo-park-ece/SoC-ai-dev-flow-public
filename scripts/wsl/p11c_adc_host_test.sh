#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/p11c_adc_host"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"

echo "=== P11C ADC Firmware Host Verification ==="

"${HOST_CC:-gcc}" -std=c11 -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined \
    -I "$repo_root/firmware/include" \
    -include "$repo_root/verification/firmware/p11c_adc_mmio.h" \
    "$repo_root/firmware/drivers/adc.c" \
    "$repo_root/firmware/drivers/joystick_policy.c" \
    "$repo_root/verification/firmware/p11c_adc_host.c" \
    -o "$run_dir/test" > "$run_dir/compile.log" 2>&1

"$run_dir/test" "$repo_root/verification/directed/adc/policy_vectors.txt" > "$run_dir/run.log" 2>&1
grep -q '^SUMMARY: PASS P11C ADC Firmware Host Verification$' "$run_dir/run.log"
cat "$run_dir/run.log"
echo "PASS p11c_adc_host_test"
