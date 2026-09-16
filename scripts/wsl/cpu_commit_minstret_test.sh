#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/cpu_commit_minstret"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the public checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"
mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done
for entry in commit:tb_commit_minstret fault:tb_precise_ordering_fault; do
    name="${entry%%:*}"
    top="${entry#*:}"
    iverilog -g2012 -s "$top" -o "$run_dir/${name}.vvp" \
        "${includes[@]}" "${all_sources[@]}" \
        "verification/directed/cpu/${top}.sv" \
        > "$run_dir/${name}.compile.log" 2>&1
    vvp "$run_dir/${name}.vvp" > "$run_dir/${name}.run.log" 2>&1
    grep -q 'SUMMARY: PASS' "$run_dir/${name}.run.log"
done
echo 'SUMMARY: PASS 3B2B commit/minstret directed suite'
