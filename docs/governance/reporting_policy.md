# Engineering Reporting and Evidence Packaging Policy

> **Scope:** Public engineering evidence under `reports/evidence/` and private internal engineering reporting.  
> **Status:** Active Project Governance.  
> **Canonical Language:** English. Korean companion files (`*.ko.md`) maintain semantic equivalence.

---

## 1. Evidence Packaging Philosophy

Engineering claims must be substantiated by immutable, reproducible, and sanitized evidence.

```text
Private Canonical Evidence                Public Derivative Package
---------------------------               -------------------------
<FEATURE>_REPORT.md             --->      summary.md (Executive overview)
verification_matrix_<feature>.json --->   result.json (Machine-readable verdicts)
Local file hashes               --->      source_hashes.sha256 (Source integrity)
Raw simulator / vendor logs     --->      RETAINED IN LOCAL runs/ ONLY
```

- **Verification Assets vs Evidence:** Executable testbenches and scripts (`verification/`, `scripts/`) prove *how to reproduce* behavior; evidence packages (`reports/evidence/`) document *what approved results were achieved* against an exact Git source identity.
- **Sanitized Derivatives:** Public evidence is derived from private execution records through an explicit sanitization process. Raw run logs, machine-local absolute paths, vendor-proprietary databases, and credentials must never appear in public evidence.

---

## 2. Directory Structure Under `reports/evidence/`

Public evidence packages reside in stable, feature- or subsystem-centric directories:

```text
reports/evidence/
├── README.md                          # Global evidence catalog and summary index
├── bus-access-fault/
│   ├── summary.md
│   ├── result.json
│   └── source_hashes.sha256
├── cpu-retirement/
│   ├── summary.md
│   ├── result.json
│   └── source_hashes.sha256
└── p08b-gate0/                        # Honest reporting of Gate 0 STOP outcomes
    ├── summary.md
    ├── result.json
    └── source_hashes.sha256
```

- **Stable Naming:** Use feature names (`bus-access-fault`), not transient project phase numbers (`phase4a_step3`).
- **Index Catalog:** `reports/evidence/README.md` must index every package with its verified source SHA, requirement IDs, and verdict.

### Status Definitions and Verdict Semantics
- **Exit Code != Semantic Verdict:** A process exit code may be zero or non-zero depending on tool and test-runner semantics, and does not automatically determine the semantic engineering verdict. Semantic engineering verdicts are evaluated independently against specification contracts. For example, reproducing a known negative case or architectural incompatibility may result in a non-zero exit code from a raw testbench or zero from a dedicated checker, yet represents the valid engineering verdict `PASS_INCOMPATIBILITY_REPRODUCED`. Conversely, a tool exiting with code 0 when assertions were bypassed, masked, or unexecuted does NOT constitute a `PASS`.
- **Status Classification:**
  - `APPROVED`: Evidence package reviewed and accepted against an immutable public commit SHA.
  - `PENDING_REVIEW`: Completed evidence package awaiting independent review.
  - `PENDING_PUBLIC_COMMIT`: Used during development when verification is complete against local working files or a feature branch, but the public documentation/source commit SHA has not yet been formed. Public evidence packages must not be finalized as `APPROVED` with a missing or uncommitted SHA; they must be marked `PENDING_PUBLIC_COMMIT` and updated prior to publication.
  - `REJECTED` / `BLOCKED`: Verification failed or prerequisite gate unavailable.

---

## 3. Evidence Specification: `summary.md`

`summary.md` provides an executive summary enabling external reviewers to assess verified scope, methodology, reproduction commands, and limitations quickly.

```markdown
# <Evidence Package Title>

## 1. Status
- Evidence ID: `<PREFIX>-EV-<NN>`
- Requirements: `<REQ-001>`, `<REQ-002>`
- Criteria: `<PREFIX>-AC-01..NN`
- Result: `PASS | CONDITIONAL_PASS | FAIL | STOP`
- Review Status: `APPROVED | PENDING_REVIEW | PENDING_PUBLIC_COMMIT | REJECTED`
- Verified Source Revision: `<40-character Git commit SHA | PENDING_PUBLIC_COMMIT>`
- Evidence Date: `<YYYY-MM-DD>`

## 2. Scope
Concise, exact description of the verified function and its architectural boundaries.

## 3. Claim
Explicit statement of what this package substantiates (and nothing more).

## 4. Method
- Testbench: `verification/.../tb_*.sv`
- Runner: `scripts/wsl/<runner>.sh`
- Simulator / Tool: `<Tool name and version>`
- Oracle / Reference: `<Golden model, ISA specification, or protocol checker>`
- Clock / Reset / Protocol Assumptions: `<Assumptions>`

## 5. Acceptance Results
| Criterion ID | Check Description | Oracle / Reference | Result |
|---|---|---|---|
| `<PREFIX>-AC-01` | <Description> | <Spec clause / golden oracle> | PASS |

## 6. Reproduction
```bash
RUN_ROOT=/tmp/soc-runs bash scripts/wsl/<runner>.sh
```
Public reproduction commands must be self-contained and free of machine-local paths.

## 7. Source Identity
- Hash Manifest: `source_hashes.sha256` (or `source_hashes.json`)
- Result JSON: `result.json`

## 8. Limitations / Not Proven
Explicit enumeration of what was NOT proven (e.g., board signoff, CDC closure, firmware endpoints).

## 9. Related Engineering Cases
- Link to relevant `docs/engineering/CS-*.md` or `docs/decisions/ADR-*.md`.

## 10. Provenance and Sanitization
- Local host paths: Scrubbed
- Proprietary IP / licenses: Excluded
- Raw execution logs: Retained in local vault (`runs/`)
```

---

## 4. Evidence Specification: `result.json`

`result.json` provides strict machine-readable verification results.

### JSON Schema Requirements
- Valid JSON (no comments or trailing commas).
- Relative paths within the repository only.
- Unexecuted items must be explicitly marked `NOT_RUN`, `NOT_APPLICABLE`, `PENDING`, or `BLOCKED`. Never use `PASS` for unexecuted checks.
- A process exit code (zero or non-zero) does not dictate the semantic verdict; semantic results must be evaluated independently against acceptance criteria (e.g., reproducing an expected incompatibility is recorded as `PASS_INCOMPATIBILITY_REPRODUCED` regardless of raw tool exit code).
- If the public source commit has not yet been formed, record `"commit": "PENDING_PUBLIC_COMMIT"` and update it prior to publication.

### Structure Example

```json
{
  "schema_version": "1.0",
  "evidence_id": "SAF-EV-01",
  "title": "Precise AHB store access-fault verification",
  "status": "PASS",
  "review_status": "APPROVED",
  "evidence_date": "2026-09-17",
  "verified_source_revision": {
    "repository": "https://github.com/sunwoo-park-ece/SoC-ai-dev-flow-public",
    "commit": "<40-character-source-commit-sha>"
  },
  "requirements": [
    "BUS-003",
    "TRAP-003"
  ],
  "criteria": [
    {
      "id": "SAF-AC-01",
      "check": "failed store produces mcause=7",
      "result": "PASS"
    }
  ],
  "tests": [
    {
      "case_id": "SAF-TC-01",
      "testbench": "verification/directed/bus/tb_cpu_access_fault.sv",
      "runner": "scripts/wsl/bus_cpu_apb_test.sh",
      "tool": "iverilog/vvp",
      "exit_code": 0,
      "result": "PASS"
    }
  ],
  "hash_manifest": "reports/evidence/bus-access-fault/source_hashes.sha256",
  "limitations": [
    "does not prove a safe firmware trap endpoint",
    "does not constitute physical FPGA board acceptance"
  ],
  "sanitization": {
    "absolute_paths_removed": true,
    "host_identifiers_removed": true,
    "license_server_data_removed": true,
    "vendor_generated_payload_included": false
  }
}
```

### Non-Self-Referential Commit Rule
An evidence file cannot record its own future commit SHA. Therefore:
1. The source/test snapshot commit is formed first.
2. The evidence package references that verified source commit SHA.
3. The evidence package is added in a subsequent documentation commit.

---

## 5. Source Hash Manifest: `source_hashes.sha256` / `source_hashes.json`

Evidence packages must corroborate the exact integrity of all input files using standard SHA-256 hashes.

### Standard `sha256sum` Format (`source_hashes.sha256`)

```text
eb261e6346f699ddce5c6f53f28df68d50e587840a7e6bf5ce0152a834d3c87e  rtl/core/v/top/RV32I46F_5SP_MMIO.v
908a241f8022a7eee2ab7f15c1f86057ff5bcc18270f7d3805247d17376ada4a  verification/directed/bus/tb_cpu_access_fault.sv
3ad86035bf3fdb3ca639dafa045b88dd9ba70034d9bbce26a63cd93627268d68  scripts/wsl/bus_cpu_apb_test.sh
```

### JSON Format Specification (`source_hashes.json`)

When machine-readable hashing is used:

```json
{
  "schema_version": "1.0",
  "files": [
    {
      "path": "rtl/core/v/top/RV32I46F_5SP_MMIO.v",
      "sha256": "eb261e6346f699ddce5c6f53f28df68d50e587840a7e6bf5ce0152a834d3c87e"
    },
    {
      "path": "verification/directed/bus/tb_cpu_access_fault.sv",
      "sha256": "908a241f8022a7eee2ab7f15c1f86057ff5bcc18270f7d3805247d17376ada4a"
    }
  ]
}
```

### Four Hash Governance Rules
1. **Content vs Commit:** SHA-256 hashes record exact physical file content to corroborate integrity; they do not replace or substitute for Git commit SHAs.
2. **Invalidation and Regeneration:** If any verified source, testbench, runner, or model file is edited or modified after hash calculation, the hash manifest is invalidated and must be regenerated immediately.
3. **Vendor IP Exclusion:** Vendor-proprietary binaries, encrypted netlists, and tool databases must NOT be hashed into public manifests; reference them via `ip_manifest.yml` or binding names instead.
4. **Repository-Relative Paths:** Paths must be strictly relative to the public repository root. Never embed absolute host paths. Include verified RTL, firmware, testbenches, runners, and models; exclude transient outputs.

---

## 6. Pre-Publication Sanitization Checklist

Before staging or committing any public evidence package, verify the following:

- [ ] All usernames, hostnames, and IP addresses scrubbed.
- [ ] No absolute paths (`/home/swp/...`, `/mnt/...`, `C:\...`) remain.
- [ ] Credentials, access tokens, and license-server ports removed.
- [ ] Vendor-generated proprietary IP netlists and databases excluded.
- [ ] Target source commit SHA is verified and reachable.
- [ ] All file hashes in `source_hashes.sha256` match current files.
- [ ] Claims accurately reflect executed tests; unexecuted scopes labeled `NOT_RUN`.
- [ ] Explicit limitations and unproven boundaries disclosed honestly.
- [ ] Repository-relative links to specs and case studies verified.
