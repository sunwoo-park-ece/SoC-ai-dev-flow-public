# Physical Assurance Limitation Register — 한국어 Companion

> **상태: PROPOSED / NOT_ACCEPTED.** [영문 정본](../physical_assurance_limitations.md)의 의미 동기화 문서다. 이 초안은 active exception authority, device qualification 또는 release acceptance가 아니다.

## 범위와 권한

이 cross-module register는 limitation record와 제안된 claim-disposition 절차를 소유한다. Behavior, acceptance criterion 및 essential device assumption은 owning subsystem spec이 유지하고 [baseline cleanup §3](baseline_cleanup.ko.md#3-cleanup-exit-gate)가 milestone gate를 유지한다. Limitation record로 어느 권한도 바꿀 수 없다.

Functional evidence, physical assurance, exception approval 및 release는 별도 결정이다. 증거 부재는 demonstrated defect, safety proof, VERIFIED 상태 또는 자동 exception 적격성이 아니다. 기존 accepted functional evidence는 실제 source/model 범위만 유지한다.

## 현재 의무

Required immediate write suppression, abort/recovery, no-side-effect, ownership, stale-event suppression 및 liveness 계약은 계속 binding이다. 최소 loss pulse나 branch skew의 수치를 새로 도입하지 않는다. 관측하지 못했거나 diagnostic에 count되지 않았거나 특정 reset branch가 capture하지 않았다는 이유로 required event를 제외하지 않는다.

Functional proof에 essential한 physical fact는 그 proof의 prerequisite로 남는다. Physical, post-baseline 또는 limited assurance로 명명해도 그 의존성을 제거할 수 없다. Active unsafe behavior가 입증되면 통상적 scheduling이나 예외 대신 즉시 corrective/restricted-use review가 필요하다.

## 증거와 주장 경계

Valid epoch 내 stable-clock operation과 qualified reset/release에는 제한된 functional evidence가 있다. Logical handshake/RAM handoff 논증은 valid epoch와 applicable primitive operation을 조건으로 한다. Conditional digital reset sequence는 모든 physical PLL invalidation의 capture나 reset-branch ordering을 입증하지 않는다. Board photograph, diagnostic zero/count, positive internal STA 또는 vendor compile 성공으로 missing guarantee를 확립할 수 없다.

### C08-PHYS-001

| 필드 | 정본과 동등한 record |
|---|---|
| ID / domain | `C08-PHYS-001` / VGA PLL, HCLK/pixel reset branch 및 physical VRAM write boundary |
| Physical state | `NOT_PROVEN / UNDETERMINABLE`; 현재 evidence gap으로 입증된 active defect 없음 |
| Exception request / acceptance | `PROPOSED / NOT_ACCEPTED`; approval, permitted exception use 또는 expiry가 부여되지 않음 |
| Owning contract | [VGA §4/§5/§6/§7](08_vga.ko.md), unchanged `VGA-CDC-AC-05/06/08/09` 포함; [reset §6.1/§13.3](06_reset_clock.ko.md); [cleanup §23A](baseline_cleanup.ko.md#23a-c08-물리적-보장-의무) |
| Source boundary | [VGA wrapper](../../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v), [reset helper](../../rtl/soc/reset_release_sync.v), [SoC top](../../rtl/soc/AMBA_SoC_TOP.v), 별도로 binding된 local MAX10 ALTPLL/M9K configuration |
| Covered functional evidence | Captured loss/abort/diagnostic 및 Boolean gating의 기존 source-bound portable digital check; conditional common-reset recovery sequence; established valid epoch 내 structural crossing completeness와 logical selected-bank handoff. Physical qualification이나 full AC09 acceptance는 아님. |
| Unproved physical condition | Raw short locked-LOW detection/capture; asymmetric 또는 late branch assertion; release/observer settling 및 reconvergence; loss/capture/rearm minima; edge-near AHB final response와 WE/M9K bitcell write atomicity; free-running PLL startup/reset condition의 applicability |
| Essential dependency | R1: 모든 required PLL invalidation이 두 branch와 relevant state를 effectively clear해야 함. R2: pixel READY/ACK/pending invalidation과 HCLK abort/rebase가 stale state를 fresh로 소비하기 전에 완료되어야 함. AC09에 계속 essential하며 supplemental-claim exception을 받을 수 없음. |
| Supplemental-claim eligibility | NOT_ESTABLISHED. R1/R2 및 모든 mandatory gate와 독립적으로 분리 가능한 residual physical claim을 명시적으로 열거하고 정당화한 뒤에만 exception 적격성을 검토할 수 있음. 이 combined record는 blanket exception이 아님. |
| Operating claim restriction | Bounded established-valid-epoch functional observation만 해당. Universal lock-loss capture, physical write-edge safety, certified board-use/deployment safety 또는 Clean Baseline release를 주장하지 않음. Required loss event와 frozen acceptance stimulus는 범위에 계속 포함. |
| Severity / impact | High assurance risk: capture/ordering 근거 부재가 fresh-epoch ownership 논증을 무효화할 수 있으며 write-edge atomicity도 미인증. 이 record로 BC row의 severity/gate class를 배정하거나 낮추지 않음. |
| Responsible owner | VGA/clock-reset specification maintainer; physical execution은 board owner; 명시적 exception/release 결정은 Owner가 유지 |
| Scheduling | `POST_BASELINE_P12_PHYSICAL_QUALIFICATION`은 accepted 실행 일정 경계만 유지. Essential AC09 dependency는 queue 배정과 무관하게 gating으로 남음. |
| Re-entry trigger | Physical safety 주장 전; clock/reset/PLL/M9K/write-commit 또는 binding 변경; 새 vendor 정보; lock-loss anomaly/defect; intended-use 변경; expiry/review 도래 |
| Evidence needed | 해당 exact source/IP/bitstream/board identity; primary MAX10/ALTPLL/M9K event/reset/write contract 및 configuration applicability; capture/re-entry ordering 근거; gap을 명시한 applicable timing/RDC; contract/analysis로 충분하지 않으면 독립 관측 targeted physical evidence; independent functional acceptance 및 Owner review |
| Approval / review / expiry | Approval: NONE. 향후 exception의 review date/expiry: NOT_SET; acceptance 전에 명시적 날짜 또는 bounded milestone 필수. Re-entry 시 review까지 applicability를 중지하고 expiry 후 renewed approval이 없으면 exception 종료. |
| Retained gate | AC09 `BLOCK/NOT_VERIFIED`; CDC-001 `OPEN`; VER-003 `OPEN`; STA-001 `IN_PROGRESS`; STA-002 `BLOCKED`; SYNCASYNCNET `NOT_WAIVED`; Clean Baseline `NOT_RELEASED` |

## Exception process

> **향후 rule 제안만 해당:** `LIMITED_ASSURANCE_ACCEPTED`는 별도 claim-specific disposition이다. BC status나 VERIFIED를 대체하지 않는다.

1. 정확한 physical claim을 제안하고 그 assurance가 모든 mandatory functional requirement 및 essential assumption에서 분리 가능함을 독립적으로 정당화한다. 분리할 수 없으면 해당 gate를 blocked로 유지하고 별도 proof/corrective/contract 결정을 요청한다.
2. 독립적으로 accept된 source-bound functional result와 모든 applicable mandatory evidence를 확립한다. 추정 PASS 대신 실제 한계와 residual risk를 기록한다.
3. Exact source/configuration/use binding, permitted/prohibited claim, severity/impact, rationale, owner, re-entry, 명시적 expiry/review date 또는 bounded milestone, affected gate/checklist clause를 explicit Owner approval 대상으로 제출한다.
4. 채택된 절차와 정확히 그 record의 approval이 모두 있어야 exception disposition을 `LIMITED_ASSURANCE_ACCEPTED`로 설정할 수 있다. Physical result는 `NOT_PROVEN`을 유지하고 그 행위로 BC item이 VERIFIED, DEFERRED, OPT 또는 closed가 되지 않는다.
5. Material change/re-entry trigger가 발생하면 applicability를 중지하고 expiry/revocation 이후에는 예외를 사용할 수 없다. Applicability 갱신에는 review와 explicit approval이 필요하다. 실제 assurance를 입증하는 evidence에는 별도 acceptance가 필요하다.
6. Release는 mandatory BC/STA/board/ADC/C09 및 checklist gate 충족 후 별도 결정으로 남는다. Limited internal engineering checkpoint는 NOT_RELEASED이며 deployment safety를 인증할 수 없다.

## 다른 candidate 영역

C08 write-edge boundary 밖의 M9K condition, ADC timing exception, external I/O 및 기타 RDC finding은 **candidate review area만 해당**한다. 이에 대한 새 limitation ID, exception record, accepted deferral 또는 status 변경을 만들지 않는다. 기존 C09, ADC, STA-002 및 다른 owning gate가 계속 controlling이다.

## Pending 결정과 유지 상태

Exception process와 record는 Owner review를 기다리는 draft proposal이다. 현재 C08은 이 경로로 R1/R2를 해소할 수 없다. Required invalidation semantics 축소, frozen AC/reset contract 변경 또는 unmet mandatory gate가 있는 release 허용에는 별도 scoped authority와 명시적 conflict resolution이 필요하며 여기서는 어느 것도 승인하지 않는다.

## Traceability

- [VGA evidence scope와 draft claim boundary](08_vga.ko.md#61-assurance-범위--주장-경계-초안)
- [VGA accepted 실행 일정 경계](08_vga.ko.md#71-c08-물리적-보장-의무--post-baseline-실행-범위)
- [Cleanup disposition 제안](baseline_cleanup.ko.md#31-proposed-limited-assurance-disposition)
- [Spec authoring policy](../../docs/governance/spec_authoring_policy.md), [vendor/board evidence policy](../../docs/governance/vendor_board_evidence_policy.md), [Git/release policy](../../docs/governance/git_release_policy.md)

