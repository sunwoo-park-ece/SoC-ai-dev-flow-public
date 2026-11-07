# P13-08 revised-source Owner SOF and DE10-Lite UART runbook

Owner operates Quartus, programmer, UART capture and mirror synchronization. The historical H0 image belongs to the old source. Start with the exact Public and Private finalization SHAs from Issue #67. Stop on any nonzero tool exit, input drift or missing artifact and keep the failed run. Use a fresh run ID for any retry.

## 1. Preflight and RV32I image

Replace the two SHA placeholders with the exact Issue #67 RESULT values. Keep the same shell through the build. Set the local Quartus installation, toolchain, vendor vault and PLL placement paths. Verify the vault is the authorized DE10-Lite MAX10 project input and keep its generated/licensed files and the binding JSON local. No other process may change these inputs during this run.

```bash
set -euo pipefail
export WORKSPACE=/home/swp/soc
export PUB="$WORKSPACE/worktrees/p13-aes-public"
export PRIV="$WORKSPACE/worktrees/p13-aes-private"
PUBLIC_SHA='PASTE_PUBLIC_DOC_COMMIT_SHA'
PRIVATE_SHA='PASTE_PRIVATE_REPORT_COMMIT_SHA'
cd "$PUB"
for repo in "$PUB" "$PRIV"; do
  test "$(git -C "$repo" branch --show-current)" = cleanup/p13-aes
  test -z "$(git -C "$repo" --no-optional-locks status --porcelain=v1 -uall)"
done
test "$(git rev-parse HEAD)" = "$PUBLIC_SHA"
test "$(git -C "$PRIV" rev-parse HEAD)" = "$PRIVATE_SHA"
export QUARTUS_BIN=/home/swp/intelFPGA/19.1/quartus/bin
export CC=riscv64-unknown-elf-gcc OBJDUMP=riscv64-unknown-elf-objdump OBJCOPY=riscv64-unknown-elf-objcopy
export VENDOR_ROOT="$WORKSPACE/vendor-projects-private/quartus/de10_lite/active"
export PRIVATE_BINDINGS_JSON="$PRIV/reports/internal/migration/phase3/private_pll_bindings.json"
test -s "$PRIVATE_BINDINGS_JSON"
test -d "$VENDOR_ROOT/fpga/quartus/ip"
RUN_ID="P13-08-OWNER-$(date -u +%Y%m%dT%H%M%S%N)"
export RUN_ROOT="$WORKSPACE/runs/quartus/p13_aes/$RUN_ID"
mkdir "$RUN_ROOT"
mkdir "$RUN_ROOT/tmp"
export TMPDIR="$RUN_ROOT/tmp"
"$QUARTUS_BIN/quartus_sh" --version > "$RUN_ROOT/quartus.version"
grep -F '19.1' "$RUN_ROOT/quartus.version"
"$QUARTUS_BIN/quartus_sta" --version > "$RUN_ROOT/timequest.version"
"$CC" --version > "$RUN_ROOT/compiler.version"
git ls-files -z | xargs -0 sha256sum > "$RUN_ROOT/public.sha256"
git -C "$PRIV" ls-files -z | (cd "$PRIV"; xargs -0 sha256sum) > "$RUN_ROOT/private.sha256"
find "$VENDOR_ROOT/fpga/quartus/ip" -type f -print0 | sort -z | xargs -0 sha256sum > "$RUN_ROOT/vendor.sha256"
sha256sum "$PRIVATE_BINDINGS_JSON" > "$RUN_ROOT/bindings.sha256"
export VECTOR_ID=$(sha256sum verification/independent/p13_aes_gcm/p13_04_vectors.json | cut -d' ' -f1)
export SOURCE_ID=$(sha256sum "$RUN_ROOT/public.sha256" | cut -d' ' -f1)
export BUILD_ID=$(printf '%s\n' "$SOURCE_ID" "$VECTOR_ID" "$(sha256sum "$RUN_ROOT/compiler.version")" rv32i-ilp32-O2 | sha256sum | cut -d' ' -f1)
python3 -B -c 'import os,json; print(json.dumps({k:os.environ[k.upper()+"_ID"] for k in ("build","source","vector")}))' > "$RUN_ROOT/image-identity.json"
export EXTRA_CFLAGS="-DP13_BUILD_ID=\"$BUILD_ID\" -DP13_SOURCE_ID=\"$SOURCE_ID\" -DP13_VECTOR_ID=\"$VECTOR_ID\""
rc=0
bash scripts/firmware/build_fw.sh p13_07_aes_board_diag > "$RUN_ROOT/firmware.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$RUN_ROOT/firmware.exit"
test "$rc" = 0
FW="$RUN_ROOT/fw/p13_07_aes_board_diag"
sha256sum "$FW"/{p13_07_aes_board_diag.elf,p13_07_aes_board_diag.map,IMEM.mif,DMEM.mif} > "$RUN_ROOT/fw.sha256"
```

The existing builder compiles RV32I/ILP32 with canonical startup/linker, links ELF/map, extracts sections and invokes the existing bin-to-MIF converter. Use its resulting IMEM and DMEM files.

## 2. Owner only: generate project, install image and compile

```bash
python3 -B scripts/wsl/private_quartus.py --run-id "$RUN_ID" --generate-only > "$RUN_ROOT/generate.log" 2>&1
BUILD="$RUN_ROOT/de10_lite/quartus/$RUN_ID"
PROJECT="$BUILD/project"
grep -F 'MIF_FILE ../mem/IMEM.mif' "$PROJECT/AMBA_SoC_TOP.qsf"
grep -F 'MIF_FILE ../mem/DMEM.mif' "$PROJECT/AMBA_SoC_TOP.qsf"
for mem in IMEM.mif DMEM.mif; do
  cp "$FW/$mem" "$BUILD/mem/$mem"
  cmp "$FW/$mem" "$BUILD/mem/$mem"
done
sha256sum "$PROJECT"/{AMBA_SoC_TOP.qpf,AMBA_SoC_TOP.qsf} "$BUILD"/mem/{IMEM.mif,DMEM.mif} > "$RUN_ROOT/consumed.sha256"
rc=0
(cd "$PROJECT"; "$QUARTUS_BIN/quartus_sh" --flow compile AMBA_SoC_TOP) > "$RUN_ROOT/quartus_compile.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$RUN_ROOT/quartus_compile.exit"
test "$rc" = 0
SOF="$PROJECT/output_files/AMBA_SoC_TOP.sof"
for ext in fit.rpt asm.rpt sta.rpt; do test -s "$PROJECT/output_files/AMBA_SoC_TOP.$ext"; done
test -s "$SOF"
sha256sum -c "$RUN_ROOT/consumed.sha256"
sha256sum -c "$RUN_ROOT/fw.sha256"
sha256sum -c "$RUN_ROOT/public.sha256"
(cd "$PRIV"; sha256sum -c "$RUN_ROOT/private.sha256")
sha256sum -c "$RUN_ROOT/vendor.sha256"
sha256sum -c "$RUN_ROOT/bindings.sha256"
sha256sum "$SOF" > "$RUN_ROOT/sof.sha256"
```

The generated QSF binds the MAX10 DE10-Lite target, top, SDC and private IP. Record QSF seed/settings, actual compile/fitter/assembler and native TimeQuest summaries. Review timing and warning outcomes before programming. Internal timing cannot close external I/O, STA-002 or CDC-001. Preserve all reports in the run directory.

## 3. Owner only: discover and program the board

```bash
"$QUARTUS_BIN/quartus_pgm" -l
read -r -p 'Enter confirmed USB-Blaster cable selector: ' CABLE
test -n "$CABLE"
"$QUARTUS_BIN/quartus_pgm" -c "$CABLE" -a
read -r -p 'Enter confirmed MAX10 chain device index: ' DEVICE
[[ "$DEVICE" =~ ^[1-9][0-9]*$ ]]
sha256sum -c "$RUN_ROOT/sof.sha256"
rc=0
"$QUARTUS_BIN/quartus_pgm" -c "$CABLE" -m JTAG -o "p;$SOF@$DEVICE" > "$RUN_ROOT/program.log" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$RUN_ROOT/program.exit"
test "$rc" = 0
```

Use the identified USB-UART port, 115200 8N1, 3.3 V UART1 TX (DE10-Lite AB2) to RX and common ground. Capture one complete reset-started session from BEGIN through SUMMARY as `uart.payload.log`. Preserve raw capture separately if the terminal adds a header. Record board identity, cable and index, exact SOF path/hash, UART settings, reset action and observations. Programming status is not device image readback.

```bash
python3 -B verification/independent/p13_aes_gcm/p13_07_board_log_check.py \
  --manifest "$RUN_ROOT/image-identity.json" --log "$RUN_ROOT/uart.payload.log" > "$RUN_ROOT/uart-check.json"
(cd "$RUN_ROOT"; find . -type f ! -name artifacts.sha256 -print0 | sort -z | xargs -0 sha256sum > artifacts.sha256)
```

Expect 15 mandatory cases: encrypt/decrypt KATs, wrong tag, API invalid LEN, functional zeroize and clear/next, zero/positive timeout and recovery. ARG17/65535 reject before MMIO. RTL/CPU_ALIAS_DV=PASS_BOUNDED; PHYSICAL_BOARD_ALIAS=NOT_RUN. BUSY is NOT_TESTABLE in this protocol; natural overflow NOT_RUN. D08 integrated remains NOT_PROVEN.

## 4. Owner only: mirror after evidence review

After saving the exact local source/board receipt and confirming no competing writer:

```bash
cd /home/swp/soc/SoC-window-chat
./sync_chat_mirror.sh
```

Record emitted snapshot ID and require SNAPSHOT_COMPLETE. Read back WORKSPACE_STATE and CURRENT_WORK from the destination, verify the same snapshot and exact Public/Private HEADs above, and confirm the destination parity verification reported by the operator tool. Ask Main Hub to review the fresh mirror. Canonical WSL remains the source of truth; no reverse sync. Attach the run ID, source and SOF hashes, actual exits and board checker receipt privately. Final acceptance and Clean Baseline release remain separate.
