#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${EVIDENCE_DIR:?Set EVIDENCE_DIR outside the public checkout}"
: "${CLOCK_PHASE_NS:?Set CLOCK_PHASE_NS to 0, 2 or 7}"
case "$(realpath -m "$EVIDENCE_DIR")" in
    "$repo_root"|"$repo_root"/*) echo 'EVIDENCE_DIR must be external' >&2; exit 2 ;;
esac
if [ -e "$EVIDENCE_DIR" ]; then echo 'evidence directory exists' >&2; exit 2; fi
mkdir -p "$EVIDENCE_DIR"
cd "$repo_root" || exit 2

sources=(
    rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v
    rtl/video/vram/HW_Cleaner.v
    rtl/video/vga/VGA_SyncGen.v
    rtl/soc/reset_release_sync.v
    verification/models/clock/vga_pll.sv
    verification/models/memory/VRAM.sv
    verification/directed/vga/tb_p08b_vga_atomicity_matrix.sv
    scripts/wsl/p08b_atomicity_matrix_test.sh
    spec/08_vga.md
)
{
    echo "TEST_ID=P08B-AC-F01-FIX-PHASE-${CLOCK_PHASE_NS}NS"
    echo 'WORKDIR=<PUBLIC_CANDIDATE_ROOT>'
    echo "COMMAND=iverilog ...; timeout 30s vvp test.vvp +CLOCK_PHASE_NS=$CLOCK_PHASE_NS"
    echo "IVERILOG_VERSION=$(iverilog -V 2>&1 | head -n 1)"
    echo "VVP_VERSION=$(vvp -V 2>&1 | head -n 1)"
    echo "CLOCK_CONFIG=HCLK 10ns; CLOCK_50 initial phase ${CLOCK_PHASE_NS}ns"
    echo 'TIMEOUT=30s wall; 20000ns simulation'
    echo 'SEED=deterministic'
} > "$EVIDENCE_DIR/command.txt"
sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes.sha256"
manifest_sha="$(sha256sum "$EVIDENCE_DIR/source_hashes.sha256" | awk '{print $1}')"
start="$(date --iso-8601=seconds)"
: > "$EVIDENCE_DIR/stdout_stderr.log"
set +e
iverilog -g2012 -s tb_p08b_vga_atomicity_matrix -o "$EVIDENCE_DIR/test.vvp" \
    "${sources[@]:0:7}" >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    timeout 30s vvp "$EVIDENCE_DIR/test.vvp" "+CLOCK_PHASE_NS=$CLOCK_PHASE_NS" \
        >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
    rc=$?
fi
set -e
printf '%s\n' "$rc" > "$EVIDENCE_DIR/exit_code.txt"
sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes_post.sha256"
if cmp -s "$EVIDENCE_DIR/source_hashes.sha256" "$EVIDENCE_DIR/source_hashes_post.sha256"; then unchanged=true; else unchanged=false; fi
passes="$(grep -c '^ASSERT_PASS ' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
failures="$(grep -c -E 'FATAL:|ASSERT_FAIL|SUMMARY: FAIL' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
if [ "$rc" -eq 0 ] && [ "$unchanged" = true ] && [ "$passes" -eq 6 ] && [ "$failures" -eq 0 ] && grep -q '^SUMMARY: PASS P08B F01 ATOMICITY MATRIX' "$EVIDENCE_DIR/stdout_stderr.log"; then result=PASS; else result=FAIL; fi
log_sha="$(sha256sum "$EVIDENCE_DIR/stdout_stderr.log" | awk '{print $1}')"
{
    echo '# Assertion observations'; echo
    echo "- Result: \`$result\`"; echo "- Exit code: \`$rc\`"
    echo "- Required/observed assertions: \`6/$passes\`"
    echo "- Failure patterns: \`$failures\`"
    echo "- Source hashes unchanged: \`$unchanged\`"; echo
    grep -E '^(CONFIG|ASSERT_PASS|OBSERVED|SUMMARY:)|FATAL:|ASSERT_FAIL' "$EVIDENCE_DIR/stdout_stderr.log" || true
} > "$EVIDENCE_DIR/assertion_observations.md"
cat > "$EVIDENCE_DIR/result.json" <<EOF
{"test_id":"P08B-AC-F01-FIX-PHASE-${CLOCK_PHASE_NS}NS","run_id":"$(basename "$EVIDENCE_DIR")","exit_code":$rc,"result":"$result","required_assertions":6,"observed_assertions":$passes,"failure_patterns":$failures,"source_hashes_unchanged":$unchanged,"source_manifest_sha256":"$manifest_sha","log_sha256":"$log_sha","start_time":"$start","end_time":"$(date --iso-8601=seconds)","limitations":["Functional behavioral PLL simulation; asynchronous setup/hold and static CDC are not proven."]}
EOF
exit "$rc"
