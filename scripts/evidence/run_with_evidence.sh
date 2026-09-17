#!/usr/bin/env bash
# Run one command; retain a unique immutable-at-creation run directory.
set -euo pipefail
usage() { echo 'Usage: run_with_evidence.sh --run-root ABS_DIR --task ID --test ID --source-root REPO --input REL_PATH [--input REL_PATH ...] -- command [args...]' >&2; exit 2; }
root='' task='' test_id='' src=''; inputs=()
while (($#)); do
  case "$1" in
    --run-root) (($#>=2)) || usage; root=$2; shift 2 ;;
    --task) (($#>=2)) || usage; task=$2; shift 2 ;;
    --test) (($#>=2)) || usage; test_id=$2; shift 2 ;;
    --source-root) (($#>=2)) || usage; src=$2; shift 2 ;;
    --input) (($#>=2)) || usage; inputs+=(--file "$2"); shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[[ -n "$root" && "$root" = /* && -n "$src" && -d "$src" && -n "$task" && -n "$test_id" && ${#inputs[@]} -gt 0 && $# -gt 0 ]] || usage
[[ "$task" =~ ^[A-Za-z0-9_-]+$ && "$test_id" =~ ^[A-Za-z0-9_-]+$ ]] || usage
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
src=$(cd -- "$src" && pwd -P)
mkdir -p -- "$root"
root=$(cd -- "$root" && pwd -P)
# Never write raw logs inside any Git worktree, including a separate private repo.
if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo 'ERROR: run root is inside a Git worktree; choose an external archive' >&2; exit 2
fi
[[ "$root/" != "$src/"* ]] || { echo 'ERROR: archive is in source root' >&2; exit 2; }
run_dir=$(mktemp -d "$root/${task}_${test_id}_$(date -u +%Y%m%dT%H%M%SZ)_XXXXXXXX")
python3 "$script_dir/generate_manifest.py" --root "$src" "${inputs[@]}" --output "$run_dir/source_hashes.sha256"
cp "$run_dir/source_hashes.sha256" "$run_dir/before.sha256"
{
  printf 'cwd: %q\ncommand: ' "$src"
  printf '%q ' "$@"; printf '\n'
} > "$run_dir/command.txt"
export EVIDENCE_RUN_DIR="$run_dir"
set +e
(cd -- "$src" && "$@") > "$run_dir/stdout_stderr.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$run_dir/exit_code.txt"
python3 "$script_dir/generate_manifest.py" --root "$src" "${inputs[@]}" --output "$run_dir/after.sha256"
python3 - "$run_dir" "$test_id" "$status" <<'PY'
import hashlib, json, sys
from pathlib import Path
p, test, status = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
def hash_file(f): return hashlib.sha256(f.read_bytes()).hexdigest()
pre, post = (p / 'before.sha256').read_bytes(), (p / 'after.sha256').read_bytes()
changed = pre != post
assertion_file = p / 'assertions.json'  # The test, not this wrapper, must create it.
try:
    assertions = json.loads(assertion_file.read_text(encoding='utf-8')) if assertion_file.is_file() else None
except (ValueError, OSError):
    assertions = None
obs = assertions.get('observations', []) if isinstance(assertions, dict) else []
counts_ok = isinstance(assertions, dict) and type(assertions.get('assertions_passed')) is int and type(assertions.get('assertions_failed')) is int
valid_obs = bool(obs) and isinstance(obs, list) and all(isinstance(o, dict) and all(o.get(k) is not None for k in ('ac_id','assertion_id','observed','expected')) for o in obs)
if status != 0 or (counts_ok and assertions['assertions_failed'] > 0):
    result = 'FAIL'
elif changed or not (counts_ok and assertions['assertions_passed'] > 0 and assertions['assertions_failed'] == 0 and assertions.get('coverage_complete') is True and valid_obs):
    result = 'EVIDENCE_INSUFFICIENT'
else:
    result = 'PASS'
notes = []
if changed: notes.append('declared inputs changed during execution')
if not assertion_file.is_file(): notes.append('test did not generate assertions.json; exit 0 alone is not proof')
if not valid_obs: notes.append('missing per-AC assertion observations')
report = {'run_id': p.name, 'test_id': test, 'exit_code': status, 'result': result,
          'source_manifest_sha256': hashlib.sha256(pre).hexdigest(),
          'source_changed_during_run': changed, 'log_sha256': hash_file(p/'stdout_stderr.log'),
          'assertions_passed': assertions.get('assertions_passed') if counts_ok else None,
          'assertions_failed': assertions.get('assertions_failed') if counts_ok else None,
          'observations': obs if valid_obs else [], 'limitations': notes}
(p/'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
lines = ['# 실제 Assertion 관찰 (시험이 작성한 JSON 기반)', '', f'Classification: {result}', '']
for o in report['observations']:
    lines.append(f"- {o['ac_id']} / {o['assertion_id']}: observed={o['observed']!r}, expected={o['expected']!r}")
if not report['observations']: lines.append('실제 assertion 관찰 없음. PASS 주장 불가.')
lines += ['', '## 제약', *[f'- {n}' for n in notes]]
(p/'assertion_observations.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
print(json.dumps({'run_directory': str(p), 'result': result, 'exit_code': status}, ensure_ascii=False))
PY
rm -- "$run_dir/before.sha256" "$run_dir/after.sha256"
exit "$status"
