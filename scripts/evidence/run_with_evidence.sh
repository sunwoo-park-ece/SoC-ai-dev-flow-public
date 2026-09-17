#!/usr/bin/env bash
# Capture a command and the ACTUAL process exit code. Never infer AC PASS from exit 0.
set -euo pipefail
usage() { echo 'Usage: run_with_evidence.sh --archive DIR --source-root DIR --inputs FILE --task-id ID --test-id ID -- COMMAND [ARGS...]' >&2; exit 2; }
archive='' source='' inputs='' task='' testid=''
while (($#)); do
  case "$1" in
    --archive) (($# >= 2)) || usage; archive=$2; shift 2;;
    --source-root) (($# >= 2)) || usage; source=$2; shift 2;;
    --inputs) (($# >= 2)) || usage; inputs=$2; shift 2;;
    --task-id) (($# >= 2)) || usage; task=$2; shift 2;;
    --test-id) (($# >= 2)) || usage; testid=$2; shift 2;;
    --) shift; break;;
    *) usage;;
  esac
done
[[ -n "$archive" && -n "$source" && -n "$inputs" && -n "$task" && -n "$testid" && $# -gt 0 ]] || usage
[[ "$task" =~ ^[A-Za-z0-9_-]+$ && "$testid" =~ ^[A-Za-z0-9_-]+$ ]] || usage
source=$(realpath -e -- "$source"); archive=$(realpath -m -- "$archive")
[[ "$archive" != "$source" && "$archive" != "$source"/* ]] || { echo 'Archive must be outside source checkout' >&2; exit 2; }
[[ -f "$inputs" ]] || { echo 'Missing inputs list' >&2; exit 2; }
run_id="$(date -u +%Y%m%dT%H%M%S%N)-$$"; run_dir="$archive/$task/$run_id"
(umask 077; mkdir -p -- "$run_dir")
scriptdir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
printf '%q ' "$@" > "$run_dir/command.txt"; printf '\n' >> "$run_dir/command.txt"
printf 'test_id=%q\nsource_root=%q\n' "$testid" "$source" >> "$run_dir/command.txt"
if ! python3 "$scriptdir/generate_manifest.py" --source-root "$source" --inputs "$inputs" --output "$run_dir/source_hashes.sha256" > "$run_dir/manifest.log" 2>&1; then
  echo 125 > "$run_dir/exit_code.txt"; cp "$run_dir/manifest.log" "$run_dir/stdout_stderr.log"
  echo 'Input manifest failed. Test NOT_RUN.' > "$run_dir/assertion_observations.md"
  python3 - "$run_dir" "$testid" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); (p/'result.json').write_text(json.dumps({'run_id':p.name,'test_id':sys.argv[2],'exit_code':125,'result':'NOT_RUN','reason':'manifest preflight failed'},indent=2)+'\n')
PY
  echo "RUN_DIR=$run_dir RESULT=NOT_RUN" >&2; exit 125
fi
start=$(date -u +%FT%TZ)
set +e
"$@" 2>&1 | tee "$run_dir/stdout_stderr.log"
rc=${PIPESTATUS[0]}
set -e
end=$(date -u +%FT%TZ)
printf '%s\n' "$rc" > "$run_dir/exit_code.txt"
echo 'NOT_REVIEWED: AC별 assertion/coverage 평가 후에만 PASS로 승격할 수 있음.' > "$run_dir/assertion_observations.md"
python3 - "$run_dir" "$testid" "$start" "$end" "$rc" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); sha=lambda x:hashlib.sha256((p/x).read_bytes()).hexdigest()
r={'run_id':p.name,'test_id':sys.argv[2],'start_utc':sys.argv[3],'end_utc':sys.argv[4],'exit_code':int(sys.argv[5]),'source_manifest_sha256':sha('source_hashes.sha256'),'log_sha256':sha('stdout_stderr.log'),'assertions_passed':None,'assertions_failed':None,'result':'EVIDENCE_INSUFFICIENT' if int(sys.argv[5])==0 else 'FAIL','reason':'AC/assertion review required' if int(sys.argv[5])==0 else 'command exited nonzero'}
(p/'result.json').write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
echo "RUN_DIR=$run_dir EXIT_CODE=$rc"
exit "$rc"
