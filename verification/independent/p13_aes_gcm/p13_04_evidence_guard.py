#!/usr/bin/env python3
"""Fail-closed evidence validation against real files, raw observations and oracle.

Negative runs remain FAIL with nonzero leaf/guard/final exits. Only their caller
may classify a reached matching rejection as SELFTEST_EXPECTED_REJECTION.
"""
import argparse
import hashlib
import importlib.util
import json
import re
from pathlib import Path

NAMES = ["tb_p13_04_apb.sv", "p13_04_contract_scoreboard.sv", "p13_04_oracle_vectors.py",
         "p13_04_vectors.json", "p13_04_mutation_adapter.sv", "p13_04_evidence_guard.py",
         "p13_04_guard_selftest.py", "run_p13_04.sh"]
PREFIX = "verification/independent/p13_aes_gcm/"
VHDL = ["aes_pkg", "aes_func", "gcm_pkg", "aes_enc_dec_ctrl", "aes_round", "aes_last_round",
        "aes_kexp", "aes_ecb", "ghash_gfmul", "gcm_gctr", "gcm_ghash", "aes_icb", "aes_gcm", "top_aes_gcm"]
FAULTS = {1: "AUTH_FAIL_STATUS", 2: "ORACLE_CIPHERTEXT", 3: "ALIAS_RAZ_WI"}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def load(path):
    return json.loads(Path(path).read_text())


def reference(repo):
    spec = importlib.util.spec_from_file_location("p13_oracle", repo / PREFIX / "p13_04_oracle_vectors.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.derive()


def validate(run, repo):
    issues = []
    def require(ok, ident):
        if not ok:
            issues.append(ident)
    try:
        # inventory is untrusted: paths are confined and mandatory files named
        # independently below, so a missing file cannot disappear with its hash.
        inv = load(run / "inputs.json")
        needed = {"target.stdout", "target.stderr", "target.transcript", "target_exit.json",
                  "source_pre.json", "source_post.json", "compiled_sources.json", "lane.json",
                  "commands.json", "vcom.version.stdout", "vlog.version.stdout", "vsim.version.stdout"}
        lane = load(run / "lane.json")
        mode = lane["mode"]
        require(mode in ("actual", "sensitivity"), "UNKNOWN_LANE")
        if mode == "actual":
            needed |= {"oracle.json", "vectors.txt", "vhdl_resolution.stdout"}
        for name in needed:
            require(name in inv and (run / name).is_file(), "MISSING_REQUIRED_ARTIFACT:" + name)
        for name, digest in inv.items():
            path = run / name
            require(path.resolve().is_relative_to(run.resolve()), "ARTIFACT_SCOPE")
            require(path.is_file(), "MISSING_REQUIRED_ARTIFACT:" + name)
            if path.is_file():
                require(sha(path) == digest, "ARTIFACT_HASH:" + name)
        if issues:
            return issues
        pre, post = load(run / "source_pre.json"), load(run / "source_post.json")
        require(pre == post, "SOURCE_IDENTITY_DRIFT")
        for f, h in pre.items():
            p = repo / f
            require(p.resolve().is_relative_to(repo.resolve()) and p.is_file() and sha(p) == h,
                    "SOURCE_HASH:" + f)
        compiled = load(run / "compiled_sources.json")
        expected = [PREFIX + "p13_04_contract_scoreboard.sv"]
        if mode == "actual":
            expected = ["rtl/peripherals/aes_gcm/pipe0/" + n + ".vhd" for n in VHDL] + [
                "rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v", *expected, PREFIX + "tb_p13_04_apb.sv"]
        else:
            expected += [PREFIX + "p13_04_mutation_adapter.sv"]
        require(list(compiled) == expected, "COMPILED_SOURCE_CLOSURE")
        require(all(h == pre.get(f) and (repo / f).is_file() and sha(repo / f) == h
                    for f, h in compiled.items()), "COMPILED_SOURCE_HASH")
        rc = load(run / "target_exit.json")["exit"]
        require(type(rc) is int and rc == 0, "TARGET_EXIT")
        raw = (run / "target.stdout").read_text(errors="replace")
        transcript = (run / "target.transcript").read_text(errors="replace")
        failures = re.findall(r"ASSERT_FAIL (\w+)", raw)
        require(not failures, "SEMANTIC_ASSERTION:" + ",".join(failures))
        require(not re.search(r"\*\* (?:Error|Fatal):", raw), "SIMULATOR_ERROR")
        require("HIERARCHY_BEGIN" in transcript and "HIERARCHY_END" in transcript, "HIERARCHY_MISSING")
        for tool in ["vcom", "vlog", "vsim"]:
            require("10.5b" in (run / (tool + ".version.stdout")).read_text(), "TOOL_VERSION:" + tool)
        if mode == "sensitivity":
            require(lane["fault"] == 0, "FAULTED_LANE")
            require("SENSITIVITY_CONTROL_PASS" in raw, "CONTROL_INCOMPLETE")
            for name in FAULTS.values():
                require("ASSERT_PASS " + name in raw, "CONTROL_ASSERTION:" + name)
            require("apb_aes_gcm" not in transcript and "BOUND_INSTANCE /tb_p13_04_sensitivity/adapter" in transcript,
                    "SENSITIVITY_ISOLATION")
            return issues
        require(lane["fault"] == 0, "FUNCTIONAL_FAULT_FORBIDDEN")
        for unit in ["top_aes_gcm", "aes_gcm", "gcm_gctr", "gcm_ghash", "aes_icb", "aes_ecb", "aes_kexp", "aes_round", "aes_last_round"]:
            require(re.search(r"Loading \S*\." + unit + r"\b", raw) is not None, "GENUINE_BINDING:" + unit)
        for path in ["/dut/u_aes_gcm/u_aes_gcm/u_gcm_gctr", "/dut/u_aes_gcm/u_aes_gcm/u_gcm_ghash"]:
            require(path in transcript, "GENUINE_HIERARCHY:" + path)
        oracle = load(run / "oracle.json")
        require(oracle == reference(repo) == load(repo / PREFIX / "p13_04_vectors.json"), "ORACLE_PROVENANCE")
        text = "".join(f'{v["id"]} {v["length"]} {v["key"]} {v["iv"]} '
                       f'{v["plaintext"].ljust(32,"0")} {v["ciphertext"].ljust(32,"0")} {v["tag"]} {v["aad"]}\n'
                       for v in oracle["vectors"])
        require((run / "vectors.txt").read_text() == text, "SIMULATOR_VECTOR_INPUT")
        pattern = (r"CRYPTO_CASE vector=(\d+) direction=(\d+) len=(\d+) payload=([0-9a-fA-F]{32}) "
                   r"tag=([0-9a-fA-F]{32}) status=([0-9a-fA-F]{8}) latency=(\d+) start=(\d+) done=(\d+)")
        rows = re.findall(pattern, raw)
        seen = set()
        for vid, direction, n, payload, tag, status, latency, start, done in rows:
            vid, direction, n = int(vid), int(direction), int(n)
            require((vid, direction) not in seen, "DUPLICATE_CRYPTO_CASE")
            seen.add((vid, direction))
            require(0 <= vid < 34 and direction in (0, 1), "CRYPTO_CASE_ID")
            if not 0 <= vid < 34 or direction not in (0, 1):
                continue
            v = oracle["vectors"][vid]
            require(n == v["length"], "CRYPTO_LENGTH")
            want = v["plaintext"] if direction else v["ciphertext"]
            require(payload.lower()[:2*n] == want, "ORACLE_PAYLOAD")
            require(tag.lower() == v["tag"], "ORACLE_TAG")
            require(int(status, 16) == 6, "CRYPTO_STATUS")
            require(int(done) - int(start) == int(latency) and int(latency) > 0, "ACTUAL_LATENCY")
        require(seen == {(v, d) for v in range(34) for d in range(2)} and len(rows) == 68,
                "ALL_LEN_COVERAGE")
        for ident in [2, 3, 4, 5, 6, 7, 8, 9, 11]:
            require(f"CASE_PASS DV04-{ident:02}" in raw, f"DV04-{ident:02}_INCOMPLETE")
        for ident in ["AUTH_FAIL_STATUS", "FULL_LEN_STORAGE", "INVALID_NO_CORE_ACTIVATION",
                      "BUSY_IMMUTABLE", "SAME_EDGE_ALIGNMENT", "EARLIEST_APB_READMISSION",
                      "ZEROIZE_REAL_RESET_WIDTH", "SENSITIVE_ZERO", "RESET_NO_REVIVAL", "ALIAS_RAZ_WI",
                      "BUSY_COMMAND_INPUTS_RETAINED", "BUSY_COMMAND_DIRECTION", "MALFORMED_INPUTS_RETAINED",
                      "CLR_TAG_RETAINED", "CLR_HDR_RETAINED", "CLR_NO_CORE_RESET", "RO_STATUS_WRITE"]:
            require("ASSERT_PASS " + ident in raw, "REQUIRED_ASSERTION:" + ident)
        for ident in range(4):
            require(re.search(rf"NEGATIVE_CASE AUTH_{ident} status=0000009a\b", raw) is not None, "AUTH_NEGATIVE_COVERAGE")
        for ident in range(16):
            require(re.search(rf"NEGATIVE_CASE BUSY_WORD_{ident} status=0000022e\b", raw) is not None, "BUSY_WORD_COVERAGE")
        require("CASE_NOT_RUN DV04-10 NATURAL_32BIT_ICB_OVERFLOW" in raw, "OVERFLOW_CLAIM_BOUNDARY")
        require("SUMMARY_PASS cases=68" in raw, "TARGET_INCOMPLETE")
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        issues.append("MALFORMED_OR_MISSING_EVIDENCE:" + str(exc))
    return issues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=Path, required=True)
    ap.add_argument("--repo", type=Path, required=True)
    args = ap.parse_args()
    issues = validate(args.run, args.repo)
    print(json.dumps({"guard_exit": 1 if issues else 0, "issues": issues}))
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main())
