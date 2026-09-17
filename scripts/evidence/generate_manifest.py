#!/usr/bin/env python3
"""Hash explicitly declared inputs. No implicit 'entire checkout' claims."""
import argparse
import hashlib
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def input_path(root, name):
    if Path(name).is_absolute() or '..' in Path(name).parts:
        raise ValueError(f'Input must be a repository-relative path: {name}')
    path = root / name
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
        raise ValueError(f'Not a regular in-root file: {name}')
    return path


def manifest(root, names):
    if not names:
        raise ValueError('Supply --file for every relevant source/test/script/image input')
    return ''.join(f'{sha256(input_path(root, name))}  {name}\n'
                   for name in sorted(set(names)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', required=True, type=Path)
    ap.add_argument('--file', action='append', required=True)
    ap.add_argument('--output', required=True, type=Path)
    args = ap.parse_args()
    root = args.root.resolve(strict=True)
    if not root.is_dir():
        ap.error('--root must be a directory')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(manifest(root, args.file), encoding='utf-8')


if __name__ == '__main__':
    main()
