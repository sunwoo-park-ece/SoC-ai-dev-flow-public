# 명세서 작성 정책 (Specification Authoring Policy)

> **적용 범위:** 퍼블릭 저장소 `spec/` 디렉터리 하위의 모든 정규 명세서.  
> **상태:** 활성 프로젝트 거버넌스 (Active Project Governance).  
> **기준 언어:** 영어 (`spec_authoring_policy.md`). 본 한국어 문서는 시맨틱 동등성을 유지하는 공식 동반 문서(Companion)입니다.

---

## 1. `spec/`의 역할과 소유권

퍼블릭 저장소의 `spec/` 디렉터리는 베이스라인 클린업 및 이후의 모든 기능 개발 단계에서 **현재 활성 계약(Current Active Contract)에 대한 단일 진실 공급원(Source of Truth)**입니다.

### `spec/`가 소유하는 대상
- 시스템 및 각 서브시스템이 지금 이 순간 어떻게 동작해야 하는지에 대한 규범적 정의.
- 인터페이스, 신호 핸드셰이크, 레지스터 맵, 타이밍 계약.
- 타협할 수 없는 안전성, 정확성, 아키텍처 불변 규칙(Invariants).
- 요구사항이 `VERIFIED` 상태로 승격되기 위해 통과해야 하는 구체적인 인수 기준(Acceptance Criteria, AC).
- 요구사항별 현재 구현 상태 (`OPEN`, `IN_PROGRESS`, `BLOCKED`, `VERIFIED`).
- 승인된 목표 스펙 및 명시적으로 유예된 항목(Approved Target / Deferred Work).

### `spec/`가 소유하지 않는 대상
- 일회성/임시 태스크 지시사항 (비공개 `tasks/`에서 관리).
- 긴 디버깅 일지나 대화식 서사 (공개 `docs/engineering/`에서 관리).
- 시뮬레이션 원시 로그나 머신 로컬 절대 경로 (로컬 `runs/`에서 관리).
- 기각된 대안이나 트레이드오프 논의 (공개 `docs/decisions/` ADR에서 관리).
- 특정 실행에 종속된 원시 해시 및 실행 레코드 (`reports/evidence/`에서 관리).

---

## 2. 표준 명세서 기본 골격

아래의 표준 8개 섹션 구조는 `spec/` 하위의 정규 서브시스템 명세서를 위한 **기본 권장 표준(Default & Recommended Standard)**입니다. 소규모 또는 특정 목적에 집중된 명세서의 경우 비례적으로 축소된 서브셋을 채택할 수 있으나, Status, Contract, Criteria, Traceability는 절대 생략되어서는 안 됩니다:

```markdown
# <기능 / 서브시스템 명칭> Specification

## 1. Status and Scope
## 2. Current Active Contract
## 3. Interface / Register / Timing Contract
## 4. Invariants and Error Behavior
## 5. Acceptance Criteria
## 6. Current Requirement Status
## 7. Approved Target / Deferred Work
## 8. Traceability
## Appendix A. Historical / Pre-cleanup Notes (선택 사항)
```

### 섹션별 역할 및 금지 사항

| 섹션 | 규범적 역할 | 금지 사항 |
|---|---|---|
| **1. Status & Scope** | 기능 범위 및 현재 베이스라인 단계 정의 | 모호한 개발 범위나 미승인 약속 기술 |
| **2. Current Active Contract** | 현재 설계가 반드시 준수해야 하는 동작 규약 | 과거의 버그나 레거시 RTL 동작을 현재 시제로 서술 |
| **3. Interface / Timing** | 주소 맵, 비트 정의, 핸드셰이크, 클록/리셋 규칙 | 원시 테스트벤치 코드 또는 시뮬레이션 로그 전문 삽입 |
| **4. Invariants & Error** | 비타협적 안전 규칙 및 에러 발생 시 시스템 동작 | 우연한 구현 편의나 내부 임시방편을 계약화 |
| **5. Acceptance Criteria** | `PASS` / `VERIFIED` 판정을 위한 영구 검증 기준 | 실행 시점의 Run ID, 타임스탬프, 로컬 파일 경로 기재 |
| **6. Requirement Status** | 요구사항별 현재 달성 상태 (`OPEN`, `VERIFIED` 등) | 증거 없이 완료(`VERIFIED`)로 주장 |
| **7. Approved Target / Deferred** | 승인된 향후 목표 및 명시적으로 유예된 작업 | 미래 목표를 이미 구현된 것처럼 기술 |
| **8. Traceability** | 테스트, 증거 패키지, 엔지니어링 케이스 상대 링크 | 로컬 절대 경로 (`/home/swp/...`, Windows 드라이브 경로) |
| **Appendix A. Historical Notes** | 설계 배경 이해를 위해 보존 가치가 있는 과거 맥락 | 레거시 동작 방식을 현재 계약 본문과 혼재하여 기술 |

---

## 3. 계약, 기준, 상태, 증거의 4단계 분리

순환 논리와 형식적/외관적 검증(Cosmetic Verification)을 원천 차단하기 위해, 명세서 작성자는 다음 네 가지 개념을 엄격히 구분해야 합니다:

```text
Current Active Contract (현재 활성 계약)
    = 시스템이 지금 어떻게 동작해야 하는가.

Acceptance Criteria (인수 기준, AC)
    = 해당 계약이 충족되었음을 증명하기 위해 어떤 검사를 통과해야 하는가.

Current Requirement Status (현재 요구사항 상태)
    = 요구사항별 현재 상태가 OPEN, IN_PROGRESS, BLOCKED, VERIFIED 중 무엇인가.

Historical / Public Evidence (공개 검증 증거)
    = 특정 기준을 어떤 실행(Run ID, 커밋 SHA, 테스트 결과)을 통해 실증했는가.
```

### 식별자 체계 (Taxonomy)

| 식별자 유형 | 표준 형식 | 정의 위치 | 예시 |
|---|---|---|---|
| **요구사항 ID** | `<서브시스템>-<NNN>` | 명세서 및 `baseline_cleanup.md` | `BUS-003`, `TRAP-003`, `VGA-001` |
| **인수 기준 ID (AC ID)** | `<접두어>-AC-<NN>` | 명세서 제5장 (Acceptance Criteria) | `SAF-AC-01`, `VGA-AC-02` |
| **검증 케이스 ID (EV ID)** | `<접두어>-EV-<NN>` | 공개 증거 패키지 (`reports/evidence/`) | `SAF-EV-01` |
| **실행 ID (Run ID)** | `<태스크>_<날짜>_<순번>` | 원시 저장소 (`runs/`) 및 내부 매트릭스 | `p12_vga_cdc_20261001_01` |

---

## 4. 참조 예시: Store-Access-Fault 계약

다음 발췌문은 명세서에서 하드웨어 계약과 인수 기준, 상태가 어떻게 분리되는지 보여줍니다:

```markdown
## 2. Current Active Contract

AHB 버스 ERROR 응답이 발생했을 때:
- 로드 접근 폴트는 예외 `mcause=5`를 발생시킨다.
- 스토어 접근 폴트는 예외 `mcause=7`을 발생시킨다.
- `mepc`는 결함이 발생한 명령어의 정확한 PC를 기록한다.
- 실패한 로드는 레지스터 파일 쓰기백(Writeback)을 수행하지 않는다.
- 실패한 스토어는 메모리 및 주변장치에 부수 효과(Side-effect)를 남기지 않는다.
- 결함이 발생한 명령어는 정상 은퇴(Retire)되지 않는다.
- 정렬 불량 예외(Misaligned exception)는 버스 에러보다 우선순위를 갖는다.

## 5. Acceptance Criteria

| 기준 ID | 통과 조건 |
|---|---|
| `SAF-AC-01` | 스토어 버스 에러 시 `mcause=7`이 발생해야 한다. |
| `SAF-AC-02` | `mepc`가 결함 명령어의 PC를 정확히 캡처해야 한다. |
| `SAF-AC-03` | 에러 스토어가 메모리 및 주변장치 레지스터 값을 변경하지 않아야 한다. |
| `SAF-AC-04` | 실패한 스토어 명령어가 은퇴되지 않아야 한다. |
| `SAF-AC-05` | 파이프라인의 후행 명령어들이 커밋되지 않고 플러시되어야 한다. |
| `SAF-AC-06` | 정렬 불량 스토어는 버스 트랜잭션을 내보내지 않고 예외 원인 6을 발생시켜야 한다. |
| `SAF-AC-07` | 펌웨어가 승인된 안전 트랩 처리 엔드포인트 또는 Fail-stop에 도달해야 한다. |

## 6. Current Requirement Status

| 요구사항 / 기준 | 상태 | 검증 증거 패키지 |
|---|---|---|
| `BUS-003`, `SAF-AC-01..06` | VERIFIED | `../reports/evidence/bus-access-fault/summary.md` |
| `SAF-AC-07` (FW 엔드포인트) | BLOCKED | `../reports/evidence/p08b-gate0/summary.md` |

## 8. Traceability

- 아키텍처 결정: `../docs/decisions/ADR-001-precise-trap-ordering.md`
- 엔지니어링 케이스: `../docs/engineering/CS-001-precise-ahb-access-fault.md`
- 디렉티드 테스트: `../verification/directed/bus/tb_soc_cpu_fault_e2e.sv`
- 공개 증거: `../reports/evidence/bus-access-fault/summary.md`
```

> **핵심 원칙:** 하드웨어의 정확한 폴트 동작(`SAF-AC-01..06`)이 `VERIFIED` 되었더라도, 펌웨어 핸들러 미완성(`SAF-AC-07`)으로 인해 시스템 수준은 `BLOCKED`일 수 있습니다. 이 둘을 명확히 분리함으로써 거짓 완료 주장을 방지하고 하드웨어 검증 사실을 정직하게 반영합니다.

---

## 5. 서사 최소화 및 상대 링크 규정

명세서는 간결한 계약 문서로 유지되어야 합니다. 긴 디버깅 스토리, 가설 검증 과정, 트레이드오프 토론은 `docs/engineering/CS-<NNN>-<제목>.md` 케이스 스터디로 이관하십시오.

- 명세서 내 배경 설명은 최대 2~5문장으로 제한합니다.
- 상세 조사 내역은 엔지니어링 케이스 스터디로 링크합니다:
  ```markdown
  ### Architectural Rationale
  본 계약에 이르게 된 문제 분석, 근본 원인 조사, 아키텍처 트레이드오프는
  [CS-001: Precise AHB Access Fault](../docs/engineering/CS-001-precise-ahb-access-fault.md)를 참조하십시오.
  ```

### 엄격한 링크 규정
1. **저장소 기준 상대 링크만 허용:** 명세서 내 모든 링크는 반드시 상대 경로(`../docs/...`, `../reports/...`)를 사용해야 합니다.
2. **로컬 절대 경로 절대 금지:** `/home/swp/...`, `/mnt/c/...`, `C:\...` 등 특정 로컬 머신 경로는 퍼블릭 명세서에 포함할 수 없습니다.

---

## 6. `baseline_cleanup.md`와 개별 명세서의 관계

- `spec/baseline_cleanup.md`는 프로젝트 전반의 클린업 게이트, 요구사항 ID, 심각도, 담당자, 요약 기준, 전체 상태를 총괄 추적합니다.
- 개별 명세서(`spec/03_cpu_interface.md` 등)는 상세한 계약, 전체 인수 기준 목록, 비트필드 정의, 불변 규칙을 소유합니다.
- 두 문서 간 기술적 세부사항에 충돌이 발생할 경우, 개별 정규 명세서가 기술적 권위를 가지며, 발견 즉시 양 문서를 동기화해야 합니다.

---

## 7. 레거시 명세서 정리 및 개편 절차

구형 명세서를 최신 표준 규격으로 개편할 때는 다음 10단계 절차를 따릅니다:

1. **내용 분류:** 명세서 내용을 `CURRENT`(현재 유효), `HISTORICAL`(과거 사실), `TARGET`(향후 목표), `UNRESOLVED`(미확정)로 분리합니다.
2. **RTL/FW 교차 검증:** 유효 후보 내용을 실제 프로덕션 RTL, 펌웨어, 검증 테스트벤치와 비교 확인합니다.
3. **현재 계약 재작성:** 제2장에 모호한 과거형 서술을 배제하고 단호한 현재형 규범 문장으로 계약을 명시합니다.
4. **인수 기준 정립:** 제5장에 `<접두어>-AC-<NN>` 형식의 고유 식별자를 부여하여 검증 조건을 정의합니다.
5. **요구사항 상태 표 작성:** 요구사항별 상태를 표로 정리하고 증거 패키지 상대 링크를 연결합니다.
6. **미래 목표 격리:** 미구현 기능이나 장기 목표를 제7장(`Approved Target / Deferred Work`)으로 분리합니다.
7. **서사 추출:** 긴 디버깅 저널, 실패한 대안 기록을 `docs/engineering/` 케이스 스터디로 추출합니다.
8. **아키텍처 결정 추출:** 지속적인 영향을 미치는 주요 구조적 결정을 `docs/decisions/ADR-<NNN>.md`로 추출합니다.
9. **한국어 동반 문서 동기화:** 영문 정규본과 한글 동반본의 섹션 구조, AC ID, 레지스터 명칭 일관성을 확인합니다.
10. **상대 링크 감사:** 문서 내 모든 링크가 저장소 내부에서 정상적으로 동작하는지 검증합니다.
