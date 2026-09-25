#!/usr/bin/env bash
# P11B-B3 Independent Integration DV — regression runner
# Corrected per [P11B-B3 CORRECTION TASK] in private issue #5
# Uses explicit top-level parameter overrides (-Ptb_p11b_b3.<PARAM>=<VAL>),
# self-contained TB (Item 6 compliant), and enforces startup parameter elaboration checks.
# All outputs go to /home/swp/soc/runs/p11b-b3-independent-dv/logs/

set -euo pipefail

REPO_ROOT="/home/swp/soc/worktrees/p11-adc-public"
DUT_DIR="$REPO_ROOT/rtl/soc"
TB_DIR="$REPO_ROOT/verification/independent/p11b_b3/tb"
LOG_ROOT="/home/swp/soc/runs/p11b-b3-independent-dv/logs"
IVERILOG="iverilog"
VVP="vvp"

echo "=== P11B-B3 Independent DV Regression (Revised) ==="
echo "REPO_ROOT : $REPO_ROOT"
echo "DUT_DIR   : $DUT_DIR"
echo "TB_DIR    : $TB_DIR"
echo "LOG_ROOT  : $LOG_ROOT"
echo "Tool      : $($IVERILOG -V 2>&1 | head -1)"
echo ""

mkdir -p "$LOG_ROOT"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_LIST=""

run_case() {
    local LABEL="$1"
    local ADC_HALF="$2"
    local PCLK_HALF="$3"
    local PCLK_PHASE="$4"
    local SEED="$5"
    local LOG="$LOG_ROOT/${LABEL}.log"
    local VVP_OUT="$LOG_ROOT/${LABEL}.vvp"

    echo -n "[$LABEL] ADC=${ADC_HALF}ns*2 PCLK=${PCLK_HALF}ns*2 PHASE=${PCLK_PHASE}ns SEED=${SEED} ... "

    # Elaborate with explicit root-module parameter overrides
    if ! timeout 30s $IVERILOG -g2012 -Wall \
        -Ptb_p11b_b3.ADC_HALF_NS="$ADC_HALF" \
        -Ptb_p11b_b3.PCLK_HALF_NS="$PCLK_HALF" \
        -Ptb_p11b_b3.PCLK_PHASE_NS="$PCLK_PHASE" \
        -Ptb_p11b_b3.SEED="$SEED" \
        -o "$VVP_OUT" \
        "$DUT_DIR/adc_acquisition_engine.v" \
        "$DUT_DIR/adc_frame_mailbox_cdc.v" \
        "$TB_DIR/tb_p11b_b3.sv" \
        > "$LOG" 2>&1; then
        echo "ELAB_FAIL (see $LOG)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST="$FAIL_LIST $LABEL(elab)"
        return
    fi

    # Simulate
    if timeout 60s $VVP "$VVP_OUT" >> "$LOG" 2>&1; then
        # Check actual elaborated parameters logged by TB
        local ELAB_LINE
        ELAB_LINE=$(grep "\[ELAB_PARAM\]" "$LOG" 2>/dev/null || true)
        local EXP_STR="[ELAB_PARAM] ADC_HALF_NS=${ADC_HALF} PCLK_HALF_NS=${PCLK_HALF} PCLK_PHASE_NS=${PCLK_PHASE} SEED=${SEED}"
        if [ "$ELAB_LINE" != "$EXP_STR" ]; then
            echo "PARAM_MISMATCH (got '$ELAB_LINE', expected '$EXP_STR')"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAIL_LIST="$FAIL_LIST $LABEL(param-mismatch)"
            return
        fi

        if grep -q "\[FAIL\]" "$LOG" 2>/dev/null; then
            echo "SIM_FAIL (see $LOG)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAIL_LIST="$FAIL_LIST $LABEL(sim-fail)"
        elif grep -q "\[PASS\] All B3 independent DV checks passed\." "$LOG" 2>/dev/null; then
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "PASS (Elab Verified)"
        else
            echo "INCOMPLETE (see $LOG)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAIL_LIST="$FAIL_LIST $LABEL(incomplete)"
        fi
    else
        echo "RUNTIME_FAIL (see $LOG)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST="$FAIL_LIST $LABEL(runtime)"
    fi
}

# Deterministic fixed clock/phase matrix
# (4 clock frequency ratios, 5 phase offsets, reproducible SEED tracking)
# Label                  ADC_HALF  PCLK_HALF  PCLK_PHASE  SEED
run_case "s01_nom_ph0"      20        10          0           1  # 25/50 MHz, 0ns phase
run_case "s02_nom_ph3"      20        10          3           2  # 25/50 MHz, 3ns phase
run_case "s03_nom_ph7"      20        10          7           3  # 25/50 MHz, 7ns phase
run_case "s04_nom_ph13"     20        10         13           4  # 25/50 MHz, 13ns phase
run_case "s05_ratio2_ph0"   30        10          0           5  # 16.7/50 MHz, 0ns phase
run_case "s06_ratio2_ph5"   30        10          5           6  # 16.7/50 MHz, 5ns phase
run_case "s07_ratio3_ph0"   40        10          0           7  # 12.5/50 MHz, 0ns phase
run_case "s08_ratio3_ph8"   40        10          8           8  # 12.5/50 MHz, 8ns phase
run_case "s09_ratio4_ph0"   20        15          0           9  # 25/33.3 MHz, 0ns phase
run_case "s10_ratio4_ph5"   20        15          5          10  # 25/33.3 MHz, 5ns phase

echo ""
echo "=== Regression Summary ==="
echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
    echo "FAILED cases:$FAIL_LIST"
    exit 1
else
    echo "All B3 regression cases PASS with parameter elaboration verified."
    exit 0
fi
