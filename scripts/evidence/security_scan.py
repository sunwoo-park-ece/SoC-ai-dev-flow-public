#!/usr/bin/env python3
"""Conservative pre-publication heuristic scanner; human inspection is mandatory."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

FORBIDDEN_EXT={'.sof','.pof','.mif','.elf','.qip','.qsys','.sopcinfo','.pkl','.pickle','.vcd','.fst','.wlf','.key','.pem'}
PATTERNS={
 'private_key':r'-----BEGIN (?:OPENSSH|RSA|EC|DSA|PRIVATE) PRIVATE KEY-----',
 'credential_assignment':r'(?im)^\s*(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s<>]{8,}',
 'github_token':r'gh[pousr]_[A-Za-z0-9_]{20,}',
 'local_home_path':r'(?i)(?:/home/[A-Za-z0-9._-]+/|/Users/[A-Za-z0-9._-]+/|[A-Z]:\\\\Users\\\\[^\\\\\s]+)',
 'vendor_license':r'(?i)(?:LM_LICENSE_FILE|license[_-]?server)\s*[:=]\s*\S+',
 'excluded_diff':r'(?im)^diff --git a/[^\n]*(?:dhrystone|benchmark)[^\n]* b/',
}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report',required=True,type=Path)
    p.add_argument('files',nargs='+',type=Path)
    a=p.parse_args()
    findings=[]; audited=[]
    for file in a.files:
        name=str(file)
        if file.is_symlink() or not file.is_file():
            findings.append({'file':name,'reason':'missing/symlink/non-regular'}); continue
        if file.suffix.lower() in FORBIDDEN_EXT or re.search(r'(?i)(?:^|[/\\])(?:dhrystone|benchmark)(?:[/\\]|$)',name):
            findings.append({'file':name,'reason':'forbidden file name/extension'}); continue
        raw=file.read_bytes(); sha=hashlib.sha256(raw).hexdigest()
        if b'\x00' in raw or len(raw)>2_000_000:
            findings.append({'file':name,'reason':'binary or over 2 MB'}); continue
        try: text=raw.decode('utf-8')
        except UnicodeDecodeError:
            findings.append({'file':name,'reason':'not UTF-8'}); continue
        audited.append({'file':name,'sha256':sha,'bytes':len(raw)})
        for label,pattern in PATTERNS.items():
            if re.search(pattern,text):
                findings.append({'file':name,'reason':label})
    status='PASS_HEURISTIC_ONLY' if not findings else 'BLOCKED'
    a.report.parent.mkdir(parents=True,exist_ok=True)
    a.report.write_text(json.dumps({'status':status,'files':audited,'findings':findings,'human_review_required':True},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'SECURITY_SCAN: {status}; files={len(audited)}; findings={len(findings)}')
    return 0 if not findings else 1


if __name__=='__main__':
    sys.exit(main())
