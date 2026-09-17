# Evidence tooling (candidate, isolated branch)

This directory contains generic tooling, not proof of P08B acceptance. Review and integrate separately from the uncommitted P08B candidate. Python 3.10+ and Bash required. Do not commit generated evidence to either Git repository.

## Quick start

Create an input list outside the source checkout containing one repository-relative input file per line. Enumerate all result-affecting RTL/FW/TB/scripts/spec/image inputs explicitly; the tool cannot discover hidden dependencies.

```bash
scripts/evidence/run_with_evidence.sh \
  --archive "$RUN_ARCHIVE" --source-root "$PWD" --inputs /tmp/sources.list \
  --task-id example --test-id example-pass -- bash -c 'echo ASSERT_CHECKED; exit 0'
```

Each invocation gets an immutable new run directory with `command.txt`, `exit_code.txt`, `stdout_stderr.log`, `source_hashes.sha256`, `result.json`, `assertion_observations.md`. A zero exit code is **EVIDENCE_INSUFFICIENT** until a separate checker assesses assertions and AC coverage. Nonzero is FAIL. `source_hashes.sha256` hashes *only the explicit input list*. Runs and reports are local-only.

```bash
python3 scripts/evidence/security_scan.py --report /tmp/scan.json reviewable.diff implementation_report.md
python3 scripts/evidence/generate_review_package.py --package-dir /path/outside/git/review --output /path/outside/git/package_manifest.json
```

`security_scan.py` is conservative heuristic preflight, **not** a guarantee of no secret/vendor content. Human review and the task allowlist remain mandatory; never push automatically from these tools. `generate_review_package.py` validates all eight required files, their non-empty status and computes SHA-256; it does **not** invent diff, code traceability or a PASS verdict. Missing documents fail closed.

Integration gates: dry-run failed/successful command, verify real exit code under tee, inspect log hash and source identity; check security scanner known-positive fixture, reject missing review artifact. The developer must still review repository policy and connect tools to real P08B runners. Vendor/STA/board remain separate.
