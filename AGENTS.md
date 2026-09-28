# Repository Working Rules

- `spec/` is the canonical engineering contract for this public repository.
- `spec/baseline_cleanup.md` is the active Baseline Cleanup tracker.
- P08B functional scope is VERIFIED; active CDC and timing-closure work is tracked under P12-VGA-CDC-AES unless the current tracker/task says otherwise.
- Do not claim Clean Baseline release, board acceptance, vendor timing closure or publication readiness without the corresponding accepted public evidence.
- Vendor-generated IP, raw runs, private task archives, machine-local configuration and credentials are outside this repository.
- `benchmark_main.c`, `dhrystone_main.c`, and `dhrystone_t410n.c` are intentionally excluded. Benchmark reports require separate provenance and terminology review before publication.
- Keep English canonical specifications and Korean companions synchronized for substantive contract changes.
- Do not commit, merge, tag, push, publish, release or claim closure on active feature work without explicit applicable owner authorization and the required evidence.

## Progressive Task and Policy Routing

Read the target worktree's pinned active task / Issue revision and Execution Profile,
then the owning spec and relevant tracker rows.

Before edits:
- confirm repository/worktree identity;
- confirm branch and pinned source revision;
- confirm dirty state;
- confirm active task authority;
- confirm authorized write scope.

Task profiles route selected gates; they do not override spec contracts, Gate 0 /
Hard STOP gates, repository boundaries or owner authorization.

### Conditional Governance Routing

Read only the policies triggered by the current task.

| Trigger | Required policy |
|---|---|
| `SPEC`, spec freeze, normative spec creation or substantive contract edit | `docs/governance/spec_authoring_policy.md` |
| `DEEP`, `deep_verification_policy: true`, independent DV, new/materially changed checker/runner/evidence guard, VERIFIED promotion, evidence/closure review | `docs/governance/anti_cosmetic_verification_policy.md` |
| engineering report/evidence authoring or reconciliation, evidence promotion, closure/publication reporting | `docs/governance/reporting_policy.md` |
| `VENDOR`, `VENDOR_BUILD`, `STA_REVIEW`, `BOARD`, `BOARD_ACCEPTANCE`, `CHARACTERIZE`, `CHARACTERIZATION`, vendor/physical evidence handling | `docs/governance/vendor_board_evidence_policy.md` |
| `PUBLISH`, `PUBLICATION`, `RELEASE`, public release preparation | `docs/governance/git_release_policy.md` |

Triggers are cumulative.
If one task activates multiple rows, read every applicable policy.

Do not load unrelated deep policies by default.

Reading a policy does not:
- expand active task scope;
- change a frozen contract;
- activate a deferred gate;
- grant commit/merge/push/tag/publication/release authority.

### Always-On Anti-Cosmetic Core

For all agents and all engineering tasks:

- Recorded != Checked; a printed/logged field is not an assertion.
- DUT output != automatically independent oracle; expectations must come from contract, an independent reference, or independently constructed observation.
- PASS string / exit 0 alone != proof.
- Process exit status != semantic engineering verdict.
- Test asset != accepted evidence.
- Do not suppress, hide, overwrite or cosmetically convert failures.
- Preserve end-to-end failure propagation.
- Claim only actually executed work and the evidence level it supports.
- Self-reported PASS != independent review or owner acceptance.
- Simulation PASS != board PASS.
- Vendor compile PASS != CDC correctness.
- Positive internal WNS != external I/O timing closure.

### Full Anti-Cosmetic Policy Trigger

Read `docs/governance/anti_cosmetic_verification_policy.md` **in full before work**
when any condition applies:

- `verification.depth: DEEP`;
- `deep_verification_policy: true`;
- new or materially changed checker, runner or evidence guard;
- independent DV task or `INDEPENDENT_DV` gate;
- requirement/tracker promotion to `VERIFIED`;
- evidence or closure review;
- explicit task request.

The full policy remains unchanged and binding when triggered:

```text
contract
→ independent oracle
→ stimulus
→ checker
→ unique source/run identity
→ raw evidence
→ semantic verdict
```

Apply valid-case and targeted counterexample tests, end-to-end failure propagation,
actual source/run identity and mutually consistent final reports as required.

HIGH risk alone does not automatically trigger the full anti-cosmetic policy.

These requirements do not expand scope or lift a STOP/publication gate.
On conflict, STOP and request a scoped decision.
Unrelated soft findings are recorded for follow-up.

### Spec Authoring Routing

When `docs/governance/spec_authoring_policy.md` is triggered:
- write observable engineering contracts rather than implementation recipes unless implementation is itself part of the contract;
- preserve English canonical / Korean companion semantic consistency;
- separate confirmed contract from unresolved questions;
- do not silently convert observed legacy RTL behavior into normative behavior;
- do not change a frozen interface outside explicit spec-change authority.

### Reporting Routing

When `docs/governance/reporting_policy.md` is triggered:
- bind reports to the actual source/run identity required by the policy;
- distinguish process exit status from semantic verdict;
- distinguish hashes/checksums from Git commit SHA;
- do not report pending/unperformed publication as completed publication;
- treat mutation of evidence after identity capture according to the reporting policy;
- do not place private/local-only vendor IP paths, secrets or restricted raw artifacts into public reports/manifests;
- identify oracle/reference provenance where required.

### Vendor / Board Evidence Routing

When `docs/governance/vendor_board_evidence_policy.md` is triggered:
- preserve owner-operated defaults for long vendor build and physical JTAG/board actions unless explicitly delegated;
- keep raw vendor runs and licensed/generated vendor artifacts local-only;
- bind public evidence to sanitized/reproducible report outputs;
- distinguish compile/fitter success, STA result, CDC correctness, board acceptance and characterization claims;
- do not claim external I/O timing closure from internal core WNS alone.

### Publication / Release Routing

When `docs/governance/git_release_policy.md` is triggered:
- run the required provenance/sanitization/public-private-boundary checks;
- verify that local absolute paths, hostnames, credentials, vendor proprietary/generated artifacts and private task data are not published;
- preserve the distinction between technical acceptance and publication/release authorization;
- require explicit owner approval for commit/merge/push/tag/release/Issue closure as applicable.

## Repository Boundary

Allowed in this public repository:
- portable RTL / firmware
- canonical specification
- public/open DV assets
- sanitized evidence
- public governance
- approved public documentation

Not allowed:
- private task packets / internal review history
- raw run directories / waveforms
- vendor project databases
- generated/licensed vendor IP
- credentials / secrets
- machine-local bindings
- unsanitized private paths or restricted provenance

## Worktree and Source Identity

Use only the authorized target worktree for production changes.
Never concurrently edit the same worktree from multiple agents.

Before production edits verify:
- expected branch;
- pinned source revision or approved reason for unpinned state;
- clean/expected dirty state;
- correct public/private repository boundary.

Unexpected dirty production state or wrong branch/worktree is a Hard STOP unless the
active task explicitly accounts for it.

## Completion Boundary

Report:
- source identity used;
- files changed;
- verification actually run;
- policy routes activated;
- evidence claim level achieved;
- Hard STOPs / soft findings;
- remaining unproven or deferred gates;
- Git/publication actions actually performed.

Default completion is:

```text
RESULT ready for User/Chat review.
Do not self-accept.
Do not automatically execute the next lifecycle gate.
```

