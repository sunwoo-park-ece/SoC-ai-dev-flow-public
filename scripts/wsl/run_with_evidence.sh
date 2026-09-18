#!/usr/bin/env bash
set -u

if [ "$#" -lt 4 ] || [ "$3" != "--" ]; then
    echo "usage: $0 TEST_ID EVIDENCE_DIR -- COMMAND [ARG ...]" >&2
    exit 2
fi
test_id="$1"
evidence_dir="$2"
shift 3
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$(realpath -m "$evidence_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'EVIDENCE_DIR must be external' >&2; exit 2 ;;
esac
if [ -e "$evidence_dir" ]; then
    echo "Refusing to overwrite evidence: $evidence_dir" >&2
    exit 2
fi
mkdir -p "$evidence_dir"
cd "$repo_root" || exit 2

{
    echo "TEST_ID=$test_id"
    echo 'WORKDIR=<PUBLIC_CANDIDATE_ROOT>'
    printf 'COMMAND='; printf '%q ' "$@"; printf '\n'
    echo "BASH_VERSION=$BASH_VERSION"
    command -v iverilog >/dev/null 2>&1 && echo "IVERILOG_VERSION=$(iverilog -V 2>&1 | head -n 1)"
    command -v verilator >/dev/null 2>&1 && echo "VERILATOR_VERSION=$(verilator --version 2>&1 | head -n 1)"
    echo 'CLOCK_CONFIG=runner-defined'
    echo 'SEED=runner-defined/deterministic unless its immutable target log states otherwise'
} > "$evidence_dir/command.txt"

find . -type f \
    ! -path './.git/*' ! -path './.serena/*' ! -path './.vscode/*' \
    ! -path './firmware/apps/benchmark_main.c' \
    ! -path './firmware/apps/dhrystone_main.c' \
    ! -path './firmware/apps/dhrystone_t410n.c' \
    -printf '%P\0' | sort -z | xargs -0 sha256sum \
    > "$evidence_dir/source_hashes.sha256"
start_time="$(date --iso-8601=seconds)"
: > "$evidence_dir/stdout_stderr.log"

finish_interrupted() {
    trap - HUP INT TERM
    printf 'RUNNER_INTERRUPTED signal received\n' >> "$evidence_dir/stdout_stderr.log"
    printf '130\n' > "$evidence_dir/exit_code.txt"
    printf '130\n' > "$evidence_dir/target_exit.txt"
    find . -type f \
        ! -path './.git/*' ! -path './.serena/*' ! -path './.vscode/*' \
        ! -path './firmware/apps/benchmark_main.c' \
        ! -path './firmware/apps/dhrystone_main.c' \
        ! -path './firmware/apps/dhrystone_t410n.c' \
        -printf '%P\0' | sort -z | xargs -0 sha256sum \
        > "$evidence_dir/source_hashes_post.sha256"
    printf 'EVIDENCE_GUARD_REJECT reason=runner_interrupted\n' > "$evidence_dir/guard_result.txt"
    printf '1\n' > "$evidence_dir/guard_exit.txt"
    local pass_count fail_count
    pass_count="$(grep -c -E '(^|[[:space:]])(PASS|ASSERT_PASS)([[:space:]]|:)' "$evidence_dir/stdout_stderr.log" || true)"
    fail_count="$(grep -c -E 'FATAL:|ASSERT_FAIL|SUMMARY: FAIL|RUNNER_INTERRUPTED|(^|[[:space:]])FAIL([[:space:]]|:)' "$evidence_dir/stdout_stderr.log" || true)"
    source scripts/wsl/p08b_evidence_finalize.sh
    p08b_finalize_and_check "$repo_root" "$evidence_dir" "$test_id" \
        "$start_time" "$(date --iso-8601=seconds)" "$pass_count" "$fail_count"
    exit 130
}
trap finish_interrupted HUP INT TERM

set +e
"$@" > "$evidence_dir/stdout_stderr.log" 2>&1
target_rc=$?
set -e
trap - HUP INT TERM
printf '%s\n' "$target_rc" > "$evidence_dir/exit_code.txt"
printf '%s\n' "$target_rc" > "$evidence_dir/target_exit.txt"

find . -type f \
    ! -path './.git/*' ! -path './.serena/*' ! -path './.vscode/*' \
    ! -path './firmware/apps/benchmark_main.c' \
    ! -path './firmware/apps/dhrystone_main.c' \
    ! -path './firmware/apps/dhrystone_t410n.c' \
    -printf '%P\0' | sort -z | xargs -0 sha256sum \
    > "$evidence_dir/source_hashes_post.sha256"
required_regex="${REQUIRED_ASSERT_REGEX:-SUMMARY: PASS|^PASS }"
required_count="${REQUIRED_ASSERT_COUNT:-1}"
guard_args=("$evidence_dir" "$required_regex" "$required_count" "$test_id" "$(basename "$evidence_dir")")
if [ "${P08B_TEST_INJECT_GUARD_FAIL:-0}" = 1 ]; then
    printf 'ASSERT_PASS INJECTED-MISSING-ASSERTION\n' > "$evidence_dir/injected_required_assertions.txt"
    guard_args+=("$evidence_dir/injected_required_assertions.txt")
elif [ -n "${REQUIRED_ASSERTIONS_FILE:-}" ]; then
    guard_args+=("$REQUIRED_ASSERTIONS_FILE")
fi
set +e
scripts/wsl/p08b_evidence_guard.sh "${guard_args[@]}" \
    > "$evidence_dir/guard_result.txt" 2>&1
guard_rc=$?
set -e
printf '%s\n' "$guard_rc" > "$evidence_dir/guard_exit.txt"

assertions_passed="$(grep -c -E '(^|[[:space:]])(PASS|ASSERT_PASS)([[:space:]]|:)' "$evidence_dir/stdout_stderr.log" || true)"
assertions_failed="$(grep -c -E 'FATAL:|ASSERT_FAIL|SUMMARY: FAIL|(^|[[:space:]])FAIL([[:space:]]|:)' "$evidence_dir/stdout_stderr.log" || true)"
source scripts/wsl/p08b_evidence_finalize.sh
p08b_finalize_and_check "$repo_root" "$evidence_dir" "$test_id" \
    "$start_time" "$(date --iso-8601=seconds)" "$assertions_passed" "$assertions_failed"
exit "$P08B_FINAL_RC"
