#!/usr/bin/env python3
"""Conservative publication preflight. A clean result is not a security guarantee."""
import argparse
import json
import re
from pathlib import Path

DENIED_PARTS = {'.git', '.serena', '__pycache__', 'vendor', 'benchmark', 'dhrystone'}
DENIED_SUFFIX = {'.sof', '.pof', '.mif', '.qip', '.qsys', '.elf', '.bin', '.vcd', '.fst', '.wlf', '.pem', '.key', '.pkl'}
PATTERNS = {
    'private_key': re.compile(r'-----BEGIN (?:OPENSSH|RSA|EC|DSA|PRIVATE) [^-]*KEY-----'),
    'token_assignment': re.compile(r'(?i)\b(?:api[_-]?key|access[_-]?token|secret[_-]?key|password)\s*[:=]\s*[\x22\x27]?[^\s\x22\x27<>]{8,}'),
    'github_token': re.compile(r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b'),
    'user_home': re.compile(r'/(?:home|Users)/[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\'),
    'license_server': re.compile(r'(?i)\b(?:LM_LICENSE_FILE|license[_-]?server)\s*[:=]\s*\S+'),
}


def inspect(path, relative, max_bytes):
    findings = []
    parts = {part.lower() for part in relative.parts}
    if parts & DENIED_PARTS or path.suffix.lower() in DENIED_SUFFIX or path.name.lower().startswith('.env'):
        findings.append('excluded_path_or_extension')
    if path.is_symlink() or not path.is_file():
        return findings + ['not_regular_file']
    if path.stat().st_size > max_bytes:
        return findings + ['exceeds_size_limit']
    raw = path.read_bytes()
    if b'\x00' in raw:
        return findings + ['binary_content']
    try:
        text = raw.decode('utf-8')
    except UnicodeError:
        return findings + ['non_utf8']
    for name, regex in PATTERNS.items():
        if regex.search(text):
            findings.append(name)
    return findings


def scan(root, paths, max_bytes=2_000_000):
    root = root.resolve(strict=True)
    results = []
    for name in paths:
        rel = Path(name)
        if rel.is_absolute() or '..' in rel.parts:
            results.append({'file': str(name), 'findings': ['unsafe_relative_path']})
            continue
        path = root / rel
        if not path.exists() or not path.resolve().is_relative_to(root):
            issues = ['missing_or_escape']
        else:
            issues = inspect(path, rel, max_bytes)
        results.append({'file': rel.as_posix(), 'findings': issues})
    return {'status': 'PASS' if all(not r['findings'] for r in results) else 'BLOCKED',
            'files': results,
            'disclaimer': 'Pattern-based preflight only; independent human review required.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--file', action='append', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = scan(args.root, args.file)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(report['status'])
    raise SystemExit(0 if report['status'] == 'PASS' else 2)


if __name__ == '__main__':
    main()
