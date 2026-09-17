# Evidence Capture 도구 (초기 공통 버전)

이 코드는 Public Repo `scripts/evidence/`에 보관할 재사용 가능한 실행 도구다. 실행 자체가 AC 승인, 정적 CDC 검증, Quartus/보드 검증을 의미하지 않는다. **현 프로젝트 P08B의 기존 PASS를 새 도구로 소급 인증하지 않는다.** 실제 프로젝트 runner와 연결할 때 별도의 통합 검증이 필요하다.

## 1. 실행 포장

```bash
./scripts/evidence/run_with_evidence.sh \
  --run-root "$RUN_ROOT" --task P08B --test VGA_FOCUSED \
  --source-root "$PWD" \
  --input rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v \
  --input verification/directed/vga/tb_p08b_vga.sv \
  --input scripts/wsl/p08b_vga_test.sh \
  -- ./scripts/wsl/p08b_vga_test.sh
```

- `$RUN_ROOT`는 절대경로이며 **어느 Git 저장소의 내부도 아니어야 한다.** 실행별 고유 폴더를 새로 만든다.
- 실제 빌드에 영향을 주는 RTL, TB, runner, firmware/image/spec 등을 필요한 만큼 `--input`으로 모두 열거한다. 입력 미선언 시 완전한 재현 증거라고 할 수 없다.
- 각 실행은 `command.txt`, `exit_code.txt`, `stdout_stderr.log`, `source_hashes.sha256`, `result.json`, `assertion_observations.md`를 생성한다.
- 시험 프로세스는 선택적으로 환경변수 `EVIDENCE_RUN_DIR`에 `assertions.json`을 작성할 수 있다. 필수 스키마: `assertions_passed`/`assertions_failed` 정수, `coverage_complete` 불리언, `observations` 비어 있지 않은 배열. 배열의 각 항목에 `ac_id`, `assertion_id`, `observed`, `expected`가 필요하다.
- **종료 코드 0만으로 PASS를 부여하지 않는다.** 적격 assertion JSON 없으면 `EVIDENCE_INSUFFICIENT`. 종료 코드가 0이 아니면 `FAIL`. 래퍼 종료 코드는 시험 프로세스의 종료 코드를 보존한다. Assertion JSON은 시험이 내놓은 주장이지 독립 리뷰 결과는 아니다.
- 실패·재시도 기록을 덮어쓰지 않는다. 민감한 실행 명령과 원본 로그는 외부 Run Archive에만 저장한다.

## 2. 별도 해시 생성

```bash
python3 scripts/evidence/generate_manifest.py --root "$PWD" \
  --file rtl/soc/AMBA_SoC_TOP.v --output "$RUN_ROOT/inputs.sha256"
```

명시한 경로만 검사하며 Symlink 및 저장소 밖 경로를 거부한다.

## 3. 리뷰 패키지 생성

```bash
python3 scripts/evidence/generate_review_package.py \
  --base /path/to/clean-public-snapshot \
  --candidate /path/to/current-candidate \
  --output "$RUN_ROOT/review-package" \
  --allowlist /path/to/approved-review-paths.txt \
  --ac-file /path/to/acceptance-criteria.json \
  --run-root "$RUN_ROOT"
```

`allowlist`는 변경이 승인된 저장소 상대 파일 경로를 줄 단위로 나열한다. `ac-file`은 `[ {"id":"AC-01", "requirement":"..."} ]` 형식이다. 전체 변경 감사·원본 diff는 외부 디렉터리에만 쓴다. 리뷰용 diff는 허용 경로로 한정하고 보안 사전 스캔이 BLOCKED면 삭제한다. `acceptance_matrix.json`은 **자동으로 PASS를 생성하지 않으며**, 리뷰어가 실제 근거를 검토해 확정해야 한다.

## 4. 게시 파일 검사

```bash
python3 scripts/evidence/security_scan.py --root "$RUN_ROOT/review-package" \
  --file reviewable_implementation.diff \
  --report "$RUN_ROOT/review-package/scan.json"
```

보안 검사는 휴리스틱이므로 `PASS`여도 추가 사람 검토와 task별 게시 허가가 필요하다. 이 도구들은 Git add/commit/push, 자동 Issue 종료, Public 소스 출판을 수행하지 않는다.

## 주의

- 기존 Public 소스의 고정 SHA와 로컬 candidate의 실제 파일 해시를 구분한다.
- `source_hashes.sha256`은 명시된 파일 목록에 한정한다. 파일 목록 누락을 탐지하는 전면적 빌드 추적기는 아니다.
- `generate_review_package.py`의 `implementation.diff`는 secret/benchmark/Serena 파일이 섞일 수 있으므로 **절대로 자동 게시하지 않는다**. `complete_change_audit.tsv`도 원본 경로 감사 후에만 게시한다.
- 릴리스, 보드 승인, 정적 CDC, STA는 별도 승인 및 도구 근거가 필요하다.
