# Repository Working Rules

- `spec/` is the canonical engineering contract; `spec/baseline_cleanup.md` is the cleanup tracker.
- P08B functional scope is VERIFIED; active CDC and timing closure tasks are tracked under P12-VGA-CDC-AES.
- Do not claim Clean Baseline release, board acceptance, or vendor timing closure without the corresponding public evidence.
- Vendor-generated IP, raw runs, private task archives, machine-local configuration, and credentials are outside this repository.
- `benchmark_main.c`, `dhrystone_main.c`, and `dhrystone_t410n.c` are intentionally excluded. Benchmark reports require separate provenance and terminology review before publication.
- Keep English canonical specifications and Korean companions synchronized for substantive contract changes.
- Do not commit, tag, push, publish, or claim closure on active feature work (P12-VGA-CDC-AES) without explicit owner approval and raw evidence.

## Progressive task and policy routing

Read the target worktree's pinned active task / Issue revision and Execution Profile,
then the owning spec and relevant tracker rows. Confirm branch, source identity and
dirty state before edits. Task profiles route selected gates; they do not override
spec contracts, Gate 0 STOP gates, repository boundaries or owner authorization.

Always-on anti-cosmetic core (all agents):

- Recorded != checked; a printed field is not an assertion.
- DUT output != automatically independent oracle; derive expectations from contract
  and independent stimulus/observations.
- PASS string / exit 0 alone != proof; connect claims to actual source and raw evidence.
- Do not suppress, hide or overwrite failures; preserve failure propagation.
- Claim only actually executed work and the evidence level it supports.
- Self-reported PASS != independent review or owner acceptance.

Read [`docs/governance/anti_cosmetic_verification_policy.md`](docs/governance/anti_cosmetic_verification_policy.md)
**in full before work** when any condition applies:

- `verification.depth: DEEP` or `deep_verification_policy: true`;
- new or materially changed checker, runner or evidence guard;
- independent DV task;
- requirement promotion to VERIFIED;
- evidence or closure review;
- explicit task request.

The full policy remains unchanged and binding when triggered: contract -> independent
oracle -> stimulus -> checker -> unique source/run identity -> raw evidence -> verdict;
valid-case and targeted counterexample tests; end-to-end failure propagation;
actual file hashes and mutually consistent final reports. Read pinned revisions too.
These requirements do not expand scope or lift a STOP/publication gate. On a conflict,
STOP and request a scoped decision. Unrelated soft findings are recorded for follow-up.
