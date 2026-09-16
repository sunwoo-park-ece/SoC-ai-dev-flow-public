#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <wave.vcd> [prefix] [include_regex]"
  echo "Example: $0 sim/fifo_w8_r32.vcd fifo '(clk|reset|wr_en|rd_en|full|empty|count|data)'"
  exit 1
fi

vcd="$1"
prefix="${2:-wave}"
include_regex="${3:-}"
out_dir="sim/logs/wave_text"

cmd=(python3 scripts/analysis/vcd_text_report.py "$vcd" --out-dir "$out_dir" --prefix "$prefix")
if [[ -n "$include_regex" ]]; then
  cmd+=(--include "$include_regex")
fi

"${cmd[@]}"

echo "[DONE] text reports in: $out_dir"
