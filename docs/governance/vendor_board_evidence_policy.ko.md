# 벤더 툴링 및 실장 보드 증거 정책 (Vendor & Board Evidence Policy)

> **적용 범위:** FPGA 벤더 컴파일 플로우 (Quartus, Vivado), 정적 타이밍 분석(STA), 실물 하드웨어 보드 검증.  
> **상태:** 활성 프로젝트 거버넌스 (Active Project Governance).  
> **기준 언어:** 영어 (`vendor_board_evidence_policy.md`). 본 한국어 문서는 시맨틱 동등성을 유지하는 공식 동반 문서(Companion)입니다.

---

## 1. 핵심 운용 경계 (Core Operating Boundary)

전체 벤더 툴 컴파일(합성, 배치배선, 비트스트림 생성) 및 물리적 보드/JTAG 작업은 **사용자(소유자)가 명시적으로 위임하지 않는 한 기본적으로 소유자가 직접 실행(Owner-operated by default)**합니다.

```text
       AI 에이전트 (Codex / Antigravity)                   인간 소유자 / 사용자 (User)
      ---------------------------------                  --------------------------
1. 빌드 전 오픈 회귀검증 및 RTL 동결        --->
2. 검증된 CLI 실행 스니펫/런북 생성        --->   3. 벤더 컴파일 직접 실행 (Quartus/Vivado)
                                            <---   4. 완료 알림 및 실행 디렉터리 전달
5. 리포트 파싱, 타이밍/자원 지표 추출
6. 보드 검증 절차 및 체크리스트 준비        --->   7. JTAG 다운로드 및 물리 하드웨어 시험
                                            <---   8. 실물 관측 결과 및 측정값 전달
9. 통합 엔지니어링 보고서 작성
```

---

## 2. 벤더 실행 런북 규약 (Runbook Contract)

요청이 있을 때 에이전트는 사용자가 복사하여 즉시 실행할 수 있는 정밀한 CLI 명령을 생성합니다. 모든 벤더 실행 스크립트나 CLI 스니펫은 다음 규약을 준수해야 합니다:

1. **고유 실행 식별자 (Unique Run ID):** 태스크, 기능, 날짜, 순번을 포함 (예: `p12_vga_cdc_20261001_01`).
2. **저장소 외부 실행 디렉터리 (Out-of-Tree Run Root):** 모든 중간 파일, 프로젝트 DB, 비트스트림을 Git 저장소 외부인 `<workspace>/runs/quartus/<feature>/<run-id>/` (또는 `<workspace>/runs/vivado/...`)에 격리 저장. 스크립트는 명시적인 워크스페이스 변수를 강제하고 미지정 시 즉시 실패(fail-fast)해야 하며, 저장소나 현재 작업 디렉터리로의 폴백은 엄격히 금지됩니다.
3. **파이프 실패 보호 (`set -o pipefail`):** bash/zsh 스니펫에서 `set -o pipefail`을 적용(또는 셸에 적합한 파이프라인 실패 전파 기법 사용)하여 파이프라인 명령 중간의 실패가 은폐되지 않도록 강제.
4. **종료 코드 명시적 기록:** 도구의 실제 종료 코드를 `exit_code.txt`에 기록.
5. **표준 출력/에러 동시 로깅:** `tee`를 사용하여 콘솔 출력과 로그 파일(`wrapper.log` 등)을 동시 기록.

### 표준 CLI 래퍼 스니펫 템플릿

```bash
# 파이프라인 실패 전파 강제 (bash/zsh)
set -o pipefail

# WORKSPACE 환경 변수 미지정 시 즉시 중단 (저장소 루트로의 폴백 금지)
: "${WORKSPACE:?ERROR: WORKSPACE 환경 변수가 반드시 명시되어야 합니다 (예: export WORKSPACE=/home/swp/soc)}"

RUN_ID="<feature>_$(date +%Y%m%d_%H%M%S)"
RUN_ROOT="${WORKSPACE}/runs/quartus/<feature>/${RUN_ID}"
mkdir -p "$RUN_ROOT"

echo "=== Starting Vendor Build [${RUN_ID}] ==="
# 검증된 빌드 스크립트 또는 벤더 실행 명령
bash scripts/quartus/build_de10_lite.sh "$RUN_ROOT" 2>&1 | tee "$RUN_ROOT/build.log"

rc=${PIPESTATUS[0]}
printf '%s\n' "$rc" > "$RUN_ROOT/exit_code.txt"

if [ "$rc" -eq 0 ]; then
  echo "=== Vendor Build Completed Successfully [exit code 0] ==="
else
  echo "=== Vendor Build FAILED [exit code $rc] ==="
fi
exit "$rc"
```

---

## 3. 빌드 후 지표 추출 의무

사용자가 빌드를 완료한 후, 에이전트는 컴파일 결과 보고서를 파싱하여 다음 지표들을 의무적으로 추출해야 합니다:

### 필수 하드웨어 자원 사용량 지표
- Logic Element (LE) / LUT 사용 개수 및 사용률(%).
- Dedicated Logic Register (FF) 개수 및 사용률(%).
- 임베디드 메모리 비트 / Block RAM (M9K / BRAM) 사용량.
- DSP 블록 사용 개수.
- PLL / 클록 제어 블록 사용 개수.

### 필수 타이밍 및 클록 도메인 지표
- 각 클록 도메인별 목표 주파수 대비 달성 Fmax.
- 최악 셋업 슬랙 (Worst Negative Slack, WNS / Setup Slack).
- 최악 홀드 슬랙 (Worst Hold Slack, WHS / Hold Slack).
- 클록 도메인별 총 음수 슬랙 (Total Negative Slack, TNS).
- 크리티컬 패스(Critical Path)의 종점(Endpoint), 소스 클록, 데이터 경로 상세 분석.
- 새로운 타이밍 병목 및 클록 도메인 교차(CDC) 실패 여부.
- 직전 마일스톤 또는 클린 베이스라인 대비 증감치(Delta).

---

## 4. 정적 타이밍 분석 (STA) 및 검증 주장 경계

과도한 완료 주장을 방지하기 위해, 에이전트는 다음 계층적 검증 한계를 엄격히 준수해야 합니다:

```text
내부 타이밍 슬랙 만족  !=  외부 I/O 타이밍 마감 (Timing Closure)
컴파일 성공 완료       !=  정적 CDC 완전 검증 (CDC Signoff)
시뮬레이션 PASS        !=  실물 보드 검증 완료 (Board Signoff)
```

1. **내부 슬랙 vs 외부 I/O 타이밍:** 내부 코어의 슬랙이 양수(TNS=0)라 하더라도, 외부 주변장치 핀(VGA DAC, SDRAM, ADC, GPIO 등)이 실물 인터페이스 규격의 셋업/홀드/스큐 조건을 만족함을 증명하지 않습니다.
2. **CDC 검증 독립성:** 벤더 합성 도구는 비동기 클록 교차의 올바름을 자동으로 보장하지 않습니다. 비동기 도메인 교차는 단순한 일괄 false-path 지정 대신, 아키텍처에 적합한 구조적 검증(다단 동기화기 또는 핸드셰이크 프로토콜 등)과 분석적으로 정당화된 타이밍 제약(적절한 경우 false path 또는 max delay)이 뒷받침되어야 합니다.
3. **한계점 명시:** I/O 타이밍이나 CDC가 완전히 마감되지 않았다면, 보고서에 반드시 `내부 코어 타이밍 만족 | 외부 I/O 타이밍 미검증` 형태로 한계를 명시해야 합니다.

---

## 5. 실물 보드 및 하드웨어 실장 시험

### 역할 분담 원칙
- **사용자(User) 수행:** 실물 보드 배선, 전원 인가, USB-Blaster / JTAG 케이블 연결, FPGA 비트스트림 다운로드(`.sof` 프로그래밍), 물리 스위치/버튼 조작, 오실로스코프 및 로직 아날라이저 프로빙.
- **에이전트 수행:** 정확한 비트스트림 파일 경로 안내, 단계별 시험 절차서 작성, 예상되는 시각적/전기적 동작 명시, 합격/불합격 판정 체크리스트 제공, 전달받은 관측 사실의 보고서 반영.

### 보드 인수 체크리스트 필수 항목
모든 보드 검증 세션은 다음 항목이 포함된 구조화된 체크리스트를 기반으로 수행되어야 합니다:
- **비트스트림 무결성:** 프로그래밍된 파일의 절대 경로 및 SHA-256 해시.
- **하드웨어 구성 상태:** 대상 보드 기종(DE10-Lite), 스위치 초기 위치, 점퍼 설정, 케이블 연결.
- **예상 입력-출력 시나리오:** 단계별 물리 입력(예: "SW[0] ON")과 관측 기대치(예: "HEX0에 'A' 표시, LEDR[0] 점등").
- **관측 증거 확보:** 멀티미터 측정값, 현장 사진, 로직 아날라이저 캡처 가이드.
- **이상 현상 기록:** 화면 노이즈, 온도 민감성, 파워온 리셋 시점의 레이스 컨디션 등 특이사항을 정직하게 기록.

---

## 6. 저장소 격리 및 라이선스 방화벽

- **로컬 전용 보관:** 벤더 프로젝트 데이터베이스(`db/`, `incremental_db/`), 생성된 IP 코어, 비트스트림 파일(`.sof`, `.pof`, `.bit`), 원시 넷리스트는 반드시 로컬 전용 저장소(`/home/swp/soc/vendor-projects-private/` 및 `runs/`)에만 보관해야 합니다.
- **GitHub 업로드 절대 금지:** 벤더 독점 파일, 라이선스 제한 IP 바이너리, 컴파일 결과물을 퍼블릭 또는 비공개 GitHub 저장소에 커밋하는 행위는 엄격히 금지됩니다.
- **공개 저장소 자산:** 퍼블릭 저장소에는 이식 가능한 SDC 제약 파일, 오픈 Tcl 빌드 스크립트, 공개 핀 매핑, 그리고 로컬에서 IP를 재생성할 수 있는 `ip_manifest.yml` 매니페스트만 보관합니다.
