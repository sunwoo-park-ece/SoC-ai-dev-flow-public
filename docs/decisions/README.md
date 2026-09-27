# Architecture Decision Records (ADRs)

This directory houses Architecture Decision Records (ADRs) that document enduring design choices, structural conventions, and trade-offs shaping the SoC architecture.

---

## 1. When to Author an ADR

Do not create ADRs for routine bug fixes or localized logic tweaks. Author an ADR when a decision introduces enduring architectural constraints or cross-cutting structural policies, such as:
- Clock and reset distribution architecture.
- Bus protocol error handling and pipeline stall policies.
- Clock-Domain Crossing (CDC) synchronization rules.
- Memory mapping and cache coherence hierarchies.
- Privilege modes and exception vector conventions.
- Public vs private repository boundary standards.

---

## 2. ADR Lifecycle and Statuses

- `PROPOSED`: Under architectural review by User + Chat.
- `ACCEPTED`: Approved by User + Chat and active across design specifications.
- `SUPERSEDED`: Replaced by a newer ADR (must cite superseding record).
- `DEFERRED`: Evaluated and postponed for subsequent project phases.

---

## 3. Standard ADR Template

New ADRs are authored as `ADR-<NNN>-<short-slug>.md` using this template:

```markdown
# ADR-<NNN> — <Decision Title>

- **Status:** `PROPOSED | ACCEPTED | SUPERSEDED | DEFERRED`
- **Date:** `<YYYY-MM-DD>`
- **Decision Owners:** `User + Chat`
- **Related Specifications / Requirements:** `<spec relative links / Requirement IDs>`

## 1. Context
What architectural forces, design constraints, and technological requirements compel this decision?

## 2. Decision
State the chosen structural approach, convention, or policy normatively.

## 3. Alternatives Considered
Summarize rejected alternatives and technical rationales concisely:

| Alternative | Technical Rationale for Rejection |
|---|---|
| Alternative A | ... |
| Alternative B | ... |

## 4. Consequences

### Positive Impacts
- Architectural benefits, improved modularity, or timing margins gained.

### Negative Impacts / Trade-offs
- Additional logic resources, latency penalties, or implementation complexities incurred.

## 5. Verification Impact
What new acceptance criteria, formal assertions, or verification benches are required to validate this decision?

## 6. References
- Owning Specs: `../../spec/...`
- Case Studies: `../engineering/...`
- Verified Evidence: `../../reports/evidence/...`
```
