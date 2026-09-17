# Anti-Cosmetic Implementation and Verification Policy

**Applies to:** Codex, Antigravity (including Claude/Gemini agents), and any future implementation, DV, build, or evidence agent working on this SoC project. Read this together with the repository's `AGENTS.md`, the exact approved task revision, and the approved specifications. This policy strengthens how an agent demonstrates compliance; it **does not authorize** any extra code, repository, publishing, or release action, and cannot override a narrower task, STOP gate, or owner decision.

## 1. Solve the engineering problem, not the checklist's appearance

Before changing anything, write a short defect/requirement-to-proof map: the actual failure or missing guarantee, triggering transaction/state/timing, source/contract involved, expected correct observable behavior, and an observation that would *falsify* the proposed fix. Separate **implementation**, **test execution**, and **independent review**. A file name, flag, counter, field, assertion, comment, PASS string, or AC label does not by itself satisfy a requirement. If a contract or identity is unclear, stop rather than silently changing its meaning.

For each acceptance criterion (AC), connect: **contract/invariant -> affected implementation -> independently derived oracle -> stimulus/boundary -> assertion or checker ID -> run ID -> source identity -> raw evidence -> verdict**. A missing link means `EVIDENCE_INSUFFICIENT`, not PASS.

## 2. Prohibited cosmetic or circular techniques

Do not:

- Add a ledger, counter, assertion, JSON field, or named test without actually using it to detect the defect it claims to cover.
- Derive the expected result from the DUT's own output, the very side effect being checked, a mirrored implementation of the same faulty logic, or the manual test queue while claiming independence. An observed signal may be logged but is not automatically an oracle.
- Substitute total counts, `SUMMARY: PASS`, exit status 0, or expected constants for per-transaction/state correctness.
- Weaken stimulus, bypass a boundary condition, modify the approved contract, disable assertions, or silently classify an actual failure as an expected rejection to obtain PASS.
- Hide failures with `|| true`, filters, ignored child exits, optimistic defaults, stale files, conditional skips, or an unconditional successful process exit. Capture expected nonzero exits explicitly and assert the expected failure mechanism.
- Edit Production RTL/FW, specifications, old evidence, or publication scope merely to make a test pass without the task's explicit authorization.
- Claim that a lint, simulation, static CDC, timing, fit, board, or independent review ran without its own real execution evidence.

## 3. Prove that the check can reject the defect

Every newly added or materially changed checker/guard must demonstrate both a valid-case PASS and a **targeted counterexample rejection**. Prefer reproducing the pre-fix bug with the same directed stimulus and then observing post-fix behavior. When appropriate, use mutation or malformed-evidence fixtures in isolated copies, never mutate the approved Production candidate or historical run archive. Verify fixture injection actually reached the intended layer. Record the injected fault, expected outcome, observed assertion/exit/report, source identity, and run ID. An intentional rejection is `SELFTEST_EXPECTED_REJECTION` only when the specific injected failure was detected; it must not count as a normal DUT PASS. If defect reproduction is infeasible, state the limitation and use `EVIDENCE_INSUFFICIENT` for the unsupported claim.

## 4. End-to-end failure propagation

Trace the **actual** path: stimulus -> DUT/target -> observation/monitor -> checker -> runner -> guard -> parent/regression orchestrator -> final exit -> JSON/Markdown report. Enumerate all relevant callers, including legacy compatibility routes and exceptional/error paths. Failure at any required layer must produce a final nonzero exit and a non-PASS final report, including the case `target_exit=0` but evidence guard fails. Keep `target_exit`, `guard_exit`, `final_exit`, and final classification separate. Preserve original target failure reason/code; a wrapper failure must not overwrite it with an apparent success. Test failure injection at the real leaf runners **and** parent orchestration, not just the guard's unit test.

## 5. Independent protocol and side-effect verification

Generate transaction identities and predicted behavior from **accepted interface transactions and the approved contract**, not from manual expected-write calls or internal completion results. For a pipelined bus, model address acceptance, data-phase ownership, HREADY stalls, ERROR wait/final phases, back-to-back activity, resets/recovery, and same-edge completion/next acceptance correctly. Associate each ID with address, direction, size, write data, response, side-effect address/data/bank/count, and completion state as relevant. Derive expected ownership/bank from a reference state machine or stable documented initial conditions; observe the DUT's bank only to cross-check it. Require exactly one correct commit for an accepted OKAY framebuffer write, zero for ERROR, no orphan/duplicate commit, no front-bank corruption, and no outstanding transfers at test end. Aggregate count agreement is supplementary, never sufficient. Explicitly document scope and any unverifiable field.

## 6. Evidence must be real, immutable, and mutually consistent

Preserve original target stdout/stderr without appending guard output; preserve failed and superseded attempts under distinct run IDs outside Git. Capture actual command, tools/versions, timing/seed/timeout, source pre/post manifests and full SHA-256, raw-log SHA-256, assertion IDs/coverage, and exits. Validate manifests against **real files**, not merely against each other; compute `source_hashes_unchanged` from observed equality, never write it as a constant. Validate all required artifacts, parse and cross-check identity and field semantics (not just JSON syntax), and reject absent/stale/tampered data.

Build provisional metadata if necessary, run the guard, then atomically finalize the status in **every** representation (`result.json`, assertion observations, exit files, indexes). Perform a separate read-only consistency check of final artifacts without self-referential hashes or an endless verification cycle. A consistency-check failure is nonzero and non-PASS; interrupted or incomplete runs remain `INCOMPLETE` or `EVIDENCE_INSUFFICIENT`, never a stale PASS. A passing target with a failing guard must never yield final exit 0 or contradictory PASS Markdown. The result is valid only for the stated source and actual run; do not inherit past PASS after changing code or a runner.

## 7. Before reporting completion: adversarial review

Ask: **"What plausible defect would still pass this test?"** Check at least one concrete counterexample per materially changed check, then add an appropriate negative test or explicitly state why it is not covered. Re-examine every AC for required fields that are only recorded, printed, or copied, rather than asserted. Inspect the *actual task delta* separately from the larger candidate-vs-public baseline diff. Never call a review-only Git commit the local uncommitted candidate's source commit. Distinguish direct execution from reading another agent's report; label unexecuted checks `NOT_RUN` and unsupported conclusions `EVIDENCE_INSUFFICIENT`.

## 8. Mandatory final acceptance map and stop

Report each AC as `PASS`, `FAIL`, `NOT_RUN`, or `EVIDENCE_INSUFFICIENT`, with exact source identity, checker/assertion IDs, unique run ID, raw-log full SHA-256, target/guard/final exit, and remaining risk. Cite actual changed files/lines and list unchanged-but-relied-on contracts. Do not auto-approve a phase, release a baseline, close its Issue, commit/push, or widen the change set without explicit approval. On a Production defect, contradictory evidence, unexplained source drift, or out-of-scope requirement, preserve raw evidence and obey the task's STOP gate.

**Review acceptance principle:** An agent's own PASS claim is a report, not an independent proof or owner approval. Independent review must inspect the contract, delta, checker independence, counterexample rejection, and evidence consistency before sign-off.
