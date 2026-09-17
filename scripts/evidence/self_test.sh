#!/usr/bin/env bash
# Offline tests; no SoC DUT, vendor tool or board evidence is implied.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/source" "$tmp/archive" "$tmp/review"
echo 'module fixture; endmodule' > "$tmp/source/fixture.v"
echo fixture.v > "$tmp/inputs.txt"

# Exit 0 must not automatically imply AC PASS.
bash "$here/run_with_evidence.sh" --archive "$tmp/archive" --source-root "$tmp/source" --inputs "$tmp/inputs.txt" --task-id smoke --test-id success -- bash -c 'echo ASSERTION_NOT_ASSESSED; exit 0' > "$tmp/success.out"
success_result=$(find "$tmp/archive/smoke" -name result.json -print -quit)
python3 - "$success_result" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); r=json.loads(p.read_text())
assert r['exit_code']==0 and r['result']=='EVIDENCE_INSUFFICIENT'
assert all((p.parent/f).is_file() for f in ('command.txt','exit_code.txt','stdout_stderr.log','source_hashes.sha256','result.json','assertion_observations.md'))
PY

# A command failing under tee must preserve original exit 7 and fail the wrapper.
set +e
bash "$here/run_with_evidence.sh" --archive "$tmp/archive" --source-root "$tmp/source" --inputs "$tmp/inputs.txt" --task-id smoke --test-id failure -- bash -c 'echo deliberate_failure; exit 7' > "$tmp/failure.out"
rc=$?
set -e
[[ "$rc" -eq 7 ]] || { echo "ERROR: expected exit 7, got $rc" >&2; exit 1; }
failed=$(grep -l '"test_id": "failure"' "$tmp/archive"/smoke/*/result.json)
python3 - "$failed" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); r=json.loads(p.read_text())
assert r['exit_code']==7 and r['result']=='FAIL' and (p.parent/'exit_code.txt').read_text().strip()=='7'
PY

# Scanner must distinguish an ordinary document from an obvious secret.
echo 'review: no credentials included' > "$tmp/safe.md"
python3 "$here/security_scan.py" --report "$tmp/safe.json" "$tmp/safe.md" > /dev/null
echo 'api_key=abcdefghijklmnopqrstuv' > "$tmp/unsafe.md"
if python3 "$here/security_scan.py" --report "$tmp/unsafe.json" "$tmp/unsafe.md" > /dev/null; then
  echo 'ERROR: scanner accepted obvious credential fixture' >&2; exit 1
fi

# Package validator must reject missing files and accept eight nonempty inputs as UNREVIEWED.
if python3 "$here/generate_review_package.py" --package-dir "$tmp/review" --output "$tmp/missing.json" > /dev/null; then
  echo 'ERROR: missing review files accepted' >&2; exit 1
fi
for f in complete_change_audit.tsv implementation.diff reviewable_implementation.diff source_traceability.md execution_evidence_index.md security_scan_report.md implementation_report.md; do echo 'fixture' > "$tmp/review/$f"; done
echo '{"criteria":[]}' > "$tmp/review/acceptance_matrix.json"
python3 "$here/generate_review_package.py" --package-dir "$tmp/review" --output "$tmp/package.json" > /dev/null
python3 - "$tmp/package.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r['status']=='PACKAGE_COMPLETE_UNREVIEWED' and len(r['files'])==8
PY
echo 'PASS evidence helpers offline smoke; NOT a hardware/SoC verification result'
