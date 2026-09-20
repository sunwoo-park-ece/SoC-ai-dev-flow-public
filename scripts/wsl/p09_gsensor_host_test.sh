#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/p09_gsensor_host"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"

"${HOST_CC:-gcc}" -std=c11 -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined \
    -I "$repo_root/firmware/include" \
    -include "$repo_root/verification/firmware/p09_gsensor_mmio.h" \
    "$repo_root/firmware/drivers/gsensor.c" \
    "$repo_root/verification/firmware/p09_gsensor_host.c" \
    -o "$run_dir/test" > "$run_dir/compile.log" 2>&1
"$run_dir/test" > "$run_dir/run.log" 2>&1
grep -q '^SUMMARY: PASS P09 GSensor firmware MMIO lifecycle$' "$run_dir/run.log"
sha256sum \
    "$repo_root/firmware/include/gsensor.h" \
    "$repo_root/firmware/drivers/gsensor.c" \
    "$repo_root/verification/firmware/p09_gsensor_mmio.h" \
    "$repo_root/verification/firmware/p09_gsensor_host.c" \
    "$repo_root/scripts/wsl/p09_gsensor_host_test.sh" \
    > "$run_dir/source_hashes.sha256"
cat "$run_dir/run.log"
