#!/usr/bin/env bash
set -u
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
: "${RUN_ROOT:?fresh local G1C run root required}"
workspace=$(cd -- "$repo/../.." && pwd)
case "$RUN_ROOT" in "$workspace"/runs/P12A3-G1C-*) ;; *) exit 1;; esac
if [[ -n "${G1_GUARD_FIXTURE:-}" ]]; then
 exec python3 "$repo/verification/independent/p12a3_soc_vga/p12a3_evidence_guard.py" replay "$G1_GUARD_FIXTURE" "$RUN_ROOT" "${G1_GUARD_MUTATION:-valid}"
fi
exec python3 "$repo/verification/independent/p12a3_soc_vga/p12a3_evidence_guard.py" run "$repo" "$RUN_ROOT"
