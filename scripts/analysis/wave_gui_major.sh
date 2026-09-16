#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  wave_gui_major.sh <dump.(vcd|fst|ghw|vcd.gz)> [profile] [regex_file]

Profiles:
  generic (default), fifo, apb, aes, soc

Examples:
  ./scripts/analysis/wave_gui_major.sh sim/fifo_w8_r32.vcd fifo
  ./scripts/analysis/wave_gui_major.sh sim/run.vcd soc scripts/analysis/soc_regex.txt
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if ! command -v gtkwave >/dev/null 2>&1; then
  echo "ERROR: gtkwave not found"
  exit 1
fi

dump_in="$1"
profile="${2:-generic}"
regex_file="${3:-}"

if [[ ! -f "$dump_in" ]]; then
  echo "ERROR: dumpfile not found: $dump_in"
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tcl_script="$script_dir/gtkwave_major_signals.tcl"

# Prefer FST for big VCD (faster load, smaller file)
dump_use="$dump_in"
if [[ "$dump_in" == *.vcd ]]; then
  fst_out="${dump_in%.vcd}.fst"
  if command -v vcd2fst >/dev/null 2>&1; then
    if [[ ! -f "$fst_out" || "$dump_in" -nt "$fst_out" ]]; then
      echo "[INFO] converting VCD -> FST: $fst_out"
      vcd2fst "$dump_in" "$fst_out"
    fi
    dump_use="$fst_out"
  fi
fi

export GTKW_PROFILE="$profile"
if [[ -n "$regex_file" ]]; then
  export GTKW_REGEX_FILE="$regex_file"
else
  unset GTKW_REGEX_FILE || true
fi

# Reduce dconf/dbus warnings under WSL/headless contexts.
export GSETTINGS_BACKEND=memory

echo "[INFO] dump=$dump_use profile=$GTKW_PROFILE"
exec gtkwave -f "$dump_use" -S "$tcl_script"
