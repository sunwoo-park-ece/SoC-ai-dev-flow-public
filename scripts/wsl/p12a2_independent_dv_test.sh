#!/usr/bin/env bash
# Parent entrypoint: preserves leaf failure and separate parent evidence.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set a fresh external RUN_ROOT}"
RUN_ROOT="$(realpath -m "$RUN_ROOT")"
case "$RUN_ROOT" in
    "$REPO_ROOT"|"$REPO_ROOT"/*) echo 'RUN_ROOT must be external' >&2; exit 2 ;;
esac
if [ -e "$RUN_ROOT" ]; then echo 'Refusing preexisting RUN_ROOT' >&2; exit 2; fi
mkdir -p "$RUN_ROOT"
set +e
RUN_ROOT="$RUN_ROOT/p12a2_independent_dv" bash "$REPO_ROOT/verification/independent/p12a2_vga_cdc/run_p12a2_regression.sh" \
    > "$RUN_ROOT/leaf.stdout" 2> "$RUN_ROOT/leaf.stderr"
leaf_exit=$?
set -e
printf '%s\n' "$leaf_exit" > "$RUN_ROOT/parent-final-exit.txt"
python3 - "$RUN_ROOT" "$leaf_exit" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); rc=int(sys.argv[2])
result={'leaf_exit':rc,'parent_final_exit':rc,'classification':'PASS' if rc==0 else 'FAIL'}
(root/'parent-result.json').write_text(json.dumps(result,indent=2)+'\n')
files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file()}
(root/'parent-file-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print('PARENT:',result['classification'],'final_exit='+str(rc))
PY
exit "$leaf_exit"
