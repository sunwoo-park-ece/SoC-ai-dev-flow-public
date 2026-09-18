#!/usr/bin/env python3
"""Atomically finalize and independently cross-check P08B evidence metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path


FAILURE_RE = re.compile(r"FATAL:|ASSERT_FAIL|SUMMARY: FAIL|(^|\s)FAIL(\s|:)", re.M)
SUMMARY_RE = re.compile(r"^(?:ASSERT_PASS|PASS |TEST_[A-Z]:|OBSERVED|SUMMARY:|CONFIG|EDGE_OBS|TX_)", re.M)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_int(path: Path) -> int:
    text = path.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+", text):
        raise ValueError(f"invalid integer in {path.name}: {text!r}")
    return int(text)


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def parse_manifest(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise ValueError(f"invalid manifest line in {path.name}: {line!r}")
        digest, rel = match.groups()
        if rel in seen:
            raise ValueError(f"duplicate manifest path: {rel}")
        seen.add(rel)
        entries.append((digest, rel))
    if not entries:
        raise ValueError(f"empty manifest: {path.name}")
    return entries


def validate_manifests(directory: Path, root: Path) -> tuple[bool, str, str]:
    pre_path = directory / "source_hashes.sha256"
    post_path = directory / "source_hashes_post.sha256"
    pre = parse_manifest(pre_path)
    post = parse_manifest(post_path)
    unchanged = pre == post
    # The post manifest is the current on-disk truth at finalization time.
    # The pre manifest may legitimately differ after a detected source drift.
    for digest, rel in post:
        candidate = root / rel
        if not candidate.is_file() or sha256(candidate) != digest:
            raise ValueError(f"source manifest is not actual: {rel}")
    return unchanged, sha256(pre_path), sha256(post_path)


def classification(target_exit: int, guard_exit: int, consistency_exit: int | None) -> tuple[str, int, str]:
    if target_exit != 0:
        return "FAIL", target_exit, "target_failure"
    if guard_exit != 0:
        return "EVIDENCE_INSUFFICIENT", 90, "guard_failure"
    if consistency_exit not in (None, 0):
        return "EVIDENCE_INSUFFICIENT", 91, "metadata_consistency_failure"
    return "PASS", 0, "validated"


def finalize(args: argparse.Namespace) -> int:
    directory = args.directory.resolve()
    root = args.root.resolve()
    target_exit = read_int(directory / "target_exit.txt")
    if read_int(directory / "exit_code.txt") != target_exit:
        raise ValueError("exit_code.txt differs from target_exit.txt")
    guard_exit = read_int(directory / "guard_exit.txt")
    consistency_path = directory / "consistency_exit.txt"
    consistency_exit = read_int(consistency_path) if consistency_path.exists() else None
    unchanged, pre_sha, post_sha = validate_manifests(directory, root)
    log_path = directory / "stdout_stderr.log"
    if not log_path.is_file() or (target_exit == 0 and log_path.stat().st_size == 0):
        raise ValueError("missing target log or empty successful target log")
    log_sha = sha256(log_path)
    result, final_exit, reason = classification(target_exit, guard_exit, consistency_exit)
    atomic_text(directory / "final_exit.txt", f"{final_exit}\n")

    payload = {
        "run_id": directory.name,
        "test_id": args.test_id,
        "start_time": args.start_time,
        "end_time": args.end_time,
        "exit_code": target_exit,
        "target_exit": target_exit,
        "guard_exit": guard_exit,
        "consistency_exit": consistency_exit,
        "final_exit": final_exit,
        "result": result,
        "reason": reason,
        "assertions_passed": args.assertions_passed,
        "assertions_failed": args.assertions_failed,
        "source_hashes_unchanged": unchanged,
        "source_manifest_sha256": pre_sha,
        "source_manifest_post_sha256": post_sha,
        "log_sha256": log_sha,
        "limitations": args.limitation,
    }
    if args.clock_phase_ns is not None:
        payload["clock_phase_ns"] = args.clock_phase_ns
    atomic_text(directory / "result.json", json.dumps(payload, indent=2, sort_keys=True) + "\n")

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    observations = [line for line in log_text.splitlines() if SUMMARY_RE.match(line) or FAILURE_RE.search(line)]
    md = [
        "# Assertion observations",
        "",
        f"- Run ID: `{directory.name}`",
        f"- Test ID: `{args.test_id}`",
        f"- Result: `{result}`",
        f"- Reason: `{reason}`",
        f"- Target exit: `{target_exit}`",
        f"- Guard exit: `{guard_exit}`",
        f"- Consistency exit: `{'PENDING' if consistency_exit is None else consistency_exit}`",
        f"- Final exit: `{final_exit}`",
        f"- Target log SHA-256: `{log_sha}`",
        f"- Pre manifest SHA-256: `{pre_sha}`",
        f"- Post manifest SHA-256: `{post_sha}`",
        f"- Source hashes unchanged: `{'true' if unchanged else 'false'}`",
        f"- ASSERT_PASS count: `{args.assertions_passed}`",
        f"- Failure-pattern count: `{args.assertions_failed}`",
        "",
        "## Raw target observations",
        "",
    ]
    md.extend(observations or ["(none)"])
    md.extend(["", "## Limitations", ""])
    md.extend(f"- {item}" for item in args.limitation)
    atomic_text(directory / "assertion_observations.md", "\n".join(md) + "\n")
    return final_exit


def check(args: argparse.Namespace) -> int:
    directory = args.directory.resolve()
    root = args.root.resolve()
    required = [
        "command.txt", "exit_code.txt", "target_exit.txt",
        "source_hashes.sha256", "source_hashes_post.sha256", "guard_result.txt",
        "guard_exit.txt", "final_exit.txt", "result.json", "assertion_observations.md",
    ]
    for name in required:
        path = directory / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"missing or empty {name}")
    target_exit = read_int(directory / "target_exit.txt")
    log_path = directory / "stdout_stderr.log"
    if not log_path.is_file() or (target_exit == 0 and log_path.stat().st_size == 0):
        raise ValueError("missing target log or empty successful target log")
    guard_exit = read_int(directory / "guard_exit.txt")
    final_exit = read_int(directory / "final_exit.txt")
    if read_int(directory / "exit_code.txt") != target_exit:
        raise ValueError("exit_code/target_exit mismatch")
    consistency_path = directory / "consistency_exit.txt"
    consistency_exit = read_int(consistency_path) if consistency_path.exists() else None
    expected_result, expected_final, expected_reason = classification(target_exit, guard_exit, consistency_exit)
    if final_exit != expected_final:
        raise ValueError("final exit does not match target/guard/consistency exits")
    unchanged, pre_sha, post_sha = validate_manifests(directory, root)
    log_sha = sha256(directory / "stdout_stderr.log")
    guard_text = (directory / "guard_result.txt").read_text(encoding="utf-8", errors="replace")
    if guard_exit == 0 and "EVIDENCE_GUARD_PASS" not in guard_text:
        raise ValueError("guard exit 0 without PASS marker")
    if guard_exit != 0 and "EVIDENCE_GUARD_REJECT" not in guard_text:
        raise ValueError("guard nonzero without rejection marker")

    data = json.loads((directory / "result.json").read_text(encoding="utf-8"))
    for count_key in ("assertions_passed", "assertions_failed"):
        if not isinstance(data.get(count_key), int) or data[count_key] < 0:
            raise ValueError(f"invalid JSON {count_key}")
    expected = {
        "run_id": directory.name,
        "test_id": args.test_id,
        "exit_code": target_exit,
        "target_exit": target_exit,
        "guard_exit": guard_exit,
        "consistency_exit": consistency_exit,
        "final_exit": expected_final,
        "result": expected_result,
        "reason": expected_reason,
        "source_hashes_unchanged": unchanged,
        "source_manifest_sha256": pre_sha,
        "source_manifest_post_sha256": post_sha,
        "log_sha256": log_sha,
    }
    for key, value in expected.items():
        if data.get(key) != value:
            raise ValueError(f"JSON mismatch {key}: {data.get(key)!r} != {value!r}")

    md = (directory / "assertion_observations.md").read_text(encoding="utf-8")
    md_expect = [
        f"- Run ID: `{directory.name}`", f"- Test ID: `{args.test_id}`",
        f"- Result: `{expected_result}`", f"- Reason: `{expected_reason}`",
        f"- Target exit: `{target_exit}`", f"- Guard exit: `{guard_exit}`",
        f"- Consistency exit: `{'PENDING' if consistency_exit is None else consistency_exit}`",
        f"- Final exit: `{expected_final}`", f"- Target log SHA-256: `{log_sha}`",
        f"- Pre manifest SHA-256: `{pre_sha}`", f"- Post manifest SHA-256: `{post_sha}`",
        f"- Source hashes unchanged: `{'true' if unchanged else 'false'}`",
        f"- ASSERT_PASS count: `{data['assertions_passed']}`",
        f"- Failure-pattern count: `{data['assertions_failed']}`",
    ]
    for line in md_expect:
        if line not in md:
            raise ValueError(f"Markdown mismatch: {line}")
    print(f"EVIDENCE_CONSISTENCY_PASS run={directory.name} result={expected_result} final_exit={expected_final}")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    sub = top.add_subparsers(dest="action", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("directory", type=Path)
    common.add_argument("--root", required=True, type=Path)
    common.add_argument("--test-id", required=True)
    final = sub.add_parser("finalize", parents=[common])
    final.add_argument("--start-time", required=True)
    final.add_argument("--end-time", required=True)
    final.add_argument("--assertions-passed", required=True, type=int)
    final.add_argument("--assertions-failed", required=True, type=int)
    final.add_argument("--clock-phase-ns", type=int)
    final.add_argument("--limitation", action="append", default=[])
    sub.add_parser("check", parents=[common])
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return finalize(args) if args.action == "finalize" else check(args)
    except Exception as exc:
        print(f"EVIDENCE_METADATA_REJECT reason={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
