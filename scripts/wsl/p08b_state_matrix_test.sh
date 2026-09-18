#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${EVIDENCE_DIR:?Set EVIDENCE_DIR outside the public checkout}"
: "${CLOCK_PHASE_NS:?Set CLOCK_PHASE_NS to 0, 2 or 7}"
case "$(realpath -m "$EVIDENCE_DIR")" in
    "$repo_root"|"$repo_root"/*) echo 'EVIDENCE_DIR must be external' >&2; exit 2 ;;
esac
if [ -e "$EVIDENCE_DIR" ]; then
    echo "Refusing to overwrite evidence: $EVIDENCE_DIR" >&2
    exit 2
fi
mkdir -p "$EVIDENCE_DIR"
cd "$repo_root" || exit 2

test_id="P08B-AC02-AC05-STATE-MATRIX-PHASE-${CLOCK_PHASE_NS}NS"
sources=(
    rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v
    rtl/video/vram/HW_Cleaner.v
    rtl/video/vga/VGA_SyncGen.v
    rtl/soc/reset_release_sync.v
    verification/models/clock/vga_pll.sv
    verification/models/memory/VRAM.sv
    verification/directed/vga/tb_p08b_vga_state_matrix.sv
    scripts/wsl/p08b_state_matrix_test.sh
    scripts/wsl/p08b_evidence_guard.sh
    scripts/wsl/p08b_evidence_finalize.sh
    scripts/wsl/p08b_evidence_metadata.py
    spec/08_vga.md
)

{
    echo "TEST_ID=$test_id"
    echo 'WORKDIR=<PUBLIC_CANDIDATE_ROOT>'
    echo "COMMAND=iverilog -g2012 -s tb_p08b_vga_state_matrix -o <EVIDENCE_DIR>/test.vvp <sources>; timeout 30s vvp <EVIDENCE_DIR>/test.vvp +CLOCK_PHASE_NS=$CLOCK_PHASE_NS"
    echo "IVERILOG_VERSION=$(iverilog -V 2>&1 | head -n 1)"
    echo "VVP_VERSION=$(vvp -V 2>&1 | head -n 1)"
    echo "CLOCK_CONFIG=HCLK 10ns; behavioral PLL pclk 20ns; CLOCK_50 initial phase ${CLOCK_PHASE_NS}ns"
    echo 'SEED=deterministic'
    echo 'TIMEOUT=30s'
} > "$EVIDENCE_DIR/command.txt"

cat > "$EVIDENCE_DIR/required_assertions.txt" <<'EOF'
ASSERT_PASS AC02 normal_swap_exact_once_boundary
ASSERT_PASS AC02 request_after_boundary
ASSERT_PASS AC02 repeated_pending_command_rejected
ASSERT_PASS AC02 reset_during_pending_request
ASSERT_PASS AC03 clear_busy_overlap_and_exact_range
ASSERT_PASS AC03 combined_swap_then_clear
ASSERT_PASS AC03 sequential_repeated_command
ASSERT_PASS AC03 command_after_completion
ASSERT_PASS AC04 reset_initial_status
ASSERT_PASS AC04 vsync_event_set
ASSERT_PASS AC04 vsync_w1c_clear
ASSERT_PASS F03-VSYNC-COINCIDENT exact_edge_set_dominance
ASSERT_PASS AC04 vsync_independent_repeated
ASSERT_PASS F03-DONE-COINCIDENT exact_edge_set_dominance
ASSERT_PASS AC05 clear_active_loss
ASSERT_PASS AC05 consecutive_clear_active_loss
ASSERT_PASS F03-ABORT-COINCIDENT exact_edge_set_dominance
ASSERT_PASS AC05 idle_loss
ASSERT_PASS AC05 idle_recovery_new_operation
ASSERT_PASS AC05 swap_pending_frame_wait_loss
ASSERT_PASS AC05 swap_pending_recovery_new_operation
ASSERT_PASS AC05 combined_clear_loss
ASSERT_PASS AC05 combined_recovery_new_operation
ASSERT_PASS AC05 cdc_ack_window_loss
ASSERT_PASS AC05 ack_window_no_duplicate_after_recovery
ASSERT_PASS AC05 reset_near_pll_loss
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
        "$start_time" "$(date --iso-8601=seconds)" "$pass_count" "$fail_count" "$CLOCK_PHASE_NS"
    exit 130
}
trap interrupted HUP INT TERM

set +e
iverilog -g2012 -s tb_p08b_vga_state_matrix \
    -o "$EVIDENCE_DIR/test.vvp" "${sources[@]:0:7}" \
    >> "$EVIDENCE_DIR/stdout_stderr.log" 2>&1
compile_rc=$?
if [ "$compile_rc" -eq 0 ]; then
    timeout 30s vvp "$EVIDENCE_DIR/test.vvp" "+CLOCK_PHASE_NS=$CLOCK_PHASE_NS" \
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

set +e
scripts/wsl/p08b_evidence_guard.sh "$EVIDENCE_DIR" '^ASSERT_PASS ' 26 \
    "$test_id" "$(basename "$EVIDENCE_DIR")" "$EVIDENCE_DIR/required_assertions.txt" \
    > "$EVIDENCE_DIR/guard_result.txt" 2>&1
guard_rc=$?
set -e
printf '%s\n' "$guard_rc" > "$EVIDENCE_DIR/guard_exit.txt"

assertions_passed="$(grep -c '^ASSERT_PASS ' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
assertions_failed="$(grep -c -E 'FATAL:|ERROR:|ASSERT_FAIL|SUMMARY: FAIL' "$EVIDENCE_DIR/stdout_stderr.log" || true)"
source scripts/wsl/p08b_evidence_finalize.sh
p08b_finalize_and_check "$repo_root" "$EVIDENCE_DIR" "$test_id" \
    "$start_time" "$(date --iso-8601=seconds)" "$assertions_passed" "$assertions_failed" "$CLOCK_PHASE_NS"
exit "$P08B_FINAL_RC"
