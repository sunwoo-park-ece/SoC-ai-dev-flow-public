#!/usr/bin/env python3
"""Produce local audit/diffs and evidence-linked, NOT self-approved, review files."""
import argparse
import csv
import difflib
import json
from pathlib import Path
from generate_manifest import sha256
from security_scan import scan


def paths(root):
    return {p.relative_to(root).as_posix() for p in root.rglob('*')
            if p.is_file() and '.git' not in p.relative_to(root).parts}


def text(path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 2_000_000:
        return None
    data = path.read_bytes()
    if b'\0' in data:
        return None
    try:
        return data.decode('utf-8').splitlines(keepends=True)
    except UnicodeError:
        return None


def diff_for(base, candidate, names):
    output = []
    for name in sorted(names):
        before = text(base / name)
        after = text(candidate / name)
        if before is None and (base / name).exists() or after is None and (candidate / name).exists():
            output.append(f'Binary/oversize/symlink file differs: {name}\n')
            continue
        if before != after:
            output.extend(difflib.unified_diff(before or [], after or [],
                          fromfile=f'a/{name}', tofile=f'b/{name}'))
    return ''.join(output)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('base', 'candidate', 'output', 'allowlist', 'ac-file', 'run-root'):
        ap.add_argument('--' + name, type=Path, required=True)
    args = ap.parse_args()
    base, cand = args.base.resolve(strict=True), args.candidate.resolve(strict=True)
    out = args.output.resolve()
    if not base.is_dir() or not cand.is_dir() or out.is_relative_to(base) or out.is_relative_to(cand):
        ap.error('base/candidate must be directories; output must be outside both trees')
    out.mkdir(parents=True, exist_ok=True)
    allow = set()
    for line in args.allowlist.read_text(encoding='utf-8').splitlines():
        name = line.strip()
        if not name or name.startswith('#'):
            continue
        p = Path(name)
        if p.is_absolute() or '..' in p.parts or '.git' in p.parts:
            ap.error(f'unsafe allowlist entry: {name}')
        allow.add(p.as_posix())
    if not allow:
        ap.error('allowlist is empty')
    existing = paths(base) | paths(cand)
    unknown = allow - existing
    if unknown:
        ap.error(f'allowlist paths not found: {sorted(unknown)}')
    with (out / 'complete_change_audit.tsv').open('w', encoding='utf-8', newline='') as f:
        writer = csv.writer(f, delimiter='\t')
        writer.writerow(['path', 'status', 'before_sha256', 'after_sha256', 'scope', 'reviewed'])
        for name in sorted(existing):
            b, c = base/name, cand/name
            bsha = sha256(b) if b.is_file() else ''
            csha = sha256(c) if c.is_file() else ''
            if bsha == csha:
                continue
            status = 'ADDED' if not b.exists() else 'REMOVED' if not c.exists() else 'MODIFIED'
            writer.writerow([name, status, bsha, csha, 'ALLOWLIST' if name in allow else 'OUT_OF_SCOPE', 'NO'])
    (out/'implementation.diff').write_text(diff_for(base, cand, existing), encoding='utf-8')
    review = out/'reviewable_implementation.diff'
    review.write_text(diff_for(base, cand, allow), encoding='utf-8')
    # Also scan original allowlisted source paths, including binary and excluded path checks.
    candidate_files = [n for n in allow if (cand / n).exists()]
    scan_source = scan(cand, sorted(candidate_files))
    scan_patch = scan(out, [review.name])
    safe = scan_source['status'] == 'PASS' and scan_patch['status'] == 'PASS'
    security = {'status': 'PASS' if safe else 'BLOCKED',
                'candidate_files': scan_source, 'review_diff': scan_patch,
                'note': 'No publication authorized by this tool; human approval is required.'}
    (out/'security_scan_report.md').write_text('# Security preflight\n\n```json\n' +
        json.dumps(security, indent=2, ensure_ascii=False)+'\n```\n', encoding='utf-8')
    if not safe:
        review.unlink()  # Unsafe patch must not be accidentally published.
    acs = json.loads(args.ac_file.read_text(encoding='utf-8'))
    if not isinstance(acs, list) or any(not isinstance(a, dict) or not a.get('id') for a in acs):
        ap.error('ac-file must be list of objects with id')
    runs = []
    for result in sorted(args.run_root.rglob('result.json')):
        try:
            data = json.loads(result.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        logs = result.parent/'stdout_stderr.log'
        verified = logs.is_file() and data.get('log_sha256') == sha256(logs)
        runs.append({'run_id': data.get('run_id'), 'test_id': data.get('test_id'),
                     'result': data.get('result'), 'exit_code': data.get('exit_code'),
                     'log_sha256': data.get('log_sha256'), 'log_hash_verified': verified,
                     'observations': data.get('observations', []),
                     'source_manifest_sha256': data.get('source_manifest_sha256')})
    lines = ['# Execution evidence index', '', '로컬 원본을 직접 검증한 항목과 미확인 항목을 구분한다.', '']
    for r in runs:
        lines.append(f"- {r['run_id']}: {r['test_id']} / {r['result']} / exit={r['exit_code']} / log_sha={r['log_sha256']} / hash_verified={r['log_hash_verified']}")
    (out/'execution_evidence_index.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    matrix = []
    trace = ['# AC → Test → Assertion → Run 추적 (검토 전)', '']
    for ac in acs:
        matched = [(r,o) for r in runs for o in (r['observations'] or [])
                   if isinstance(o, dict) and o.get('ac_id') == ac['id']]
        status = ('NOT_RUN' if not matched else 'FAIL' if any(r['result']=='FAIL' for r,o in matched)
                  else 'EVIDENCE_INSUFFICIENT')
        # Review package generator NEVER auto-promotes any AC to PASS.
        matrix.append({'id': ac['id'], 'requirement': ac.get('requirement',''), 'status': status,
                       'runs': [r['run_id'] for r,o in matched], 'review_required': True})
        trace.append(f"- {ac['id']}: {status}; run_ids={','.join(x['run_id'] for x,o in matched) or 'none'}; source/test/assertion reviewer mapping required")
    (out/'acceptance_matrix.json').write_text(json.dumps(matrix, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    (out/'source_traceability.md').write_text('\n'.join(trace)+'\n', encoding='utf-8')
    (out/'implementation_report.md').write_text('# Implementation review draft\n\n'
        '실행 자동 수집은 리뷰 승인 아님. AC별 소스·assertion·원본 근거 검토 후 상태를 확정할 것.\n\n'
        f'- Run count: {len(runs)}\n- Security scan: {security["status"]}\n'
        '- Vendor/board: NOT_RUN unless separate new evidence exists.\n', encoding='utf-8')
    print(f'PACKAGE={out} SECURITY={security["status"]} AC_AUTO_PASS=0 RUNS={len(runs)}')
    raise SystemExit(0 if safe else 2)


if __name__ == '__main__':
    main()
