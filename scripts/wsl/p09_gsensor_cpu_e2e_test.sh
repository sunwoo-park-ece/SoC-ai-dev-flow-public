#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
out="$RUN_ROOT/p09_gsensor_cpu_e2e"; mkdir -p "$out"
RUN_ROOT="$out" "$root/scripts/firmware/build_fw.sh" p09_gsensor_cpu_e2e >"$out/build.log" 2>&1
fw="$out/fw/p09_gsensor_cpu_e2e"
od -An -tx4 -w4 -v "$fw/imem.bin" | tr -d ' ' > "$out/imem.hex"
sig=$(riscv32-unknown-elf-nm -n "$fw/p09_gsensor_cpu_e2e.elf" | awk '$3=="p09_gsensor_signature" {printf "%d", strtonum("0x"$1)/4 - strtonum("0x10000000")/4}')
test -n "$sig"
mapfile -t fault_matches < <(awk '$2=="0107a703" && $3=="lw" && $4=="x14,16(x15)" {sub(":", "", $1); print $1}' "$fw/p09_gsensor_cpu_e2e.dis")
test "${#fault_matches[@]}" -eq 1
faultpc="${fault_matches[0]}"
mapfile -t src < <(python3 "$root/scripts/wsl/source_list.py" OPEN_SIM_VERILOG)
mapfile -t dirs < <(find "$root/rtl/core/v" -type d | sort); inc=(); for d in "${dirs[@]}"; do inc+=("-I$d"); done
iverilog -g2012 -s tb_p09_gsensor_cpu_e2e -o "$out/test.vvp" "${inc[@]}" "${src[@]}" "$root/verification/directed/bus/tb_p09_gsensor_cpu_e2e.sv" >"$out/compile.log" 2>&1
vvp "$out/test.vvp" +IMEM_HEX="$out/imem.hex" +SIG_WORD="$sig" +FAULT_PC="$faultpc" >"$out/run.log" 2>&1
grep -q '^SUMMARY: PASS P09 GSensor CPU e2e$' "$out/run.log"
printf 'fault_pc=%s instruction=0107a703 lw x14,16(x15)\n' "$faultpc" > "$out/fault_instruction.txt"
sha256sum "$fw/p09_gsensor_cpu_e2e.elf" "$fw/imem.bin" "$out/imem.hex" > "$out/image_hashes.sha256"
cat "$out/run.log"
