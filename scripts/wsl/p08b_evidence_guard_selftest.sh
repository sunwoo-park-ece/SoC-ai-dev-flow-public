#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${FIXTURE_ROOT:?Set FIXTURE_ROOT outside the public checkout}"
case "$(realpath -m "$FIXTURE_ROOT")" in
    "$repo_root"|"$repo_root"/*) echo 'FIXTURE_ROOT must be external' >&2; exit 2 ;;
esac
if [ -e "$FIXTURE_ROOT" ]; then
    echo "Refusing to overwrite fixtures: $FIXTURE_ROOT" >&2
    exit 2
fi
mkdir -p "$FIXTURE_ROOT"
cd "$repo_root" || exit 2

passed=0
failed=0
record() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        passed=$((passed + 1))
        echo "ASSERT_PASS SELFTEST_EXPECTED_REJECTION name=$name rc=$actual"
    else
        failed=$((failed + 1))
        echo "ASSERT_FAIL selftest name=$name actual=$actual expected=$expected"
    fi
}

make_guard_fixture() {
    local name="$1" target_exit="$2" log_text="$3"
    local base="$FIXTURE_ROOT/$name"
    local root="$base/root"
    local evidence="$base/evidence"
    mkdir -p "$root" "$evidence"
    printf 'fixture source\n' > "$root/source.txt"
    printf 'TEST_ID=FIXTURE\n' > "$evidence/command.txt"
    printf '%s\n' "$target_exit" > "$evidence/exit_code.txt"
    printf '%s\n' "$target_exit" > "$evidence/target_exit.txt"
    printf '%b\n' "$log_text" > "$evidence/stdout_stderr.log"
    (cd "$root" && sha256sum source.txt) > "$evidence/source_hashes.sha256"
    cp "$evidence/source_hashes.sha256" "$evidence/source_hashes_post.sha256"
    printf 'ASSERT_PASS required\n' > "$evidence/required_assertions.txt"
}

guard_case() {
    local name="$1" expected="$2" evidence="$FIXTURE_ROOT/$1/evidence"
    set +e
    P08B_MANIFEST_ROOT="$FIXTURE_ROOT/$name/root" \
        scripts/wsl/p08b_evidence_guard.sh "$evidence" '^ASSERT_PASS ' 1 \
        FIXTURE evidence "$evidence/required_assertions.txt" >/dev/null 2>&1
    local rc=$?
    set -e
    if [ "$expected" = reject ]; then
        [ "$rc" -ne 0 ]; record "$name" "$?" 0
    else
        record "$name" "$rc" 0
    fi
}

exact_id_fixture() {
    local name="$1" log_text="$2" required_text="$3" expected="$4"
    make_guard_fixture "$name" 0 "$log_text"
    printf '%b' "$required_text" > "$FIXTURE_ROOT/$name/evidence/required_assertions.txt"
    guard_case "$name" "$expected"
}

# The original six malformed raw-evidence fixtures.
make_guard_fixture fail_pattern 0 'ASSERT_PASS required\nASSERT_FAIL injected'
make_guard_fixture missing_assertion 0 'SUMMARY: PASS fixture'
make_guard_fixture nonzero_exit 9 'ASSERT_PASS required'
make_guard_fixture changed_source 0 'ASSERT_PASS required'
printf '0000000000000000000000000000000000000000000000000000000000000000  source.txt\n' \
    > "$FIXTURE_ROOT/changed_source/evidence/source_hashes_post.sha256"
make_guard_fixture timeout 124 'ASSERT_PASS required'
make_guard_fixture missing_artifact 0 'ASSERT_PASS required'
rm "$FIXTURE_ROOT/missing_artifact/evidence/stdout_stderr.log"
for name in fail_pattern missing_assertion nonzero_exit changed_source timeout missing_artifact; do
    guard_case "$name" reject
done

# A real valid guard input must still be accepted.
make_guard_fixture valid_full 0 'ASSERT_PASS required\nSUMMARY: PASS fixture'
guard_case valid_full accept

# Exact-record matching must reject the Hardening-05 substring false pass and
# similar quoted/context/case/whitespace/list-integrity counterexamples.
exact_id_fixture exact_payload_valid \
    'ASSERT_PASS first_word writes=8\nSUMMARY: PASS fixture' \
    'ASSERT_PASS first_word writes=8\n' accept
exact_id_fixture id_suffix_collision 'ASSERT_PASS required_fake' \
    'ASSERT_PASS required\n' reject
exact_id_fixture id_prefix_collision 'ASSERT_PASS requir' \
    'ASSERT_PASS required\n' reject
exact_id_fixture observed_context 'OBSERVED ASSERT_PASS required' \
    'ASSERT_PASS required\n' reject
exact_id_fixture summary_context 'SUMMARY ASSERT_PASS required' \
    'ASSERT_PASS required\n' reject
exact_id_fixture fail_context 'ASSERT_FAIL ASSERT_PASS required' \
    'ASSERT_PASS required\n' reject
exact_id_fixture case_mismatch 'ASSERT_PASS Required' \
    'ASSERT_PASS required\n' reject
exact_id_fixture leading_whitespace ' ASSERT_PASS required' \
    'ASSERT_PASS required\n' reject
exact_id_fixture trailing_whitespace 'ASSERT_PASS required ' \
    'ASSERT_PASS required\n' reject
exact_id_fixture crlf_log 'ASSERT_PASS required\r' \
    'ASSERT_PASS required\n' reject
exact_id_fixture duplicate_log 'ASSERT_PASS required\nASSERT_PASS required' \
    'ASSERT_PASS required\n' reject
exact_id_fixture duplicate_list 'ASSERT_PASS required' \
    'ASSERT_PASS required\nASSERT_PASS required\n' reject
exact_id_fixture empty_list_entry 'ASSERT_PASS required' \
    'ASSERT_PASS required\n\n' reject
exact_id_fixture forged_list_entry 'ASSERT_PASS required' \
    'OBSERVED ASSERT_PASS required\n' reject
exact_id_fixture crlf_list 'ASSERT_PASS required' \
    'ASSERT_PASS required\r\n' reject

finalize_fixture() {
    local name="$1" guard_exit="$2"
    make_guard_fixture "$name" 0 'ASSERT_PASS required\nSUMMARY: PASS fixture'
    local evidence="$FIXTURE_ROOT/$name/evidence" root="$FIXTURE_ROOT/$name/root"
    if [ "$guard_exit" -eq 0 ]; then
        printf 'EVIDENCE_GUARD_PASS fixture\n' > "$evidence/guard_result.txt"
    else
        printf 'EVIDENCE_GUARD_REJECT reason=injected\n' > "$evidence/guard_result.txt"
    fi
    printf '%s\n' "$guard_exit" > "$evidence/guard_exit.txt"
    set +e
    python3 scripts/wsl/p08b_evidence_metadata.py finalize "$evidence" --root "$root" \
        --test-id FIXTURE --start-time start --end-time end \
        --assertions-passed 1 --assertions-failed 0 >/dev/null 2>&1
    set -e
}

metadata_check() {
    local name="$1" expected="$2" evidence="$FIXTURE_ROOT/$1/evidence"
    set +e
    python3 scripts/wsl/p08b_evidence_metadata.py check "$evidence" \
        --root "$FIXTURE_ROOT/$name/root" --test-id FIXTURE >/dev/null 2>&1
    local rc=$?
    set -e
    if [ "$expected" = reject ]; then
        [ "$rc" -ne 0 ]; record "$name" "$?" 0
    else
        record "$name" "$rc" 0
    fi
}

# Six full-metadata checks: valid, missing command/observations, invalid JSON,
# same fake pre/post manifest, and target-log SHA mismatch.
finalize_fixture metadata_valid 0
metadata_check metadata_valid accept
finalize_fixture missing_command 0
rm "$FIXTURE_ROOT/missing_command/evidence/command.txt"
metadata_check missing_command reject
finalize_fixture empty_observations 0
: > "$FIXTURE_ROOT/empty_observations/evidence/assertion_observations.md"
metadata_check empty_observations reject
finalize_fixture invalid_json 0
printf '{bad json\n' > "$FIXTURE_ROOT/invalid_json/evidence/result.json"
metadata_check invalid_json reject
finalize_fixture same_fake_manifest 0
printf '0000000000000000000000000000000000000000000000000000000000000000  source.txt\n' \
    > "$FIXTURE_ROOT/same_fake_manifest/evidence/source_hashes.sha256"
cp "$FIXTURE_ROOT/same_fake_manifest/evidence/source_hashes.sha256" \
   "$FIXTURE_ROOT/same_fake_manifest/evidence/source_hashes_post.sha256"
metadata_check same_fake_manifest reject
finalize_fixture bad_log_hash 0
sed -i 's/"log_sha256": "[0-9a-f]*"/"log_sha256": "bad"/' \
    "$FIXTURE_ROOT/bad_log_hash/evidence/result.json"
metadata_check bad_log_hash reject

# Actual source tamper must fail even when pre/post manifests are identical.
finalize_fixture actual_source_tamper 0
printf 'tampered source\n' > "$FIXTURE_ROOT/actual_source_tamper/root/source.txt"
metadata_check actual_source_tamper reject

# Reproduce the prior contradiction: guard failure is finalized consistently,
# then a stale Markdown PASS injection must be rejected.
finalize_fixture guard_fail_consistent 1
metadata_check guard_fail_consistent accept
grep -q -- "- Result: \`EVIDENCE_INSUFFICIENT\`" \
    "$FIXTURE_ROOT/guard_fail_consistent/evidence/assertion_observations.md"
record guard_fail_md_finalized "$?" 0
sed -i "s/- Result: \`EVIDENCE_INSUFFICIENT\`/- Result: \`PASS\`/" \
    "$FIXTURE_ROOT/guard_fail_consistent/evidence/assertion_observations.md"
set +e
python3 scripts/wsl/p08b_evidence_metadata.py check \
    "$FIXTURE_ROOT/guard_fail_consistent/evidence" \
    --root "$FIXTURE_ROOT/guard_fail_consistent/root" --test-id FIXTURE \
    >/dev/null 2>&1
contradiction_rc=$?
set -e
[ "$contradiction_rc" -ne 0 ]; record contradictory_markdown "$?" 0

# Parent wrapper must propagate a child-observed failure despite target exit 0.
set +e
REQUIRED_ASSERT_COUNT=1 scripts/wsl/run_with_evidence.sh PARENT-PROPAGATION \
    "$FIXTURE_ROOT/parent_propagation" -- bash -c \
    'echo "ASSERT_PASS required"; echo "ASSERT_FAIL injected"; echo "SUMMARY: PASS injected"; exit 0' \
    >/dev/null 2>&1
parent_rc=$?
set -e
[ "$parent_rc" -ne 0 ]; record parent_failure_propagation "$?" 0

# Target nonzero and timeout retain their original exit/status in both reports.
set +e
REQUIRED_ASSERT_COUNT=1 scripts/wsl/run_with_evidence.sh TARGET-NONZERO \
    "$FIXTURE_ROOT/target_nonzero" -- bash -c 'echo "SUMMARY: PASS misleading"; exit 23' \
    >/dev/null 2>&1
nonzero_rc=$?
REQUIRED_ASSERT_COUNT=1 scripts/wsl/run_with_evidence.sh TARGET-TIMEOUT \
    "$FIXTURE_ROOT/target_timeout" -- timeout 0.1s bash -c 'sleep 2' \
    >/dev/null 2>&1
timeout_rc=$?
set -e
if [ "$nonzero_rc" -eq 23 ] && grep -q '"result": "FAIL"' \
    "$FIXTURE_ROOT/target_nonzero/result.json"; then
    record target_nonzero_preserved 0 0
else
    record target_nonzero_preserved 1 0
fi
if [ "$timeout_rc" -eq 124 ] && grep -q '"target_exit": 124' \
    "$FIXTURE_ROOT/target_timeout/result.json"; then
    record target_timeout_preserved 0 0
else
    record target_timeout_preserved 1 0
fi

# Exercise the wrapper's signal trap. The outer timeout returns 124, while
# the finalized interrupted run records target/final 130 and no stale PASS.
set +e
timeout -s TERM 1 env REQUIRED_ASSERT_COUNT=1 \
    scripts/wsl/run_with_evidence.sh TARGET-INTERRUPTED \
    "$FIXTURE_ROOT/target_interrupted" -- bash -c 'sleep 5; echo "SUMMARY: PASS too-late"' \
    >/dev/null 2>&1
interrupt_outer_rc=$?
set -e
if [ "$interrupt_outer_rc" -eq 124 ] && \
   grep -q '"target_exit": 130' "$FIXTURE_ROOT/target_interrupted/result.json" && \
   grep -q -- "- Result: \`FAIL\`" "$FIXTURE_ROOT/target_interrupted/assertion_observations.md"; then
    record interrupted_finalized 0 0
else
    record interrupted_finalized 1 0
fi

if [ "$failed" -eq 0 ] && [ "$passed" -ge 36 ]; then
    echo "SUMMARY: PASS P08B AC-F04 fixtures passed=$passed failed=$failed"
    exit 0
fi
echo "SUMMARY: FAIL P08B AC-F04 fixtures passed=$passed failed=$failed"
exit 1
