# Physical Assurance Limitation Register

> **Status: PROPOSED / NOT_ACCEPTED.** English canonical; [Korean companion](kor/physical_assurance_limitations.ko.md). This draft is not active exception authority, device qualification or release acceptance.

## Scope and authority

This cross-module register owns limitation records and their proposed claim-disposition process. Owning subsystem specifications retain behavior, acceptance criteria and essential device assumptions; [baseline cleanup §3](baseline_cleanup.md#3-cleanup-exit-gate) retains milestone gates. A limitation record cannot change either authority.

Functional evidence, physical assurance, exception approval and release are separate decisions. Missing evidence is not a demonstrated defect, proof of safety, VERIFIED status or automatic eligibility for an exception. Existing accepted functional evidence keeps only its actual source/model scope.

## Current obligations

Required immediate write suppression, abort/recovery, no-side-effect, ownership, stale-event suppression and liveness contracts remain binding. No numeric minimum loss pulse or branch skew is introduced. No required event is excluded because it was not observed, counted by a diagnostic, or captured by a particular reset branch.

A physical fact essential to a functional proof remains a prerequisite of that proof. Calling it physical, post-baseline or limited assurance cannot remove that dependency. A demonstrated active unsafe behavior requires immediate corrective/restricted-use review, not routine scheduling or an exception.

## Evidence and claim boundary

Stable-clock operation within a valid epoch and qualified reset/release have bounded functional evidence. Logical handshake/RAM handoff reasoning is conditional on a valid epoch and applicable primitive operation. Conditional digital reset sequencing does not establish capture of every physical PLL invalidation or reset-branch ordering. Neither board photographs, diagnostic zero/counts, positive internal STA nor successful vendor compilation establishes those missing guarantees.

### C08-PHYS-001

| Field | Canonical record |
|---|---|
| ID / domain | `C08-PHYS-001` / VGA PLL, HCLK/pixel reset branches and physical VRAM write boundary |
| Physical state | `NOT_PROVEN / UNDETERMINABLE`; no active defect established by the current evidence gap |
| Exception request / acceptance | `PROPOSED / NOT_ACCEPTED`; no approval, permitted exception use or expiry has been granted |
| Owning contracts | [VGA §4/§5/§6/§7](08_vga.md), including unchanged `VGA-CDC-AC-05/06/08/09`; [reset §6.1/§13.3](06_reset_clock.md); [cleanup §23A](baseline_cleanup.md#23a-c08-physical-assurance-obligation) |
| Source boundary | [VGA wrapper](../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v), [reset helper](../rtl/soc/reset_release_sync.v), [SoC top](../rtl/soc/AMBA_SoC_TOP.v) and separately bound local MAX10 ALTPLL/M9K configuration |
| Covered functional evidence | Existing source-bound portable digital checks of captured loss/abort/diagnostics and Boolean gating; conditional common-reset recovery sequence; structural crossing completeness and logical selected-bank handoff within an established valid epoch. These are not physical qualification or full AC09 acceptance. |
| Unproved physical condition | Raw short locked-LOW detection/capture; asymmetric or late branch assertion; release/observer settling and reconvergence; loss/capture/rearm minima; edge-near AHB final response versus WE/M9K bitcell write atomicity; applicability of the free-running PLL startup/reset conditions |
| Essential dependency | R1: every required PLL invalidation effectively clears both branches and relevant state. R2: pixel READY/ACK/pending invalidation and HCLK abort/rebase precede stale-state consumption as fresh. These remain essential to AC09 and cannot receive a supplemental-claim exception. |
| Supplemental-claim eligibility | NOT_ESTABLISHED. Any separable residual physical claim must be explicitly enumerated and justified independently of R1/R2 and all mandatory gates before exception eligibility can be considered. The combined record is not a blanket exception. |
| Operating claim restrictions | Bounded established-valid-epoch functional observations only. No universal lock-loss capture, physical write-edge safety, certified board-use/deployment safety or Clean Baseline release claim. Required loss events and frozen acceptance stimuli remain in scope. |
| Severity / impact | High assurance risk: absent capture/ordering justification can invalidate the fresh-epoch ownership argument; write-edge atomicity is also unqualified. This record does not assign or lower a BC row's severity/gate class. |
| Responsible owner | VGA/clock-reset specification maintainer; board owner for physical execution; Owner retains explicit exception and release decisions |
| Scheduling | `POST_BASELINE_P12_PHYSICAL_QUALIFICATION` retains the accepted scheduling boundary only. Essential AC09 dependencies remain gating irrespective of that queue assignment. |
| Re-entry triggers | Before a physical safety claim; clock/reset/PLL/M9K/write-commit or binding change; new vendor information; lock-loss anomaly or defect; change of intended use; expiry/review due |
| Evidence needed | Exact source/IP/bitstream/board identity as applicable; primary MAX10/ALTPLL/M9K event/reset/write contracts and configuration applicability; capture and re-entry ordering justification; applicable timing/RDC with explicit gaps; independently observed targeted physical evidence where contracts/analysis do not suffice; independent functional acceptance and Owner review |
| Approval / review / expiry | Approval: NONE. Review date/expiry for a future exception: NOT_SET; an explicit date or bounded milestone is mandatory before acceptance. Re-entry suspends applicability pending review; expiry without renewed approval ends the exception. |
| Retained gates | AC09 `BLOCK/NOT_VERIFIED`; CDC-001 `OPEN`; VER-003 `OPEN`; STA-001 `IN_PROGRESS`; STA-002 `BLOCKED`; SYNCASYNCNET `NOT_WAIVED`; Clean Baseline `NOT_RELEASED` |

## Exception process

> **Proposed future rule only:** `LIMITED_ASSURANCE_ACCEPTED` is a separate, claim-specific disposition. It is never a replacement for a BC status or VERIFIED.

1. Propose an exact physical claim and independently justify that its assurance is separable from every mandatory functional requirement and essential assumption. If not separable, keep the affected gate blocked and route a separate proof/corrective/contract decision.
2. Establish independently accepted source-bound functional results and all applicable mandatory evidence; record actual limits and residual risk, not an inferred PASS.
3. Submit the exact source/configuration/use binding, permitted and prohibited claims, severity/impact, rationale, owner, re-entry, explicit expiry/review date or bounded milestone, and affected gate/checklist clauses for explicit Owner approval.
4. Only an adopted process and an approval for that exact record may set its exception disposition to `LIMITED_ASSURANCE_ACCEPTED`. Its physical result stays `NOT_PROVEN`; no BC item becomes VERIFIED, DEFERRED, OPT or closed by that action.
5. Material change or a re-entry trigger suspends applicability; expiry or revocation prevents further use of the exception. Renewed applicability needs review and explicit approval. Evidence establishing actual assurance instead needs its own acceptance.
6. Release remains a separate decision after mandatory BC/STA/board/ADC/C09 and checklist gates. A limited internal engineering checkpoint is NOT_RELEASED and cannot certify deployment safety.

## Other candidate areas

M9K conditions beyond the C08 write-edge boundary, ADC timing exceptions, external I/O and other RDC findings are **candidate review areas only**. No new limitation IDs, exception records, accepted deferrals or status changes are created for them. Existing C09, ADC, STA-002 and other owning gates remain controlling.

## Pending decisions and retained state

The exception process and record are draft proposals awaiting Owner review. Current C08 cannot use the route to discharge R1/R2. Narrowing required invalidation semantics, changing the frozen AC or reset contract, or allowing release with an unmet mandatory gate requires separate scoped authority and explicit conflict resolution; none is authorized here.

## Traceability

- [VGA evidence scope and draft claim boundary](08_vga.md#61-assurance-scope--draft-claim-boundary)
- [VGA accepted scheduling boundary](08_vga.md#71-c08-physical-assurance-obligation--post-baseline-execution-scope)
- [Proposed cleanup disposition](baseline_cleanup.md#31-proposed-limited-assurance-disposition)
- [Spec authoring policy](../docs/governance/spec_authoring_policy.md), [vendor/board evidence policy](../docs/governance/vendor_board_evidence_policy.md), [Git/release policy](../docs/governance/git_release_policy.md)

