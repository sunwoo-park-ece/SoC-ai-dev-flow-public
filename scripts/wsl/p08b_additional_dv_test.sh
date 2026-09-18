#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${EVIDENCE_DIR:?Set EVIDENCE_DIR outside the public checkout}"
case "$(realpath -m "$EVIDENCE_DIR")" in
    "$repo_root"|"$repo_root"/*) echo 'EVIDENCE_DIR must be external' >&2; exit 2 ;;
esac
if [ -e "$EVIDENCE_DIR" ]; then
    echo "Refusing to overwrite evidence: $EVIDENCE_DIR" >&2
    exit 2
fi
mkdir -p "$EVIDENCE_DIR"
cd "$repo_root" || exit 2

test_id='P08B-AC-F02-INDEPENDENT-LEDGER'
sources=(
    rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v
    rtl/video/vram/HW_Cleaner.v
    rtl/video/vga/VGA_SyncGen.v
    rtl/soc/reset_release_sync.v
    verification/models/clock/vga_pll.sv
    verification/models/memory/VRAM.sv
    verification/directed/vga/tb_p08b_vga_back_to_back.sv
    scripts/wsl/p08b_additional_dv_test.sh
    scripts/wsl/p08b_evidence_guard.sh
    scripts/wsl/p08b_evidence_finalize.sh
    scripts/wsl/p08b_evidence_metadata.py
    spec/08_vga.md
)

{
    echo "TEST_ID=$test_id"
    echo 'WORKDIR=<PUBLIC_CANDIDATE_ROOT>'
    echo 'COMMAND=iverilog -g2012 -s tb_p08b_vga_back_to_back -o <EVIDENCE_DIR>/test.vvp <sources>; timeout 20s vvp <EVIDENCE_DIR>/test.vvp'
    echo "IVERILOG_VERSION=$(iverilog -V 2>&1 | head -n 1)"
    echo "VVP_VERSION=$(vvp -V 2>&1 | head -n 1)"
    echo 'CLOCK_CONFIG=HCLK 10ns; behavioral PLL pclk 20ns; initial phase 0ns'
    echo 'SEED=deterministic'
    echo 'TIMEOUT=20s'
} > "$EVIDENCE_DIR/command.txt"

cat > "$EVIDENCE_DIR/required_assertions.txt" <<'EOF'
ASSERT_PASS consecutive_addresses writes=4
ASSERT_PASS same_address_ordered writes=7
ASSERT_PASS first_word writes=8
ASSERT_PASS last_word writes=9
ASSERT_PASS hready_stall_then_accept writes=10
ASSERT_PASS accept_before_reject writes=11
ASSERT_PASS rejected_no_we addr=20009600
ASSERT_PASS accept_after_reject writes=12
ASSERT_PASS accepted_data_phase_stall_exactly_once writes=13
ASSERT_PASS pipelined_accept_reject_accept writes=15
ASSERT_PASS F02-INDEPENDENT-LEDGER accepts=17 okay=15 error=2 physical=15 outstanding=0 expected_bank=VRAM1 source=reset_contract
EOF

sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes.sha256"
start_time="$(date --iso-8601=seconds)"
: > "$EVIDENCE_DIR/stdout_stderr.log"

interrupted() {
    trap - HUP INT TERM
    printf 'RUNNER_INTERRUPTED signal received\n' >> "$EVIDENCE_DIR/stdout_stderr.log"
    printf '130\n' > "$EVIDENCE_DIR/exit_code.txt"
    printf '130\n' > "$EVIDENCE_DIR/target_exit.txt"
    sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes_post.sha256"
    printf 'EVIDENCE_GUARD_REJECT reason=runner_interrupted\n' > "$EVIDENCE_DIR/guard_result.txt"
    printf '1\n' > "$EVIDENCE_DIR/guard_exit.txt"
    local pass_count fail_count
    pass_count="$(grep -c '^ASSERT_PASS ' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
    fail_count="$(grep -c -E 'FATAL:|ERROR:|ASSERT_FAIL|RUNNER_INTERRUPTED' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
    source scripts/wsl/p08b_evidence_finalize.sh
    p08b_finalize_and_check "$repo_root" "$EVIDENCE_DIR" "$test_id" \
        "$start_time" "$(date --iso-8601=seconds)" "$pass_count" "$fail_count"
    exit 130
}
trap interrupted HUP INT TERM

set +e
iverilog -g2012 -s tb_p08b_vga_back_to_back \
    -o "$EVIDENCE_DIR/test.vvp" "${sources[@]:0:7}" \
    >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
compile_rc=$?
if [ "$compile_rc" -eq 0 ]; then
    mutation_arg=()
    [ "${P08B_LEDGER_MUTATION:-}" = data ] && mutation_arg+=(+LEDGER_MUTATE_DATA)
    [ "${P08B_LEDGER_MUTATION:-}" = bank ] && mutation_arg+=(+LEDGER_MUTATE_BANK)
    timeout 20s vvp "$EVIDENCE_DIR/test.vvp" "${mutation_arg[@]}" \
        >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
    target_rc=$?
else
    target_rc=$compile_rc
fi
set -e
trap - HUP INT TERM

printf '%s\n' "$target_rc" > "$EVIDENCE_DIR/exit_code.txt"
printf '%s\n' "$target_rc" > "$EVIDENCE_DIR/target_exit.txt"
sha256sum "${sources[@]}" > "$EVIDENCE_DIR/source_hashes_post.sha256"
if [ "${P08B_TEST_INJECT_GUARD_FAIL:-0}" = 1 ]; then
    printf 'ASSERT_PASS INJECTED-MISSING-ASSERTION\n' >> "$EVIDENCE_DIR/required_assertions.txt"
fi
if [ "${P08B_TEST_INJECT_ID_PREFIX:-0}" = 1 ]; then
    sed -i 's/^ASSERT_PASS first_word writes=8$/ASSERT_PASS first_word/' \
        "$EVIDENCE_DIR/required_assertions.txt"
fi

set +e
scripts/wsl/p08b_evidence_guard.sh "$EVIDENCE_DIR" '^ASSERT_PASS ' 11 \
    "$test_id" "$(basename "$EVIDENCE_DIR")" "$EVIDENCE_DIR/required_assertions.txt" \
    > "$EVIDENCE_DIR/guard_result.txt" 2>&1
guard_rc=$?
set -e
printf '%s\n' "$guard_rc" > "$EVIDENCE_DIR/guard_exit.txt"

assertions_passed="$(grep -c '^ASSERT_PASS ' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
assertions_failed="$(grep -c -E 'FATAL:|ERROR:|ASSERT_FAIL|SUMMARY: FAIL' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
source scripts/wsl/p08b_evidence_finalize.sh
p08b_finalize_and_check "$repo_root" "$EVIDENCE_DIR" "$test_id" \
    "$start_time" "$(date --iso-8601=seconds)" "$assertions_passed" "$assertions_failed"
exit "$P08B_FINAL_RC"
