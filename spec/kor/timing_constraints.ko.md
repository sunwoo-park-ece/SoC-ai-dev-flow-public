# 타이밍 제약 및 STA 정책

> **상태:** 현재 DE10-Lite 공개 후보의 baseline 타이밍 계약. [영문 정본](../timing_constraints.md)이 우선이며 이 문서는 의미를 맞춘 한국어 동반 문서다. 보드 전체 타이밍 sign-off를 주장하지 않는다. 클록/리셋 구조는 [06_reset_clock.ko.md](06_reset_clock.ko.md)에, milestone별 측정 이력과 fitted 원시 근거는 공개 spec 밖에 보관한다.

## 1. 범위

현재 **50 MHz baseline**의 클록, 시간 관계, setup/hold 합격 기준, 예외, 증거와 재빌드 판정을 규정한다. 내부 STA와 외부 I/O, CDC, 보드 특성 평가를 분리한다. 이 문서 자체는 SDC/QSF 변경, 예외 추가, 빌드 또는 target-SoC 주파수 상향을 승인하지 않는다.

## 2. Baseline 타이밍 목표

DE10-Lite의 `clk`가 50 MHz CPU/AHB를 직접 구동하고 APB `PCLK`도 동일 클록을 쓴다. 주기는 **20.000 ns**다. 올바르게 모델링한 모든 필수 내부 경로에서 관련 corner별 setup WNS ≥ 0 ns, TimeQuest endpoint TNS = 0 ns, hold slack ≥ 0 ns가 필요하다. 이는 합격 기준이지 측정 margin이 아니다. 현재 Slow 85°C의 +0.253 ns는 관측값이지 새로운 spec 임계값이 아니다.

## 3. 클록 정의

공개 `fpga/quartus/constraints/de10_lite.sdc`는 `clk` 20.000 ns를 정의하고 `derive_pll_clocks`, `derive_clock_uncertainty`를 호출한다. 승인된 fit의 활성 클록 객체는 시스템 `clk` 50 MHz, VGA pixel PLL 25 MHz, ADC/Qsys PLL 25 MHz와 10 MHz의 네 개다. 파생 클록 속도는 구현 사실이며 별도의 SW 성능 보증이 아니다. 현재 G-sensor FSM/샘플 레지스터는 PCLK에서 동작하고 약 2 MHz의 등록된 SCLK는 **외부 SPI 출력**이지 내부 생성 클록이 아니다. 과거/private `spi_pll` 파일이 존재해도 활성화된 것은 아니다.

IP 파일이나 과거 설명만으로 활성 클록을 추정하지 말고, 구조·binding이 바뀌면 fitted 클록 목록을 확인한다. `system_pll`은 현재 CPU 활성 클록이 아니다.

## 4. 생성 클록 정책

활성 PLL 내부 클록은 검토된 자동 유도 또는 명시적 제약으로 주파수·위상·관계를 TimeQuest에 올바르게 모델링해야 한다. WNS를 양수로 만들기 위해 생성 클록을 무시하면 안 된다. G-sensor single-PCLK 변경처럼 내부 도메인이 **구조적으로 제거**된 경우에만 해당 클록이 목록에서 사라질 수 있다. RTL/binding, fitted 클록 목록, CDC 검토가 필요하며 단순 제약 삭제는 closure가 아니다.

## 5. 타이밍 corner

현재 MAX 10 모델의 **Slow 1200 mV 0°C**, **Slow 1200 mV 85°C** setup을 최소한 검토한다. 현재 보고된 **Fast 1200 mV 0°C**를 포함해 선택한 device/profile의 모든 hold corner를 확인한다. 해당되는 recovery, removal, minimum pulse width도 검토한다. 향후 device/tool profile이 바뀌면 corner 목록을 새로 검토하며 없는 corner를 만들어 쓰지 않는다.

## 6. Setup 합격

필수 시간 관계의 모든 요구 corner에서 setup slack은 0 이상이어야 하며, corner별 WNS와 실제 최악 경로를 기록한다. 시스템 클록 한 행이 양수라도 생성 클록 전송이나 외부 port가 모두 닫혔다는 뜻은 아니다. 과거 3B2A의 SPI 생성 클록→시스템 클록 실패가 launch/capture 관계 확인의 중요성을 보여준다.

## 7. Hold 합격

모든 필수 hold 경로가 보고된 모든 hold corner에서 0 이상의 slack을 가져야 한다. multicorner 최악값과 경로군을 기록하며 setup PASS나 Fmax로 hold PASS를 추론하지 않는다. 리셋 recovery/removal은 별도로 검토한다.

## 8. TNS 합격

필수 setup/hold endpoint TNS는 **0**이어야 한다. TimeQuest는 위반 TNS를 **음수 부호**로 출력한다. 음수면 실패이며 절댓값이 위반량이다. 컴파일 exit 0을 이유로 음수 TNS를 PASS로 취급하지 않는다.

## 9. 클록 uncertainty 정책

활성 클록에 검토된 uncertainty를 유지한다. 공개 SDC의 `derive_clock_uncertainty`가 fitted TimeQuest의 생성 클록에도 적용되었는지 확인한다. missing-clock/uncertainty 경고는 `STA-001`에서 분류하며 Fmax만으로 무시하지 않는다. slack을 양수로 만들기 위한 uncertainty 완화는 금지한다.

## 10. False-path 정책

실패를 숨기기 위해 false path를 넣을 수 없다. 제안 시 실제 비전송 구조 또는 검증된 CDC/리셋 메커니즘, 정확한 source/destination 범위, 담당자·독립 검토자, 기능/CDC 근거가 필요하다. 도구·vendor 제공 예외도 검토한다. 공개 SDC에 예외가 없다는 사실만으로 컴파일된 전체 constraint set에 예외가 전혀 없다고 단정하지 않는다. 기능적으로 필요한 동기 전송은 계속 timing 대상이다.

## 11. Multicycle-path 정책

깊은 조합 경로를 가리기 위한 multicycle은 금지한다. 합법적 예외에는 명시적인 launch/capture 프로토콜과 enable 동작, 정확한 endpoint, setup **및 hold** 의미, 검증 근거와 검토 승인이 필요하다. 값은 slack 부족분이 아니라 구조에서 도출해야 한다. 3B2A G-sensor 경로는 이런 예외로 면제하지 않았다.

## 12. 클록 도메인 / CDC 타이밍 정책

STA와 CDC 안전성은 별개다. 시간 분석되는 교차 클록 경로라도 coherent/safe CDC를 증명하지 못하며, CDC 예외는 의도된 synchronizer, handshake, FIFO 또는 검증된 dual-clock memory 경계와 결합될 때만 유효하다. CDC 구조를 정하기 전 비동기 관계를 임의 선언하지 않는다. 클록/리셋 도메인과 열린 crossing은 `06_reset_clock.ko.md` 및 `CDC-*`/`RST-*`/`STA-001`에서 관리한다. G-sensor의 내부 crossing 하나를 제거했어도 ADC/VGA CDC와 소프트웨어-visible XYZ snapshot은 별도 미완이다.

## 13. 외부 I/O 제약 정책

보드 port를 synchronous, source-synchronous, asynchronous, static, analog로 분류한다. input/output delay는 보드·상대 디바이스·인터페이스의 문서화된 시간 가정에 근거할 때만 부여한다. 해당되지 않으면 임의의 0이나 수치를 만들지 않고 근거 있는 **N/A**를 기록한다. I/O standard/전압, drive/load, ADC/VGA 인접 배치 및 G-sensor SPI peer timing을 보드·디바이스 자료로 검토한다. `STA-002`의 별도 gate이며 내부 50 MHz 양수 slack은 외부 타이밍이나 ADC 아날로그 성능 sign-off가 아니다.

## 14. 미제약 경로 정책

“미제약 클록 0개”는 “설계 전체 제약 완료”와 다르다. closure 검토에는 미제약 클록, 입력/출력 port와 경로, 외부 delay coverage가 모두 포함된다. 승인된 3B3 fit에는 미제약 클록 0개지만 **입력 port 16개/경로 44개**, **출력 port 71개/경로 2,114개**가 미제약이다. 이는 열린 범위이며 보드 전체 timing sign-off 근거가 아니다. 수를 줄이려고 delay를 지어내지 않는다.

## 15. 타이밍 예외 승인 관리

false path, multicycle, clock group 등 예외 승인 전 구조적 이유, 정확한 `-from`/`-to` 및 클록 관계, 담당자와 독립 검토자, 기능/CDC 근거, setup/hold 영향, 적용 전후 TimeQuest 예외·경로 audit을 기록한다. 실패를 조용히 없애기 위한 예외는 허용하지 않는다. 필수 동기 경로가 실패하면 구조나 fit을 조사·개선한다. 이 문서는 **새 예외를 승인하지 않는다**.

## 16. Quartus / TimeQuest 증거 요구

합격 기록에는 tool/version, device, timing model/profile, run ID, 공개 vendor payload 없이 식별 가능한 source-list/private-binding identity, SDC/QSF identity, 클록 목록/주기, corner별 WNS/TNS, worst hold, 보조 Fmax, 최악 경로 start/end와 클록 관계, logic level, 가능한 경우 data/cell/routing delay, 경고, 미제약 경로 요약을 포함한다. 상세치가 없으면 `UNKNOWN / NOT REPORTED`라고 쓴다. 기본 summary에 경로 상세가 없으면 기존 fitted DB의 **복사본**에서 path 분석을 수행해 원본 빌드 증거를 보존한다.

Fmax는 동일 클록 경로에 한정된 보조값이다. 과거 3B2A는 Fmax가 50 MHz를 넘었지만 생성 클록→`clk` 경로의 WNS가 음수였다. 따라서 필수 경로의 WNS/TNS/hold가 headline Fmax보다 우선한다.

## 17. 타이밍 closure 흐름

승인 spec/RTL/클록/constraint/binding freeze → open regression PASS → 새 run ID로 사용자 vendor full build → exit code와 source/constraint/report 무결성 검사 → 클록/corner setup·hold 및 경고 검토 → 필요 시 상세 critical path 추출 → 내부/외부/CDC gap 처리 → User/Chat review gate. 컴파일/bitstream 성공만으로 타이밍, firmware 또는 board 승인이라고 하지 않는다. 선행 run 근거는 덮어쓰지 않는다.

## 18. 증거 재사용 / 재빌드 규칙

합성 RTL, SDC, 타이밍 관련 QSF, source list/profile, private IP 구현과 binding, device, 구현에 영향을 주는 tool/version/profile이 동일하고 identity가 기록된 경우에만 fit을 재사용한다. TB/script/report만 바뀌면 fit이 무효화되지 않는다. Phase 4A-3B-CLOSE는 승인된 3B3 fit의 검증 전용 재사용 사례이지 새 측정점이 아니다. 합성 RTL, timing constraint, 클록 구조, 관련 QSF, private IP 구현, device 또는 구현 flow가 바뀌면 새 빌드와 타이밍 검토가 필요하다.

## 19. 보드 특성 평가와 STA sign-off

STA는 명시된 PVT/제약의 모델 기반 worst-case 판단이다. 특정 조건에서 한 보드가 50 MHz 이상 동작한 관찰은 경험적 특성 평가이지 전체 보드/corner 보증이나 STA 대체 근거가 아니다. 향후 overclock 시험에는 하드웨어, 환경, firmware/workload, 시간, 오류 기준을 기록한다. 대응 근거와 STA가 없으면 60–70 MHz 최대치나 보증을 주장하지 않는다.

## 20. 현재 열린 타이밍 범위

P05C fitted reset/clock checkpoint는 **현재 내부 constraint 범위에서 PASS**다. Multicorner worst setup `+0.558 ns`, hold `+0.111 ns`, recovery `+11.334 ns`, removal `+0.478 ns`, design-wide TNS `0`이며 의도한 내부 clock은 모두 constrained이고 G-sensor 내부 generated clock은 없다. `STA-001`은 최종 P14 frozen-source multicorner, exception/CDC, multi-seed/stability 검토까지 IN_PROGRESS를 유지한다. 외부 I/O timing/electrical 및 ADC/VGA board 영향은 **NOT CLOSED**(`STA-002` BLOCKED)이며 P05C에도 input port 32개/경로 55개와 output port 87개/경로 2,146개가 unconstrained다. 이는 reset row closure 및 release 승인과 별개이며 변화하는 상세 margin은 local STA status history에서 관리한다.

## 21. 향후 target-SoC 타이밍 재검토

PLIC, AXI, DMA, SDRAM 또는 주파수 상향은 구조/CDC/제약 재평가, source/binding freeze, open regression, 새 vendor fit, critical path·외부 I/O 분석과 독립 검토를 요구한다. 현재 3B3 WNS/Fmax를 확장 설계에 승계할 수 없다. decode 조기화, EX/MEM 제어 등록, MEM 재디코드 축소, forwarding 경로 단축, exception fanout 완화 등은 **향후 조사 후보**일 뿐 승인된 RTL 변경이나 예외가 아니다.
