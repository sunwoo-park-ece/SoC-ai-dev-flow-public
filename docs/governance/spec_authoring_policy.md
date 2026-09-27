# Specification Authoring Policy

> **Scope:** Canonical specifications under `spec/` in the public repository.  
> **Status:** Active Project Governance.  
> **Canonical Language:** English. Korean companion files (`*.ko.md`) are maintained for semantic equivalence.

---

## 1. Role and Ownership of `spec/`

`spec/` in the public repository is the **Source of Truth for the Current Active Contract** throughout baseline cleanup and all subsequent feature development.

### What `spec/` Owns
- How the system and each subsystem must behave right now.
- Interface, signal handshake, register, and timing definitions.
- Non-negotiable safety, correctness, and architectural invariants.
- Concrete Acceptance Criteria (AC) required for a requirement to be declared `VERIFIED`.
- Current implementation status across requirements (`OPEN`, `IN_PROGRESS`, `BLOCKED`, `VERIFIED`).
- Approved target specifications and explicitly deferred items.

### What `spec/` Does NOT Own
- Ephemeral task instructions (owned by private `tasks/`).
- Long debugging narratives or conversational journals (owned by `docs/engineering/`).
- Raw simulation run logs or machine-local paths (owned by local `runs/`).
- Discarded alternatives or trade-off debates (owned by `docs/decisions/` ADRs).
- Execution records and run-specific hashes (owned by `reports/evidence/`).

---

## 2. Standard Specification Skeleton

The standard 8-part structure below is the **default and recommended standard** for canonical subsystem specifications under `spec/`. Small or focused specifications may adapt headings proportionally, but must strictly preserve the distinct semantic ownership of all core dimensions without semantic loss:
- **Status / Scope**
- **Current Active Contract**
- **Interface / Timing** (where applicable)
- **Invariants / Error Behavior**
- **Acceptance Criteria**
- **Current Requirement Status**
- **Approved Target / Deferred Work**
- **Traceability**

Under no circumstances may adapted headings eliminate or conflate these distinct normative roles:

```markdown
# <Feature / Subsystem Name> Specification

## 1. Status and Scope
## 2. Current Active Contract
## 3. Interface / Register / Timing Contract
## 4. Invariants and Error Behavior
## 5. Acceptance Criteria
## 6. Current Requirement Status
## 7. Approved Target / Deferred Work
## 8. Traceability
## Appendix A. Historical / Pre-cleanup Notes (Optional)
```

### Section Rules and Prohibitions

| Section | Normative Role | Prohibited Content |
|---|---|---|
| **1. Status & Scope** | Functional boundary and current baseline phase | Vague scope or unapproved commitments |
| **2. Current Active Contract** | Normative behavior governing the current design | Describing past bugs or legacy RTL in present tense |
| **3. Interface / Timing** | Address maps, bit definitions, handshakes, clock/reset | Raw testbench dumps or simulation logs |
| **4. Invariants & Error** | Non-negotiable safety rules and fault responses | Implementation accidents or internal workarounds |
| **5. Acceptance Criteria** | Stable conditions required for `PASS` / `VERIFIED` | Ephemeral run IDs, timestamps, local file paths |
| **6. Requirement Status** | Current state per requirement (`OPEN`, `VERIFIED`, etc.) | Unsubstantiated claims of completion |
| **7. Approved Target / Deferred** | Approved future targets and deferred items | Phrasing future targets as if already implemented |
| **8. Traceability** | Relative links to tests, evidence packages, and case studies | Absolute local paths (`/home/swp/...`, Windows drives) |
| **Appendix A. Historical Notes** | Contextual heritage preserved for design rationale | Blending legacy behaviors into the active contract |

---

## 3. Decoupling Contracts, Criteria, Status, and Evidence

To prevent circular reasoning and cosmetic verification, specification authors must distinguish four distinct concepts:

```text
Current Active Contract
    = How the system must behave right now.

Acceptance Criteria (AC)
    = Stable conditions that must be checked to declare the contract satisfied.

Current Requirement Status
    = Verdict state (OPEN, IN_PROGRESS, BLOCKED, or VERIFIED) for each requirement.

Historical / Public Evidence
    = Empirical proof (run IDs, source commit SHAs, test results) validating criteria.
```

### Identifier Taxonomy

| Identifier Type | Standard Format | Defining Location | Example |
|---|---|---|---|
| **Requirement ID** | `<SUBSYS>-<NNN>` | Owning spec & `baseline_cleanup.md` | `BUS-003`, `TRAP-003`, `VGA-001` |
| **Acceptance Criterion ID** | `<PREFIX>-AC-<NN>` | Owning spec (§5) | `SAF-AC-01`, `VGA-AC-02` |
| **Verification Case ID** | `<PREFIX>-EV-<NN>` | Public evidence package (`reports/evidence/`) | `SAF-EV-01` |
| **Run ID** | `<task>_<date>_<seq>` | Raw run vault (`runs/`) and private matrices | `p12_vga_cdc_20261001_01` |

---

## 4. Reference Example: Store-Access-Fault Contract

The following excerpt demonstrates proper decoupling in a canonical specification:

```markdown
## 2. Current Active Contract

Upon a terminal AHB ERROR response:
- Load access fault generates exception `mcause=5`.
- Store access fault generates exception `mcause=7`.
- `mepc` records the exact PC of the faulting instruction.
- Failed loads perform no register writeback.
- Failed stores produce no memory or peripheral side effects.
- Faulting instructions do not retire successfully.
- Misaligned access exceptions take precedence over bus errors.

## 5. Acceptance Criteria

| Criterion ID | Pass Condition |
|---|---|
| `SAF-AC-01` | Bus error on store generates `mcause=7`. |
| `SAF-AC-02` | `mepc` captures the faulting instruction PC precisely. |
| `SAF-AC-03` | Store bus error leaves memory and peripheral registers unmodified. |
| `SAF-AC-04` | Failed store instruction does not retire. |
| `SAF-AC-05` | Younger pipeline instructions are flushed without committing. |
| `SAF-AC-06` | Misaligned store raises cause 6 without initiating bus transaction. |
| `SAF-AC-07` | Firmware reaches an approved safe trap endpoint or fail-stop. |

## 6. Current Requirement Status

| Requirement / Criterion | Status | Validating Evidence Package |
|---|---|---|
| `BUS-003`, `SAF-AC-01..06` | VERIFIED | `../reports/evidence/bus-access-fault/summary.md` |
| `SAF-AC-07` (FW endpoint) | BLOCKED | `../reports/evidence/p08b-gate0/summary.md` |

## 8. Traceability

- Architectural Decision: `../docs/decisions/ADR-001-precise-trap-ordering.md`
- Engineering Case: `../docs/engineering/CS-001-precise-ahb-access-fault.md`
- Directed Test: `../verification/directed/bus/tb_soc_cpu_fault_e2e.sv`
- Public Evidence: `../reports/evidence/bus-access-fault/summary.md`
```

> **Key Takeaway:** Hardware precision (`SAF-AC-01..06`) can be `VERIFIED` while the firmware endpoint (`SAF-AC-07`) remains `BLOCKED`. Separating these statuses prevents false claims of overall system completion while honestly recognizing verified hardware behavior.

---

## 5. Narrative Minimization and Link Conventions

Specs must remain concise contracts. Move debugging stories, hypothesis testing, and trade-off narratives into case studies under `docs/engineering/CS-<NNN>-<title>.md`.

- Include at most 2–5 sentences of historical background in a spec.
- Link to engineering case studies for investigation history:
  ```markdown
  ### Architectural Rationale
  For problem analysis, root-cause investigation, and trade-offs leading to this contract,
  see [CS-001: Precise AHB Access Fault](../docs/engineering/CS-001-precise-ahb-access-fault.md).
  ```

### Strict Linking Rules
1. **Repository-Relative Links Only:** All Markdown links in `spec/` must use relative paths (e.g., `../docs/engineering/...`, `../reports/evidence/...`).
2. **Absolute Host Paths Prohibited:** Never include `/home/swp/...`, `/mnt/c/...`, `C:\...`, or machine-specific URLs in public specifications.

---

## 6. Relationship Between `baseline_cleanup.md` and Owning Specs

- `spec/baseline_cleanup.md` coordinates project-wide cleanup gates, tracking requirement IDs, gate severities, owners, condensed criteria, and overall statuses.
- Owning specifications (e.g., `spec/03_cpu_interface.md`, `spec/08_vga.md`) own the detailed contract, full acceptance criteria definitions, register bitfields, and invariant lists.
- If a conflict occurs between `baseline_cleanup.md` and an owning specification, the owning specification is authoritative for detailed technical behavior. Reconcile both documents promptly.

---

## 7. Procedure for Reconciling Legacy Specifications

When updating pre-cleanup specifications to the modern contract standard, follow this 10-step procedure:

1. **Audit Statements:** Classify existing text into `CURRENT` (active design), `HISTORICAL` (legacy behavior), `TARGET` (future goals), and `UNRESOLVED`.
2. **Verify Against RTL/FW:** Confirm candidate active rules against production RTL, testbenches, and verified evidence packages.
3. **Draft Current Active Contract:** State the normative behavior in Section 2, eliminating ambiguous past-tense or speculative descriptions.
4. **Formulate Acceptance Criteria:** Define atomic, verifiable pass conditions with stable IDs (`<PREFIX>-AC-<NN>`) in Section 5.
5. **Populate Status Table:** Map requirement IDs to current statuses (`OPEN`, `IN_PROGRESS`, `BLOCKED`, `VERIFIED`) with links to supporting evidence.
6. **Segregate Future Targets:** Relocate unapproved or deferred enhancements to Section 7 (`Approved Target / Deferred Work`).
7. **Extract Narratives:** Move extensive problem-solving journals, failed alternative records, and debugging logs to `docs/engineering/`.
8. **Extract Architecture Decisions:** Move enduring structural decisions to `docs/decisions/ADR-<NNN>.md`.
9. **Synchronize Companions:** Update English canonical text and Korean companion text (`*.ko.md`) in lockstep, verifying that AC IDs and register names match.
10. **Relative Link Audit:** Validate that all internal and cross-document links resolve correctly within the repository.
