# Engineering Case Studies

This directory contains in-depth problem-solving narratives, root-cause investigations, architectural trade-offs, and lessons learned across the SoC lifecycle.

---

## 1. Case Study Index

| Case ID | Title / Scope | Status | Link |
|---|---|---|---|
| **CS-009** | P08B VGA hardware-clear / W1C contract and smoke evidence | VERIFIED functional scope | [CS-009-p08b-vga-hwclear-w1c.md](CS-009-p08b-vga-hwclear-w1c.md) |

---

## 2. Authoring Guidelines and Purpose

Specifications under `spec/` define *what the system must do right now*. Case studies under `docs/engineering/` preserve *why the system was designed this way*, documenting:

```text
Symptom / Failure Mode
      ↓
Root-Cause Analysis
      ↓
Constraints & Design Forces
      ↓
Alternatives Evaluated (with pros/cons)
      ↓
Design Decision or Conscious STOP
      ↓
Empirical Verification & Lessons Learned
```

### Permitted Case Statuses
- `OPEN_INVESTIGATION`: Defect actively being analyzed.
- `BLOCKED_DECISION_REQUIRED`: Structural trade-off requiring human architectural decision.
- `IMPLEMENTED_VERIFICATION_PENDING`: Candidate fix in place, formal DV in progress.
- `VERIFIED`: Complete fix substantiated by verified evidence package.
- `CLOSED_WITH_LIMITATION`: Fixed for defined operational envelope with documented gaps.
- `DEFERRED`: Addressed in a future milestone.

> **Honest Engineering Value:** Not every case study ends in immediate resolution. Documenting a critical incompatibility and halting flawed implementation (a conscious STOP) represents sound engineering judgment.

---

## 3. Standard Case Study Template

When authoring a new case study, use filename `CS-<NNN>-<short-slug>.md` and follow this structure:

```markdown
# CS-<NNN> — <Case Title>

## 1. Status
- Status: `VERIFIED | BLOCKED_DECISION_REQUIRED | ...`
- Related Requirements: `<IDs>`
- Current Source Revision: `<commit SHA>`
- Author / Owner: `<Name>`

## 2. Executive Summary
Concise summary (5 to 10 sentences) explaining the problem, root cause, chosen resolution or conscious STOP decision, and results.

## 3. Problem / Symptom
- Observed anomalies and reproduction conditions.
- System-level impact and failure manifestations.

## 4. Constraints
- Preserved interfaces, clock/reset domains, and vendor IP boundaries.
- Resource, timing, and compatibility constraints.

## 5. Root-Cause Analysis
- Structural mechanisms creating the defect.
- Code-level evidence and falsified initial hypotheses.

## 6. Alternatives Considered
| Alternative | Pros | Cons / Risks | Decision |
|---|---|---|---|
| A | ... | ... | Adopted |
| B | ... | ... | Rejected |

## 7. Design Decision
Chosen architecture and technical rationale. Link to `docs/decisions/ADR-*.md` if the architectural impact is enduring.

## 8. Implementation
Key state machines, signal handshakes, and modified module scopes.

## 9. Verification Strategy
Acceptance criteria, directed stimulus, assertions, and counterexample tests.

## 10. Results
Empirically verified metrics (resource, timing, simulation outcomes). Do not estimate.

## 11. Limitations / Remaining Work
Unproven boundaries, follow-up tracker items, or residual risks.

## 12. Lessons Learned
Reusable architectural or debugging insights.

## 13. References
Relative links to `spec/...`, `docs/decisions/...`, `rtl/...`, and `reports/evidence/...`.
```
