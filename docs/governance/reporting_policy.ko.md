# 엔지니어링 보고 및 증거 패키징 정책 (Reporting Policy)

> **적용 범위:** 퍼블릭 저장소 `reports/evidence/` 하위의 공개 증거 패키지 및 비공개 내부 엔지니어링 보고서.  
> **상태:** 활성 프로젝트 거버넌스 (Active Project Governance).  
> **기준 언어:** 영어 (`reporting_policy.md`). 본 한국어 문서는 시맨틱 동등성을 유지하는 공식 동반 문서(Companion)입니다.

---

## 1. 증거 패키징 철학

모든 엔지니어링 주장은 불변성(Immutable), 재현성(Reproducible), 정제성(Sanitized)을 갖춘 증거에 의해 실증되어야 합니다.

```text
비공개 정규 증거 (Private Canonical)        공개 정제 패키지 (Public Derivative)
--------------------------------------      -------------------------------------
<FEATURE>_REPORT.md                 --->    summary.md (핵심 개요 및 범위)
verification_matrix_<feature>.json  --->    result.json (머신 판독 가능 판정)
로컬 소스/테스트 해시                --->    source_hashes.sha256 (무결성 검증)
시뮬레이터/툴 원시 실행 로그         --->    로컬 runs/ 보관 (Git 커밋 절대 금지)
```

- **검증 자산 vs 결과 증거:** 실행 가능한 테스트벤치와 스크립트(`verification/`, `scripts/`)는 *결과를 재현하는 방법*을 제공하며, 증거 패키지(`reports/evidence/`)는 *특정 소스 커밋에 대해 승인된 결과가 무엇인지*를 영구히 기록합니다.
- **정제된 파생 문서:** 공개 증거는 비공개 원본으로부터 철저한 비식별화/정제 과정을 거쳐 도출됩니다. 원시 로그, 로컬 절대 경로, 벤더 독점 데이터베이스, 자격 증명은 절대 공개 저장소에 포함될 수 없습니다.

---

## 2. `reports/evidence/` 디렉터리 구조

공개 증거 패키지는 기능/서브시스템 중심의 영구 디렉터리로 구성됩니다:

```text
reports/evidence/
├── README.md                          # 전체 공개 증거 목록 및 인덱스
├── bus-access-fault/
│   ├── summary.md
│   ├── result.json
│   └── source_hashes.sha256
├── cpu-retirement/
│   ├── summary.md
│   ├── result.json
│   └── source_hashes.sha256
└── p08b-gate0/                        # Gate 0 STOP 결과를 솔직하게 공시한 패키지
    ├── summary.md
    ├── result.json
    └── source_hashes.sha256
```

- **영구적 명명:** 일시적인 단계 번호(`phase4a`)가 아닌 대상 기능명(`bus-access-fault`)을 디렉터리 이름으로 사용합니다.
- **색인 목록:** `reports/evidence/README.md`에 검증 소스 커밋 SHA, 요구사항 ID, 판정 결과를 요약 표로 인덱싱합니다.

### 상태 정의 및 판정 시맨틱
- **종료 코드 != 시맨틱 판정 (Exit Code != Semantic Verdict):** 도구의 프로세스 종료 코드가 시맨틱 판정을 자동으로 결정하지 않습니다. 예를 들어, 기지의 부정 테스트(Negative Test)나 버그를 재현하는 경우 도구가 0이 아닌 종료 코드를 반환하더라도 `PASS_INCOMPATIBILITY_REPRODUCED`로 기록됩니다. 반대로 기대 단언문이 실행되지 않고 우회된 채 exit 0을 반환한 경우는 `PASS`가 될 수 없습니다.
- **상태 분류 체계:**
  - `APPROVED`: 변경 불가능한 공개 커밋 SHA를 대상으로 독립 검토 및 승인이 완료된 증거 패키지.
  - `PENDING_REVIEW`: 작성이 완료되어 독립 검토를 대기 중인 증거 패키지.
  - `PENDING_PUBLIC_COMMIT`: 로컬 작업 파일이나 기능 브랜치에서 검증이 완료되었으나 아직 퍼블릭 문서/소스 커밋 SHA가 형성되지 않은 개발 단계에서 사용. 공개 증거 패키지는 SHA 누락 상태로 `APPROVED`로 최종화되어서는 안 되며, 반드시 `PENDING_PUBLIC_COMMIT`으로 표기 후 공개 직전에 확정 SHA로 갱신해야 합니다.
  - `REJECTED` / `BLOCKED`: 검증이 실패했거나 전제 게이트를 통과하지 못한 상태.

---

## 3. 증거 문서 규격: `summary.md`

`summary.md`는 외부 검토자가 검증 범위, 방법론, 재현 명령, 한계점을 신속히 파악할 수 있도록 작성하는 총괄 요약 문서입니다.

```markdown
# <증거 패키지 제목>

## 1. Status
- Evidence ID: `<접두어>-EV-<NN>`
- Requirements: `<요구사항 ID>`
- Criteria: `<인수 기준 ID>`
- Result: `PASS | CONDITIONAL_PASS | FAIL | STOP`
- Review Status: `APPROVED | PENDING_REVIEW | PENDING_PUBLIC_COMMIT | REJECTED`
- Verified Source Revision: `<40자리 소스 커밋 SHA | PENDING_PUBLIC_COMMIT>`
- Evidence Date: `<YYYY-MM-DD>`

## 2. Scope
검증된 기능 및 인터페이스 경계에 대한 명확하고 간결한 서술.

## 3. Claim
본 증거 패키지가 증명하는 구체적인 사실 (그 외 범위는 주장하지 않음).

## 4. Method
- Testbench: `verification/.../tb_*.sv`
- Runner: `scripts/wsl/<runner>.sh`
- Tool: `<도구 명칭 및 버전>`
- Oracle / Reference: `<골든 모델, ISA 명세, 또는 프로토콜 체커>`
- Assumptions: `<클록/리셋/프로토콜 가정>`

## 5. Acceptance Results
| 기준 ID | 검증 내용 | Oracle / Reference | 결과 |
|---|---|---|---|
| `<기준 ID>` | <설명> | <명세 조항 / 골든 오라클> | PASS |

## 6. Reproduction
```bash
RUN_ROOT=/tmp/soc-runs bash scripts/wsl/<runner>.sh
```
공개 재현 명령은 로컬 전용 경로에 의존하지 않아야 합니다.

## 7. Source Identity
- 해시 매니페스트: `source_hashes.sha256` (또는 `source_hashes.json`)
- 결과 JSON: `result.json`

## 8. Limitations / Not Proven
검증되지 않은 경계(예: 보드 실장 미검증, CDC 미완료, 펌웨어 미작성)를 정직하게 명시.

## 9. Related Engineering Cases
- 관련 `docs/engineering/CS-*.md` 및 `docs/decisions/ADR-*.md` 링크.

## 10. Provenance and Sanitization
- 로컬 머신 경로 제거 확인
- 독점 벤더 IP 제외 확인
- 원시 로그 로컬 보관 확인
```

---

## 4. 증거 문서 규격: `result.json`

`result.json`은 머신 판독이 가능한 정형 검증 결과 데이터를 제공합니다.

### JSON 작성 규칙
- 엄격한 표준 JSON 규격 준수 (주석이나 후행 쉼표 금지).
- 저장소 내부 기준 상대 경로만 사용.
- 실행되지 않은 항목은 반드시 `NOT_RUN`, `NOT_APPLICABLE`, `PENDING`, `BLOCKED`로 표기 (절대 거짓 `PASS` 금지).
- 0번 종료 코드(exit 0)가 곧바로 `PASS`를 의미하지 않음 (예: 비호환성 재현 검증은 `PASS_INCOMPATIBILITY_REPRODUCED`).
- 퍼블릭 소스 커밋이 아직 생성되지 않은 경우 `"commit": "PENDING_PUBLIC_COMMIT"`으로 표기하고 배포 전 갱신.

### 구조 예시

```json
{
  "schema_version": "1.0",
  "evidence_id": "SAF-EV-01",
  "title": "Precise AHB store access-fault verification",
  "status": "PASS",
  "review_status": "APPROVED",
  "evidence_date": "2026-09-17",
  "verified_source_revision": {
    "repository": "https://github.com/sunwoo-park-ece/SoC-ai-dev-flow-public",
    "commit": "<40자리-소스-커밋-SHA>"
  },
  "requirements": [
    "BUS-003",
    "TRAP-003"
  ],
  "criteria": [
    {
      "id": "SAF-AC-01",
      "check": "failed store produces mcause=7",
      "result": "PASS"
    }
  ],
  "tests": [
    {
      "case_id": "SAF-TC-01",
      "testbench": "verification/directed/bus/tb_cpu_access_fault.sv",
      "runner": "scripts/wsl/bus_cpu_apb_test.sh",
      "tool": "iverilog/vvp",
      "exit_code": 0,
      "result": "PASS"
    }
  ],
  "hash_manifest": "reports/evidence/bus-access-fault/source_hashes.sha256",
  "limitations": [
    "does not prove a safe firmware trap endpoint",
    "does not constitute physical FPGA board acceptance"
  ],
  "sanitization": {
    "absolute_paths_removed": true,
    "host_identifiers_removed": true,
    "license_server_data_removed": true,
    "vendor_generated_payload_included": false
  }
}
```

### 비자기참조(Non-Self-Referential) 커밋 원칙
증거 파일은 자기 자신이 포함될 미래의 커밋 SHA를 스스로 기록할 수 없습니다. 따라서:
1. 대상 소스/테스트 코드 스냅샷 커밋을 먼저 생성합니다.
2. 증거 패키지에 해당 검증 소스 커밋 SHA를 기록합니다.
3. 후속 문서 커밋을 통해 증거 패키지를 저장소에 반영합니다.

---

## 5. 소스 해시 매니페스트: `source_hashes.sha256` / `source_hashes.json`

증거 패키지는 표준 SHA-256 해시를 사용하여 모든 입력 파일의 정확한 무결성을 실증해야 합니다.

### 표준 `sha256sum` 형식 (`source_hashes.sha256`)

```text
eb261e6346f699ddce5c6f53f28df68d50e587840a7e6bf5ce0152a834d3c87e  rtl/core/v/top/RV32I46F_5SP_MMIO.v
908a241f8022a7eee2ab7f15c1f86057ff5bcc18270f7d3805247d17376ada4a  verification/directed/bus/tb_cpu_access_fault.sv
3ad86035bf3fdb3ca639dafa045b88dd9ba70034d9bbce26a63cd93627268d68  scripts/wsl/bus_cpu_apb_test.sh
```

### JSON 형식 규격 (`source_hashes.json`)

머신 판독 가능 해시 형식을 사용할 때:

```json
{
  "schema_version": "1.0",
  "files": [
    {
      "path": "rtl/core/v/top/RV32I46F_5SP_MMIO.v",
      "sha256": "eb261e6346f699ddce5c6f53f28df68d50e587840a7e6bf5ce0152a834d3c87e"
    },
    {
      "path": "verification/directed/bus/tb_cpu_access_fault.sv",
      "sha256": "908a241f8022a7eee2ab7f15c1f86057ff5bcc18270f7d3805247d17376ada4a"
    }
  ]
}
```

### 4대 해시 거버넌스 수칙
1. **내용 무결성 vs 커밋 SHA:** SHA-256 해시는 물리적 파일의 정확한 내용 일치 여부를 증명하며, Git 커밋 SHA를 대체하지 않습니다.
2. **무효화 및 재계산:** 검증 대상 소스, 테스트벤치, 러너, 모델 파일이 수정되거나 재생성되면 기존 해시는 즉시 무효화되며 반드시 재계산되어야 합니다.
3. **벤더 IP 제외:** 벤더 독점 바이너리, 암호화 넷리스트, 도구 DB 파일은 퍼블릭 해시 매니페스트에 절대 기록하지 않으며, `ip_manifest.yml` 또는 바인딩 명칭으로만 참조합니다.
4. **저장소 상대 경로:** 경로는 반드시 퍼블릭 저장소 루트 기준 상대 경로여야 합니다. 절대 머신 경로를 포함해서는 안 되며, 검증된 RTL, 펌웨어, 테스트벤치, 러너를 포함하고 일시적 산출물은 제외합니다.

---

## 6. 배포 전 정제(Sanitization) 체크리스트

공개 증거 패키지를 스테이징하거나 커밋하기 전에 다음 항목을 전수 검사해야 합니다:

- [ ] 사용자명, 호스트명, 내부 IP 주소가 모두 제거되었는가
- [ ] 로컬 절대 경로(`/home/swp/...`, `/mnt/...`, `C:\...`)가 남아있지 않은가
- [ ] 비밀번호, API 토큰, 라이선스 서버 주소가 제거되었는가
- [ ] 벤더 자동생성 독점 IP 넷리스트 및 DB가 제외되었는가
- [ ] 기록된 소스 커밋 SHA가 유효하고 추적 가능한가
- [ ] `source_hashes.sha256`의 모든 해시가 실제 파일과 일치하는가
- [ ] 실제 실행된 테스트 결과만 기록되었으며 미실행 항목은 `NOT_RUN`으로 명시되었는가
- [ ] 미검증 영역 및 한계점이 정직하게 기술되었는가
- [ ] 명세서 및 케이스 스터디로 연결되는 상대 링크가 정상 동작하는가
