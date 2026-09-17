#!/usr/bin/env python3
"""Validate and hash a prepared eight-file review package. Does not invent evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

REQUIRED=('complete_change_audit.tsv','implementation.diff','reviewable_implementation.diff','source_traceability.md','execution_evidence_index.md','security_scan_report.md','acceptance_matrix.json','implementation_report.md')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package-dir',required=True,type=Path)
    p.add_argument('--output',required=True,type=Path)
    a=p.parse_args()
    folder=a.package_dir.resolve(strict=True)
    output=a.output.resolve()
    if output.is_relative_to(folder):
        p.error('manifest output must be outside package directory to avoid self-reference')
    found=[]; problems=[]
    for name in REQUIRED:
        f=folder/name
        if f.is_symlink() or not f.is_file() or f.stat().st_size==0:
            problems.append(f'missing, empty or symlink: {name}'); continue
        raw=f.read_bytes()
        found.append({'path':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
    for name in ('acceptance_matrix.json','security_scan_report.md'):
        f=folder/name
        if f.is_file() and not f.is_symlink() and name.endswith('.json'):
            try: json.loads(f.read_text(encoding='utf-8'))
            except (ValueError,UnicodeError) as e: problems.append(f'invalid JSON {name}: {e}')
    output.parent.mkdir(parents=True,exist_ok=True)
    record={'status':'PACKAGE_COMPLETE_UNREVIEWED' if not problems else 'BLOCKED','files':found,'problems':problems,'note':'Completeness and hashes only; no code, assertions or security approval inferred.'}
    output.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f"REVIEW_PACKAGE: {record['status']}; files={len(found)}/{len(REQUIRED)}")
    return 0 if not problems else 1


if __name__=='__main__':
    sys.exit(main())
