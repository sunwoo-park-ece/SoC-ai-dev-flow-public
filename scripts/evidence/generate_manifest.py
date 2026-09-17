#!/usr/bin/env python3
"""Hash an explicit list of repository-relative inputs; no implicit dependency discovery."""
import argparse
import hashlib
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source-root', type=Path, required=True)
    ap.add_argument('--inputs', type=Path, required=True, help='UTF-8 file with one relative source path per line')
    ap.add_argument('--output', type=Path, required=True)
    a = ap.parse_args()
    root = a.source_root.resolve(strict=True)
    if not a.inputs.is_file():
        ap.error('missing inputs file')
    paths = []
    for row in a.inputs.read_text(encoding='utf-8').splitlines():
        s = row.strip()
        if not s or s.startswith('#'):
            continue
        rel = Path(s)
        target = root / rel
        if rel.is_absolute() or '..' in rel.parts or target.is_symlink() or not target.is_file() or not target.resolve().is_relative_to(root):
            ap.error(f'unsafe or missing input: {s}')
        paths.append((rel.as_posix(), target))
    if not paths or len({p for p, _ in paths}) != len(paths):
        ap.error('input list must contain unique existing regular files')
    out = a.output.resolve()
    if out.is_relative_to(root):
        ap.error('output must be outside source checkout')
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for rel, f in sorted(paths):
        h = hashlib.sha256()
        with f.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(chunk)
        lines.append(f'{h.hexdigest()}  {rel}')
    out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'MANIFEST: {len(lines)} inputs')


if __name__ == '__main__':
    main()
