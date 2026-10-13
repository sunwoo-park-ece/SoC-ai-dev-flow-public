#!/usr/bin/env bash
set -u
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${RUN_ROOT:?fresh local G1C parent root required}"
workspace=$(cd -- "$repo/../.." && pwd)
case "$RUN_ROOT" in "$workspace"/runs/P12A3-G1C-*) ;; *) exit 1;; esac
if [[ -e "$RUN_ROOT" ]]; then echo "REFUSE existing run root" >&2; exit 1; fi
mkdir -p -- "$RUN_ROOT" || exit 1
RUN_ROOT="$RUN_ROOT/leaf" bash "$repo/scripts/wsl/p12a3_soc_vga_test.sh" > "$RUN_ROOT/parent.raw.log" 2>&1
leaf=$?
if [[ $leaf -eq 0 ]]; then
 python3 "$repo/verification/independent/p12a3_soc_vga/p12a3_evidence_guard.py" guard "$RUN_ROOT/leaf" >> "$RUN_ROOT/parent.raw.log" 2>&1
 guard=$?
else guard=1; fi
final=1
if [[ $leaf -eq 0 && $guard -eq 0 ]]; then final=0; fi
printf 'leaf_exit=%s guard_exit=%s final_exit=%s\n' "$leaf" "$guard" "$final" | tee "$RUN_ROOT/parent.result"
exit "$final"
