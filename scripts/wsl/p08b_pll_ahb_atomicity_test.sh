#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${EVIDENCE_DIR:?Set EVIDENCE_DIR outside the public checkout}"

case "$(realpath -m "$EVIDENCE_DIR")" in
    "$repo_root"|"$repo_root"/*)
        echo 'EVIDENCE_DIR must be outside the public checkout' >&2
        exit 2
        ;;
esac

if [ -e "$EVIDENCE_DIR" ]; then
    echo "Refusing to overwrite existing evidence directory: $EVIDENCE_DIR" >&2
    exit 2
fi

mkdir -p "$EVIDENCE_DIR"
cd "$repo_root" || exit 2

test_id='F01-PLL-AHB-ATOMICITY'
sources=(
    rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v
    rtl/video/vram/HW_Cleaner.v
    rtl/video/vga/VGA_SyncGen.v
    rtl/soc/reset_release_sync.v
    verification/models/clock/vga_pll.sv
    verification/models/memory/VRAM.sv
    verification/directed/vga/tb_p08b_vga_pll_ahb_atomicity.sv
    scripts/wsl/p08b_pll_ahb_atomicity_test.sh
    spec/08_vga.md
    spec/04_ahb_fabric.md
    spec/06_reset_clock.md
)

{
    echo "TEST_ID=$test_id"
    echo 'WORKDIR=<PUBLIC_CANDIDATE_ROOT>'
    echo 'COMMAND=timeout 20s vvp <compiled F01 test image>'
    echo "IVERILOG_VERSION=$(iverilog -V 2>&1 | head -n 1)"
    echo "VVP_VERSION=$(vvp -V 2>&1 | head -n 1)"
    echo 'CLOCK_CONFIG=HCLK 10ns; CLOCK_50 10ns; behavioral PLL pclk 20ns; initial phase 0ns'
    echo 'LOCK_INJECTION=approved behavioral vga_pll.inject_lock_loss() after accepted address edge and before data commit edge'
    echo 'TIMEOUT=20s wall clock and 5000ns simulation guard'
    echo 'SEED=deterministic'
} > "$EVIDENCE_DIR/command.txt"

sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes.sha256"
source_manifest_sha256="$(sha256sum "$EVIDENCE_DIR/source_hashes.sha256" | awk '{print $1}')"
start_time="$(date --iso-8601=seconds)"
: > "$EVIDENCE_DIR/stdout_stderr.log"

set +e
iverilog -g2012 -s tb_p08b_vga_pll_ahb_atomicity \
    -o "$EVIDENCE_DIR/test.vvp" "${sources[@]:0:7}" \
    >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
compile_rc=$?
if [ "$compile_rc" -eq 0 ]; then
    timeout 20s vvp "$EVIDENCE_DIR/test.vvp" \
        >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
    test_rc=$?
else
    test_rc=$compile_rc
fi
set -e
printf '%s\n' "$test_rc" > "$EVIDENCE_DIR/exit_code.txt"

sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes_post.sha256"
if cmp -s "$EVIDENCE_DIR/source_hashes.sha256" \
          "$EVIDENCE_DIR/source_hashes_post.sha256"; then
    hashes_unchanged=true
else
    hashes_unchanged=false
fi

assertions_passed="$(grep -c '^ASSERT_PASS ' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
assertions_failed="$(grep -c -E 'FATAL:|ASSERT_FAIL|SUMMARY: FAIL' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
if [ "$test_rc" -eq 0 ] && [ "$hashes_unchanged" = true ] &&
   grep -q '^SUMMARY: PASS P08B F01 Option A first boundary' "$EVIDENCE_DIR/stdout_stderr.log" &&
   [ "$assertions_failed" -eq 0 ]; then
    result=PASS
else
    result=FAIL
fi

log_sha256="$(sha256sum "$EVIDENCE_DIR/stdout_stderr.log" | awk '{print $1}')"
end_time="$(date --iso-8601=seconds)"

{
    echo '# Assertion observations'
    echo
    echo "- Test ID: \`$test_id\`"
    echo "- Result: \`$result\`"
    echo "- Exit code: \`$test_rc\`"
    echo "- ASSERT_PASS count: \`$assertions_passed\`"
    echo "- Failure-pattern count: \`$assertions_failed\`"
    echo "- Source hashes unchanged during execution: \`$hashes_unchanged\`"
    echo '- Invariant: every write with a final OKAY response must produce exactly one physical VRAM commit.'
    echo '- This first-priority run injects behavioral PLL lock loss after address acceptance and before the data commit edge.'
    echo
    echo '## Raw observations'
    echo
    grep -E '^(ASSERT_PASS|ASSERT_FAIL|INJECT|OBSERVED|SUMMARY:|TRACE tx=1)|FATAL:' \
        "$EVIDENCE_DIR/stdout_stderr.log" || true
} > "$EVIDENCE_DIR/assertion_observations.md"

cat > "$EVIDENCE_DIR/result.json" <<EOF
{
  "run_id": "$(basename "$EVIDENCE_DIR")",
  "test_id": "$test_id",
  "source_manifest_sha256": "$source_manifest_sha256",
  "start_time": "$start_time",
  "end_time": "$end_time",
  "exit_code": $test_rc,
  "assertions_passed": $assertions_passed,
  "assertions_failed": $assertions_failed,
  "source_hashes_unchanged": $hashes_unchanged,
  "result": "$result",
  "log_sha256": "$log_sha256",
  "limitations": [
    "Functional simulation uses the approved open behavioral PLL model, not vendor PLL timing.",
    "This first-priority run covers the address-accepted/data-not-yet-committed lock-loss boundary; later F01 boundaries are not run after a reproduced invariant violation.",
    "Static CDC, Quartus, TimeQuest and board verification are not exercised."
  ]
}
EOF

exit "$test_rc"
