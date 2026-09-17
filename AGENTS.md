# Repository Working Rules

- `spec/` is the canonical engineering contract; `spec/baseline_cleanup.md` is the cleanup tracker.
- Preserve the P08B Gate 0 STOP until the trap-vector/firmware endpoint policy is approved and implemented.
- Do not claim Clean Baseline release, board acceptance, or vendor timing closure without the corresponding public evidence.
- Vendor-generated IP, raw runs, private task archives, machine-local configuration, and credentials are outside this repository.
- `benchmark_main.c`, `dhrystone_main.c`, and `dhrystone_t410n.c` are intentionally excluded. Benchmark reports require separate provenance and terminology review before publication.
- Keep English canonical specifications and Korean companions synchronized for substantive contract changes.
- Do not commit, tag, push, publish, or resume P08B implementation without explicit owner approval.

## Mandatory anti-cosmetic implementation and verification rules

**All implementation, DV, evidence, and review agents (Codex, Antigravity/Claude/Gemini, and successors) MUST read and follow [`docs/governance/anti_cosmetic_verification_policy.md`](docs/governance/anti_cosmetic_verification_policy.md) in full before starting an authorized task.** Read the task's pinned revision and source identities too. This policy adds evidence/quality requirements only; it does not expand authorized file scope, lift an existing STOP gate, or approve a commit, push, release, or Issue closure. If the task and policy conflict, STOP and request a scoped decision rather than silently overriding either.

Minimum enforceable checks:

1. For every acceptance criterion, map approved contract -> independent oracle -> triggering stimulus -> assertion/checker -> unique run/source identity -> raw evidence -> verdict. Recording or printing a field is not checking it.
2. Prove a newly added or materially changed checker rejects a targeted counterexample as well as accepting a valid case. Do not mutate approved Production source or historical evidence; use isolated fixtures when authorized.
3. Avoid circular expected values, manually seeded 'independent' ledgers, aggregate count/PASS-string substitutes, optimistic status constants, suppressed failures, and unsupported verification claims.
4. Trace real failure propagation from leaf test through runner/guard/parent to final CLI exit and every final report. A failed guard with a successful target must never leave exit 0 or contradictory PASS evidence.
5. Compute manifests and hashes from actual files, keep immutable target logs separate from guard logs, and cross-check final JSON/Markdown/exits/source identity. Preserve each failed attempt and honestly mark `FAIL`, `NOT_RUN`, or `EVIDENCE_INSUFFICIENT`.
6. Before reporting completion, identify a concrete plausible defect that could still pass and show how the checker rejects it or report the gap. Self-reported PASS never replaces independent review and owner approval.
