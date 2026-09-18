#!/usr/bin/env bash
set -u

if [ "$#" -ne 5 ] && [ "$#" -ne 6 ]; then
    echo 'usage: p08b_evidence_guard.sh DIR REGEX COUNT TEST_ID RUN_ID [REQUIRED_IDS]' >&2
    exit 2
fi
evidence_dir="$1"
required_regex="$2"
required_count="$3"
expected_test_id="$4"
expected_run_id="$5"
required_ids="${6:-}"
repo_root="${P08B_MANIFEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

reject() {
    echo "EVIDENCE_GUARD_REJECT reason=$1"
    exit 1
}

for file in command.txt exit_code.txt target_exit.txt stdout_stderr.log source_hashes.sha256 source_hashes_post.sha256; do
    [ -s "$evidence_dir/$file" ] || reject "missing_or_empty_$file"
done

rc="$(tr -d '[:space:]' < "$evidence_dir/exit_code.txt")"
[[ "$rc" =~ ^[0-9]+$ ]] || reject invalid_exit_code
[[ "$required_count" =~ ^[0-9]+$ ]] || reject invalid_required_count
[ "$rc" = "$(tr -d '[:space:]' < "$evidence_dir/target_exit.txt")" ] || reject target_exit_mismatch
[ "$rc" -eq 0 ] || reject "nonzero_exit_$rc"
[ "$(basename "$evidence_dir")" = "$expected_run_id" ] || reject run_id_mismatch
grep -Fxq "TEST_ID=$expected_test_id" "$evidence_dir/command.txt" || reject test_id_mismatch

failure_count="$(grep -c -E 'FATAL:|ASSERT_FAIL|SUMMARY: FAIL|(^|[[:space:]])FAIL([[:space:]]|:)' "$evidence_dir/stdout_stderr.log" || true)"
[ "$failure_count" -eq 0 ] || reject "failure_patterns_$failure_count"

observed="$(grep -c -E "$required_regex" "$evidence_dir/stdout_stderr.log" || true)"
[ "$observed" -ge "$required_count" ] || reject "required_observations_${observed}_of_${required_count}"

cmp -s "$evidence_dir/source_hashes.sha256" \
       "$evidence_dir/source_hashes_post.sha256" || reject source_hash_changed

if [ -n "$required_ids" ]; then
    [ -s "$required_ids" ] || reject missing_required_assertion_list
    list_count="$(awk 'END { print NR }' "$required_ids")"
    [ "$list_count" -eq "$required_count" ] || \
        reject "required_assertion_count_${list_count}_of_${required_count}"
    LC_ALL=C grep -Eq '^ASSERT_PASS [[:graph:]]+( [[:graph:]]+)*$' "$required_ids" || \
        reject invalid_required_assertion_list
    invalid_count="$(LC_ALL=C grep -Evc '^ASSERT_PASS [[:graph:]]+( [[:graph:]]+)*$' "$required_ids" || true)"
    [ "$invalid_count" -eq 0 ] || reject invalid_required_assertion_list
    duplicate_count="$(LC_ALL=C sort "$required_ids" | uniq -d | wc -l)"
    [ "$duplicate_count" -eq 0 ] || reject duplicate_required_assertion
    while IFS= read -r assertion_id; do
        exact_matches="$(grep -Fxc -- "$assertion_id" "$evidence_dir/stdout_stderr.log" || true)"
        [ "$exact_matches" -eq 1 ] || \
            reject "assertion_id_${assertion_id//[^A-Za-z0-9_.-]/_}_matches_$exact_matches"
    done < "$required_ids"
fi

(cd "$repo_root" && sha256sum -c "$evidence_dir/source_hashes.sha256" >/dev/null 2>&1) || reject source_manifest_not_actual

log_sha="$(sha256sum "$evidence_dir/stdout_stderr.log" | awk '{print $1}')"
pre_sha="$(sha256sum "$evidence_dir/source_hashes.sha256" | awk '{print $1}')"
post_sha="$(sha256sum "$evidence_dir/source_hashes_post.sha256" | awk '{print $1}')"
echo "EVIDENCE_GUARD_PASS test_id=$expected_test_id run_id=$expected_run_id observations=$observed failures=0 target_exit=0 log_sha256=$log_sha pre_manifest_sha256=$pre_sha post_manifest_sha256=$post_sha hashes=actual_unchanged"
