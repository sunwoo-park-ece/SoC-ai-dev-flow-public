#!/usr/bin/env python3
"""Real leaf/runner/guard rejection tests, using fresh isolated run products.

Expected failures retain nonzero result/exit in each child. Parent checks the
specific semantic rejection and reach before classifying it as expected.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--run", type=Path, required=True)
    args = ap.parse_args()
    base = args.repo / "verification/independent/p13_aes_gcm"
    spec = importlib.util.spec_from_file_location("guard", base / "p13_04_evidence_guard.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    root = args.run / "selftests"
    root.mkdir(exist_ok=False)
    results = []
    def launch(argv, directory, env=None):
        directory.mkdir(exist_ok=False)
        with (directory / "parent.stdout").open("wb") as out, (directory / "parent.stderr").open("wb") as err:
            proc = subprocess.run(list(map(str, argv)), cwd=directory, stdout=out, stderr=err,
                                  env=env, timeout=120)
        g.save(directory / "parent_command.json", {"argv": list(map(str, argv)), "exit": proc.returncode})
        return proc.returncode
    def record(name, ok, **kwargs):
        results.append(dict(name=name, status="SELFTEST_EXPECTED_REJECTION" if ok else "FAIL", **kwargs))
        g.save(root / "results.json", results)
        if not ok:
            raise ValueError("SELFTEST_FAILED:" + name)
    # Same real runner, independent library containing no production hierarchy.
    for fault in range(4):
        directory = root / ("sensitivity_" + str(fault))
        env = dict(os.environ, RUN_ROOT=str(directory / "run"))
        rc = launch(["bash", base / "run_p13_04.sh", "--mode", "sensitivity", "--fault", str(fault)], directory, env)
        child = directory / "run"
        result = g.load(child / "result.json")
        raw = (child / "target.stdout").read_text()
        assertions = re.findall(r"ASSERT_FAIL (\w+)", raw)
        if fault == 0:
            ok = rc == result["target_exit"] == result["guard_exit"] == result["final_exit"] == 0
            ok = ok and not assertions and "SENSITIVITY_CONTROL_PASS" in raw
            results.append(dict(name="SENSITIVITY_GOOD_CONTROL", status="PASS" if ok else "FAIL", exits=result))
            g.save(root / "results.json", results)
            if not ok:
                raise ValueError("SENSITIVITY_GOOD_CONTROL")
        else:
            ok = rc != 0 and result["target_exit"] != 0 and result["guard_exit"] != 0 and result["final_exit"] != 0
            ok = ok and assertions == [g.FAULTS[fault]] and f"MUTATION_REACH fault={fault} " in raw
            ok = ok and "ASSERT_PASS INJECTION_REACHED" in raw and "SENSITIVITY_CONTROL_PASS" not in raw
            record("M04-0" + str(fault), ok, exits=result, named_failure=assertions, raw_sha256=g.sha(child / "target.stdout"))
    # Real runner must propagate a guard failure even though real vsim passed.
    for negative, reason in [("missing", "MISSING_REQUIRED_ARTIFACT:target.transcript"),
                             ("tamper", "ARTIFACT_HASH:target.stdout")]:
        directory = root / ("runner_guard_" + negative)
        env = dict(os.environ, RUN_ROOT=str(directory / "run"))
        rc = launch(["bash", base / "run_p13_04.sh", "--mode", "sensitivity", "--negative", negative], directory, env)
        child = directory / "run"
        result = g.load(child / "result.json")
        issues = g.load(child / "guard.stdout")["issues"]
        record("M04-04_" + negative, rc != 0 and result["target_exit"] == 0 and
               result["guard_exit"] != 0 and result["final_exit"] != 0 and reason in issues,
               exits=result, issues=issues)
    # Guard semantic tests use copies of successful functional evidence. Adjust
    # the copy's hash only when intentionally testing a deeper semantic parser.
    inv = g.load(args.run / "inputs.json")
    changes = [
        ("missing_raw", "MISSING_REQUIRED_ARTIFACT:target.stdout"),
        ("raw_hash", "ARTIFACT_HASH:target.stdout"),
        ("payload", "ORACLE_PAYLOAD"), ("tag", "ORACLE_TAG"),
        ("status", "CRYPTO_STATUS"), ("latency", "ACTUAL_LATENCY"),
        ("missing_case", "ALL_LEN_COVERAGE"),
        ("compiled", "COMPILED_SOURCE_CLOSURE"),
        ("source", "SOURCE_IDENTITY_DRIFT"),
        ("masked_exit", "TARGET_EXIT"),
        ("oracle", "ORACLE_PROVENANCE"),
        ("missing_assertion", "REQUIRED_ASSERTION:BUSY_COMMAND_INPUTS_RETAINED"),
    ]
    for name, reason in changes:
        directory = root / ("guard_" + name)
        directory.mkdir()
        evidence = directory / "evidence"
        evidence.mkdir()
        for n in [*inv, "inputs.json"]:
            if name == "missing_raw" and n == "target.stdout":
                continue
            shutil.copyfile(args.run / n, evidence / n)
        changed = None
        if name in ("raw_hash", "payload", "tag", "status", "latency", "missing_case", "missing_assertion"):
            changed = "target.stdout"
            raw = (evidence / changed).read_text()
            if name == "raw_hash":
                raw += "\nBAD_ARTIFACT_COPY\n"
            elif name == "missing_case":
                raw = re.sub(r"[^\n]*CRYPTO_CASE vector=0 direction=0[^\n]*\n", "", raw)
            elif name == "missing_assertion":
                raw = raw.replace("ASSERT_PASS BUSY_COMMAND_INPUTS_RETAINED", "ASSERT_SKIPPED BUSY_COMMAND_INPUTS_RETAINED")
            elif name == "payload":
                raw = re.sub(r"(CRYPTO_CASE vector=1 direction=0 len=1 payload=)[0-9a-fA-F]{32}", r"\g<1>ffffffffffffffffffffffffffffffff", raw)
            elif name == "tag":
                raw = re.sub(r"(CRYPTO_CASE vector=0 direction=0[^\n]* tag=)[0-9a-fA-F]{32}", r"\g<1>ffffffffffffffffffffffffffffffff", raw)
            elif name == "status":
                raw = raw.replace("status=00000006", "status=00000002", 1)
            else:
                raw = re.sub(r"(CRYPTO_CASE vector=0 direction=0[^\n]* latency=)\d+", r"\g<1>999", raw)
            (evidence / changed).write_text(raw)
        elif name == "compiled":
            changed = "compiled_sources.json"
            data = g.load(evidence / changed)
            data.pop(next(iter(data)))
            g.save(evidence / changed, data)
        elif name == "source":
            changed = "source_post.json"
            data = g.load(evidence / changed)
            data[next(iter(data))] = "0" * 64
            g.save(evidence / changed, data)
        elif name == "masked_exit":
            changed = "target_exit.json"
            g.save(evidence / changed, {"exit": 17})
        elif name == "oracle":
            changed = "oracle.json"
            data = g.load(evidence / changed)
            data["cryptography"] = "WRONG_ORACLE_PROVENANCE"
            g.save(evidence / changed, data)
        if changed and name != "raw_hash":
            new_inv = dict(inv)
            new_inv[changed] = g.sha(evidence / changed)
            g.save(evidence / "inputs.json", new_inv)
        rc = launch(["python3", "-B", base / "p13_04_evidence_guard.py", "--repo", args.repo, "--run", evidence], directory / "process")
        report = g.load(directory / "process/parent.stdout")
        record("GUARD_" + name, rc != 0 and reason in report["issues"], issues=report["issues"], exit=rc)
    # Owner-authorized correction regression: run the preserved erroneous script
    # read-only and require its original named rejection, never a normal PASS.
    preserved = os.environ.get("P13_PRESERVED_ORACLE")
    if not preserved:
        raise ValueError("PRESERVED_ORACLE_REQUIRED")
    directory = root / "original_bad_kat"
    rc = launch(["python3", "-B", preserved], directory)
    err = (directory / "parent.stderr").read_text()
    record("ORIGINAL_KAT_LITERAL", rc != 0 and "ValueError: STANDARD_KAT_MISMATCH" in err,
           exit=rc, preserved_source_sha256=g.sha(preserved))
    print(json.dumps({"status": "PASS", "entries": len(results), "results": results}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
