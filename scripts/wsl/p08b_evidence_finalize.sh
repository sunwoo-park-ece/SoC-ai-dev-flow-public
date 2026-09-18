#!/usr/bin/env bash

# Source-only helper. The caller owns target execution and guard invocation.
p08b_finalize_and_check() {
    local repo_root="$1" evidence_dir="$2" test_id="$3"
    local start_time="$4" end_time="$5" assertions_passed="$6"
    local assertions_failed="$7" clock_phase="${8:-}"
    local metadata=(python3 scripts/wsl/p08b_evidence_metadata.py finalize
        "$evidence_dir" --root "$repo_root" --test-id "$test_id"
        --start-time "$start_time" --end-time "$end_time"
        --assertions-passed "$assertions_passed"
        --assertions-failed "$assertions_failed"
        --limitation "Functional simulation only; static CDC, vendor fit, timing and board are not exercised.")
    if [ -n "$clock_phase" ]; then
        metadata+=(--clock-phase-ns "$clock_phase")
    fi

    rm -f "$evidence_dir/consistency_exit.txt"
    "${metadata[@]}" >/dev/null 2>&1 || true
    set +e
    python3 scripts/wsl/p08b_evidence_metadata.py check "$evidence_dir" \
        --root "$repo_root" --test-id "$test_id" \
        > "$evidence_dir/consistency_result_initial.txt" 2>&1
    local initial_rc=$?
    set -e
    printf '%s\n' "$initial_rc" > "$evidence_dir/consistency_exit.txt"

    "${metadata[@]}" >/dev/null 2>&1 || true
    set +e
    python3 scripts/wsl/p08b_evidence_metadata.py check "$evidence_dir" \
        --root "$repo_root" --test-id "$test_id" \
        > "$evidence_dir/consistency_result.txt" 2>&1
    local final_check_rc=$?
    set -e
    if [ "$final_check_rc" -ne 0 ]; then
        printf '1\n' > "$evidence_dir/consistency_exit.txt"
        "${metadata[@]}" >/dev/null 2>&1 || true
        set +e
        python3 scripts/wsl/p08b_evidence_metadata.py check "$evidence_dir" \
            --root "$repo_root" --test-id "$test_id" \
            > "$evidence_dir/consistency_result.txt" 2>&1
        final_check_rc=$?
        set -e
    fi
    P08B_FINAL_RC="$(tr -d '[:space:]' < "$evidence_dir/final_exit.txt")"
    if [ "$final_check_rc" -ne 0 ]; then
        P08B_FINAL_RC=91
    fi
    export P08B_FINAL_RC
}
