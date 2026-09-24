# 현재 공개 상태 (Current Public Status)

- P10-HEX Public 소스: [`aa77d90ed50d29e5ea42e8c490f4451b76a8df95`](https://github.com/sunwoo-park-ece/SoC-ai-dev-flow-public/commit/aa77d90ed50d29e5ea42e8c490f4451b76a8df95)에 **통합 완료(INTEGRATED)**; 관련 문서, 표준 규격서 및 베이스라인 클린업 트래커가 동기화되었습니다. 현재 `main` HEAD의 공식 기준은 저장소의 Git 히스토리입니다.
- P09B Public 소스: [`ed2bfd0f5167679aef4851d40ce66f95f8e2355d`](https://github.com/sunwoo-park-ece/SoC-ai-dev-flow-public/commit/ed2bfd0f5167679aef4851d40ce66f95f8e2355d)에 **통합 완료(INTEGRATED)**; 관련 문서는 후속 커밋으로 게시되었습니다.
- 동결된 P08B 소스 스냅샷: `f28e95df2eafcb939e04ffaca728c44f74c90612`
- 베이스라인 클린업: **진행 중 (IN PROGRESS)**
- P08B VGA 기능 범위 (`VGA-001..006`): **오너 승인 완료 / 검증 완료 (OWNER ACCEPTED / VERIFIED)**
- P09B G-sensor 기능 범위: **통합 완료 / 검증 완료 (INTEGRATED / VERIFIED)**
- P10-HEX 7세그먼트 디스플레이 기능 범위 (`HEX-001..003`): **오너 승인 완료 / 검증 완료 (OWNER ACCEPTED / VERIFIED)**
- 주변장치 APB-005 HEX 하위 범위 (`0x4000_7000..0x4000_7FFF`): **검증 완료 (VERIFIED)**
- 클린 베이스라인 릴리즈: **미출시 (NOT RELEASED)**
- 벤더/보드 승인: **본 스냅샷에서는 주장하지 않음 (NOT CLAIMED BY THIS SNAPSHOT)**

동결된 P08B 스냅샷 및 후속 마일스톤 커밋들은 현재 Public `main` 리비전과 명확히 구분됩니다. 기능 범위 승인(VGA, G-sensor, HEX)은 각 서브시스템의 동작만을 다루며, 최종 릴리즈 식별자를 재정의하거나 전체 SoC에 대한 CDC/STA 사인을 주장하지 않습니다.

CPU의 정밀 store-access-fault 처리는 **합격(PASS)** 판정되었습니다: 결함을 유발하는 store 명령어는 `mepc = 0x00000008`과 함께 `mcause = 7`을 발생시키며, 정상적으로 완료(retire)되지 않고 후속 `x3` 커밋도 발생하지 않습니다. 이전 Gate 0 감지기에서 리셋 기본값 `mtvec = 0x00006d60`이 표준 16 KiB 명령어 메모리 외부에 위치함을 보였으나, 해당 결과는 수정 이전의 역사적 증거일 뿐 현재 엔드포인트 상태를 나타내지 않습니다. 동결된 [부팅 코드](../../firmware/bsp/start.S)는 스택, BSS, 애플리케이션 또는 VGA MMIO 작업 전에 유효 범위 내의 `__trap_entry`를 설치하고 트랩을 최종 `__trap_fail_stop`으로 전달합니다. 따라서 Gate 0은 **부팅 코드의 `mtvec` 쓰기가 커밋된 이후에만 조건부 합격(SCOPED PASS)**입니다. 해당 커밋 이전의 리셋 구간(`RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT`)은 여전히 **알려진 위험 / 미해결(KNOWN RISK / OPEN)** 상태로 유지되며, 리셋 최초 인출부터의 안전한 트랩과 전반적인 CPU/펌웨어 승인은 주장하지 않습니다. 제한적 정책에 대한 세부 사항은 [인터럽트 규격](../../spec/kor/07_interrupt_architecture.ko.md) 및 [펌웨어 계약](../../spec/kor/19_firmware_contract.ko.md)을 참조하십시오.

P08B의 보드 시각적 스모크 증거는 [CS-009](../engineering/CS-009-p08b-vga-hwclear-w1c.md)에 정확한 카운트 RTL/DV 구분과 함께 게시되어 있으며, 사진 자료는 제한적인 시각적 전이만을 뒷받침합니다. `VGA-007`은 미해결 상태로 남아있고, `CDC-001`은 정적 검증 미실행, `STA-001`은 내부 `SCOPED_PASS`로만 진행 중, `STA-002`는 블로킹 상태이며, 두 개의 VGA/ADC 경고가 미해결 상태이고, `mtvec` 이전 리셋 윈도우는 알려진 위험으로 유지되며, 독립 프로그래머/JTAG 식별자는 기록되지 않았습니다. 다른 ADC, G-sensor, HEX, 펌웨어, STA 및 보드 작업 역시 릴리즈 완료를 위해 남아 있습니다. 항목별 공식 상태는 [클린업 트래커](../../spec/kor/baseline_cleanup.ko.md)를 참조하십시오.

벤치마크 및 Dhrystone 소스 파일은 첫 번째 스냅샷에서 의도적으로 제외되었습니다. 향후 성능 보고서는 명시적인 방법론과 용어를 바탕으로 별도로 검토 및 게시될 예정입니다.

P09B Public 통합은 소스 및 문서 커밋 쌍을 통해 구현되었습니다. 활성 P09B 계약은 [G-sensor](../../spec/kor/12_gsensor.ko.md), [메모리 맵](../../spec/kor/01_memory_map.ko.md) 및 [APB 서브시스템](../../spec/kor/05_apb_subsystem.ko.md)의 통합 섹션에 기술된 구현 동작입니다. P09B를 미커밋 또는 미통합 후보로 서술하는 과거 구절은 **게시 이전의 역사적 체크포인트**만을 의미하며 현재 Public `main`을 의미하지 않습니다. P09B는 12회 쓰기 50 Hz/INT1 시퀀스, 30 ms 워치독, LIVE/HOLD 스냅샷 ABI, 직접 공유 `PRESETn`, 펌웨어 라이프사이클 및 전용/CPU/호스트 체커를 구현합니다. 비공개 피팅/STA 증거 및 보드 디스플레이 관찰은 제한적 범위의 증거로 유지됩니다. `STA-002`, 외부 타이밍/전기적 특성, 물리적 INT1/방향/캘리브레이션, Stage 3 이관 작업, 비정상 APB 치명적 음의 분기 및 지연된 트랩 부수효과 검사는 미해결 또는 미실행(NOT_RUN) 상태입니다. 게시 자체가 트래커 VERIFIED, 릴리즈 또는 보드 승인을 부여하지는 않습니다.

P10-HEX Public 통합은 S0부터 S6 단계까지 완료되었습니다. 활성 계약은 [HEX 디스플레이](../../spec/kor/16_hex_display.ko.md), [펌웨어 계약](../../spec/kor/19_firmware_contract.ko.md), [APB 서브시스템](../../spec/kor/05_apb_subsystem.ko.md) 및 [베이스라인 클린업 트래커](../../spec/kor/baseline_cleanup.ko.md)에 정의되어 있습니다. P10-HEX는 정밀 로컬 6자리 디코드(`HEX-001`), 리드백/마스킹 RAZ/WI 규칙(`HEX-002`), 단독 소유 펌웨어 Shadow 동기화 및 `hex_display_resync()` 수명 주기(`HEX-003`), 그리고 슬롯 7 APB 브리지 억제(`0x4000_7000..0x4000_7FFF`, `APB-005`)를 확립했습니다. 검증에는 독립형 APB 테스트(S0), 레지스터 시맨틱(S1), 로컬 오프셋 디코드(S2), 펌웨어 Shadow 계약(S3), 방향성 뮤테이션 회귀 검증(S4), 버스 인터커넥트/CPU 통합(S5), 42개 핀(`HEX[0:6]`, `HEX[7]` 미사용)을 확인한 Quartus Fitter Pin 리포트, 그리고 오너가 확인한 물리적 보드 승인 증거(S6, `reports/evidence/p10-hex-s6/summary.md`, `P10-HEX-S6-EV-01`, 사진 B0~B8)가 포함됩니다. 이에 따라 `HEX-001`, `HEX-002`, `HEX-003`은 `VERIFIED`로 승격되었습니다. 이는 HEX 기능 클린업 범위에만 해당하며, 외부 I/O 타이밍/전기적 사인오프(`STA-002`), 여러 주변장치 동시 보드 동작, 그리고 Clean Baseline v1 최종 릴리즈 승인은 미완료 상태로 유지됩니다.
