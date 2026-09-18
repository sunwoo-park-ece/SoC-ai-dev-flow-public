# SoC Baseline Cleanup Plan and Tracker — 한국어 Companion

> **상태:** ACTIVE DRAFT TRACKER — reconstructed baseline spec과 승인된 target contract에서 통합한 cleanup 작업 추적 문서이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/baseline_cleanup.md`가 충돌할 경우 영문 canonical tracker가 authoritative source이다.
>
> **권한 관계:** 이 문서는 cleanup 작업을 조정한다. 세부 behavior contract는 각 canonical specification이 소유한다. Tracker와 spec이 충돌하면 spec을 먼저 수정한 뒤 tracker를 동기화한다.

## 1. 목적

Baseline specification 재구성 이후 PLIC/AXI의 대규모 feature integration에 들어가기 전에 수행할 **1회성 baseline cleanup pass**의 중앙 implementation/verification tracker이다.

```text
reconstructed/approved specs
          |
          v
 baseline_cleanup.md
          |
          v
 RTL + firmware cleanup
          |
          v
 directed DV / CDC / STA
          |
          v
 Quartus FPGA integration
          |
          v
 board acceptance + evidence
          |
          +--> PLIC stage
          +--> AXI stage
```

RTL 수정 또는 Quartus compile만으로 item을 완료 처리하지 않는다. 요구 verification/evidence와 global exit gate를 충족해야 한다.

## 2. Scope Control

### 2.1 Gate class

| Gate | 의미 |
|---|---|
| `BC` | Baseline-cleanup gate. PLIC/AXI가 다음 stable stage가 되기 전에 해결/검증해야 한다. |
| `PLIC` | Dedicated PLIC/interrupt 단계로 미룬다. |
| `AXI` | AXI/DMA/external-memory migration 단계로 미룬다. |
| `OPT` | Non-gating hygiene 또는 optional future enhancement. |

### 2.2 Severity

| Severity | 의미 |
|---|---|
| `Blocker` | Cleanup closure를 막는 architecture/integration dependency. |
| `High` | correctness/CDC/security/protocol/software-contract 문제. 원칙적으로 cleanup에서 해결. |
| `Medium` | determinism/maintainability/interface-quality/verification debt. 해당 영역 수정 시 함께 해결 권장. |
| `Low` | correctness에 직접 영향이 적은 hygiene/refactor/documentation. |

### 2.3 Status

```text
OPEN        시작 전
BLOCKED     named decision/dependency 대기
IN_PROGRESS implementation 또는 verification 진행 중
VERIFIED    구현 + evidence review 완료
DEFERRED    PLIC / AXI / optional future로 의도적으로 이동
```

## 3. Cleanup Exit Gate

다음을 모두 만족해야 cleanup milestone을 종료한다.

1. `BC Blocker/High` 모두 `VERIFIED`.
2. 남은 `BC Medium`은 `VERIFIED` 또는 이유와 함께 명시적으로 accept.
3. target board-I/O ownership 일관성 확보.
4. approved 16-slot APB map active.
5. unsafe multi-bit CDC 제거 또는 verified CDC structure로 교체.
6. 모든 active domain의 reset release / generated-clock constraint 검토.
7. directed RTL/FW regression pass.
8. Quartus/TimeQuest에서 cleanup 관련 critical warning을 설명 없이 방치하지 않음.
9. cleanup FPGA image가 board-acceptance matrix 통과.
10. implementation evidence 전에는 target text를 active behavior로 승격하지 않음.
11. source commit, FW build, IMEM/DMEM image, SOF, timing, board evidence 연결.

## 4. 권장 구현 순서

```text
Phase A — architecture decisions APPROVED/FROZEN (구현 검증 전)
  A1 GPIO width / expansion-header pins
  A2 bus default-slave / access-fault policy
  A3 VGA framebuffer read/subword policy
  A4 UART TX-busy write policy
  A5 timer start/restart semantics
  A6 private-SPI timing retain vs refactor

Phase B — cross-cutting infrastructure
  B1 CPU correctness / legality / retirement
  B2 AHB decode / HSIZE / bus error
  B3 APB 8 -> 16 slots
  B4 reset / CDC
  B5 timing constraints

Phase C — board I/O
Phase D — peripheral correctness
Phase E — firmware migration
Phase F — regression / Quartus / board / report
```

`21_cpu_core.md`에서 GPR reset, machine ID, FENCE/FENCE.I, EBREAK, counter write semantics는 이미 승인되었으므로 더 이상 architecture blocker가 아니다. 아래 tracker에서는 구현/검증 item으로 관리한다.

---

# Part I — Bus / CPU / Reset / Trap Cleanup

## 5. AHB / CPU / Memory

| ID | Sev | Gate | 현재 문제 | 필요한 결과 | 관련 spec | Verification | Status |
|---|---|---|---|---|---|---|---|
| `BUS-001` | High | BC | DMEM top decode 64 KiB vs canonical 32 KiB. | `0x1000_0000..0x1000_7FFF`만 decode. | `01_memory_map`, `02_memory_subsystem`, `04_ahb_fabric` | boundary/unmapped load/store | VERIFIED |
| `BUS-002` | High | BC | CPU master `HSIZE` undriven. | byte=`000`, half=`001`, word=`010`. | `03_cpu_interface`, `04_ahb_fabric`, `21_cpu_core` | 모든 load/store waveform | VERIFIED |
| `BUS-003` | Blocker | BC | unmapped/default zero/OKAY, CPU HRESP 미사용. | 승인된 A2: 2-cycle `HRESP=01` ERROR, APB default error, precise CPU load/store access fault 구현. | `03_cpu_interface`, `04_ahb_fabric`, `05_apb_subsystem`, `07_interrupt_architecture`, `21_cpu_core` | invalid DMEM/VGA/APB/reserved fault | VERIFIED |
| `BUS-004` | Medium | BC | `HSEL_*` address-only decode. | valid-transfer qualify 또는 동등 안전성 증명. | `03_cpu_interface`, `04_ahb_fabric` | IDLE/back-to-back/wait | VERIFIED |
| `CPU-001` | Medium | BC | `EX_funct3_AHB` width/naming 문제. | width/naming 정규화. | `03_cpu_interface`, `21_cpu_core` | lint + memory | OPEN |
| `CPU-002` | Medium | AXI | custom write mask/BRAM hazard가 CPU↔DMEM local sideband. | baseline에 containment; AXI generic semantics로 복사 금지. | `02_memory_subsystem`, `03_cpu_interface`, `21_cpu_core` | RAW + future AXI review | DEFERRED |
| `BUS-005` | High | BC | stall/data-phase routing proof 부족. | delayed select/cross-slave wait 검증. | `03_cpu_interface`, `04_ahb_fabric`, `05_apb_subsystem`, `21_cpu_core` | wait-state tests | VERIFIED |

### 5.1 CPU Core Correctness

| ID | Sev | Gate | 현재 문제 | 필요한 결과 | 관련 spec | Verification | Status |
|---|---|---|---|---|---|---|---|
| `CPU-003` | High | BC | 과거 register shift의 full-width rs2 사용. | `rs2[4:0]`만 사용. | `21_cpu_core` | 3B3R 0/31/32/33/63/0xFFFF_FFFF | VERIFIED |
| `CPU-004` | High | BC | 과거 JALR raw `rs1+imm` target 검사. | `(rs1+imm)&~1` 후 IALIGN=32 검사. | `07_interrupt_architecture`, `21_cpu_core` | aligned/raw-...01/misaligned JALR | VERIFIED |
| `CPU-005` | High | BC | 과거 explicit valid/commit 부재로 real NOP이 minstret에서 누락. | pipeline-valid/retire-valid 또는 동등한 commit semantics. | `21_cpu_core` | 3B2B 정상 WB + 3B3R MRET one-shot commit/minstret | VERIFIED |
| `CPU-006` | Medium | BC | 과거 ASCII-like machine ID. | `mvendorid=0`, `marchid=0`, `mimpid=0x0001_0000`, `mhartid=0`. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R exact readback | VERIFIED |
| `CPU-007` | Medium | BC | 과거 FENCE inert + `TRAP_FENCEI/ic_clean` 모호성. | FENCE/FENCE.I legal no-op, 정상 retire, dormant artifact 표시. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R FENCE retire; legacy 비활성 문서화 | VERIFIED |
| `CPU-008` | Medium | BC | 과거 counter write response 미확정. | 이번 cleanup에서는 `mcycle/mcycleh/minstret/minstreth` RO 유지. 이 지원되는 counter CSR write는 legal no-effect/write-ignore: 값 불변, read-only라는 이유만으로 trap 없음. | `21_cpu_core` | 3B3R 4개 주소 write-ignore/value-stability/no-trap | VERIFIED |
| `CPU-009` | High | BC | 과거 opcode/funct3/funct7/shift/SYSTEM/CSR legality 결함. | rejected encoding/unsupported CSR는 illegal instruction + side effect 억제. 단 지원되는 project-RO counter write는 `CPU-008`의 명시적 write-ignore 예외. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R legality/no-bus + RO-counter 예외 | VERIFIED |
| `CPU-010` | Low | BC | GPR은 configuration init되지만 system reset clear 없음. | 승인 정책 유지: x1..x31 unspecified, reset fanout 추가 안 함. | `21_cpu_core`, `19_firmware_contract` | reset software test | OPEN |

## 6. APB / Decode

| ID | Sev | Gate | 현재 문제 | 필요한 결과 | 관련 spec | Verification | Status |
|---|---|---|---|---|---|---|---|
| `APB-001` | Blocker | BC | 과거 active `PSEL[7:0]`; P04에서 16-slot 이관 완료. | `PSEL[15:0]`, PRDATA/PREADY/tests 및 slot0..7 유지. | `01_memory_map`, `05_apb_subsystem`, `20_board_io_architecture` | P04 slot0..15 one-hot/cross-slot/post-fit | VERIFIED |
| `APB-002` | High | BC | `[27:20]` ignored -> alias. | `0x4000_0000..0x400F_FFFF`만 canonical decode. | `01_memory_map`, `04_ahb_fabric`, `05_apb_subsystem` | alias negative | VERIFIED |
| `APB-003` | High | BC | SETUP에서 new PWDATA stable 미보장. | SETUP→ACCESS address/control/data stable. | `05_apb_subsystem` | APB assertion | VERIFIED |
| `APB-004` | High | BC | reserved/invalid silent zero/ready. | 승인된 A2 전체 offset 검증, side-effect gate, default `PSLVERR`, bridge ERROR 구현. | `05_apb_subsystem`, `20_board_io_architecture` | reserved/offset tests | VERIFIED |
| `APB-005` | Medium | BC | peripheral register mirror; P06B Timer와 P07 UART sub-scope만 종결. | touched block은 canonical offset만 decode. | peripheral specs | Timer와 두 UART full slot-offset decode/mirror 제거; UART invalid request bridge ERROR·no real PSEL·no side effect 및 실제 backpressure PASS; 나머지 peripheral test 필요 | OPEN |
| `APB-006` | Medium | AXI | PSTRB 없음. | cleanup은 aligned32 유지. | `05_apb_subsystem`, `19_firmware_contract` | partial-write dependency 없음 | DEFERRED |

Phase 4A-3A 시점에는 slot 8/9와 후속 ISA/trap 근거가 남아 `APB-001`과 `TRAP-003`이 `IN_PROGRESS`였다. 이후 3B/3B3R이 `TRAP-003`을, P04 공개 검증·사용자 post-fit 검토가 `APB-001`을 종결하여 현재 둘 다 `VERIFIED`다. 전체 baseline cleanup 종료를 뜻하지 않는다.

## 7. Reset / CDC / Timing

| ID | Sev | Gate | 현재 문제 | 필요한 결과 | Verification | Status |
|---|---|---|---|---|---|---|
| `RST-001` | High | BC | 과거 domain별 assertion/release 불일치와 cold-start 비결정성은 P05 reset architecture로 해결됨. | 필요한 곳의 async assertion, HCLK/destination-sync release, deterministic LOW power-up, 1,000,000-cycle qualification을 보존. | P05 all-domain reset + fitted synchronizer/power-up + positive recovery/removal | VERIFIED |
| `RST-002` | High | BC | 과거 generated-domain release/PLL-ready gap은 baseline VGA, ADC project logic, PCLK-only G-sensor에서 해결됨. | VGA `locked` qualification, pclk_25/adc_sys_clk local release sync, vendor-managed ADC/Qsys reset, G-sensor 내부 SPI clock 부재를 보존. | P05 lock/reset + fitted PLL/reset/clock inventory | VERIFIED |
| `CDC-001` | High | BC | 과거 VGA bank selector direct CDC를 P08B candidate에서 교체. | frame-safe CDC/ownership handshake. | async request/ack, 정확한 frame-wrap swap, PLL recovery PASS; review 대기 | IN_PROGRESS |
| `CDC-002` | Blocker | BC | Gsensor XYZ direct CDC. | atomic XYZ + VALID/SEQ. | async pattern | OPEN |
| `CDC-003` | Blocker | BC | ADC response direct CDC. | coherent XY publication. | torn-sample | OPEN |
| `CDC-004` | Medium | BC | P05가 external async-input policy audit을 완료하고 reset/AUX 동작을 수정했으며 승인된 synchronizer를 보존함. | UART RX/AUX, G-sensor INT, reset button, SW, GPIO 구조와 level/pulse 제한을 보존. | P05 directed regression + fitted 36-chain/minimum-2-register review | VERIFIED |
| `STA-001` | High | BC | generated clock/uncertainty constraint 부족. | 남은 VGA/ADC generated clock·관계·uncertainty, A6 active SPI PLL 제거, TimeQuest/CDC warning 검토. | TimeQuest clock/CDC | IN_PROGRESS |
| `STA-002` | High | BC | 외부 board I/O timing/electrical 및 ADC/VGA physical placement 영향 미종결; 내부 양의 slack만으로 signoff 불가. | 모든 top 외부 port를 sync/source-sync/async/static/analog로 분류; peer/board 자료가 있는 경우에만 I/O delay, 나머지는 N/A 기록; IO standard/voltage/drive/load/unconstrained port, ADXL345 SPI timing, ADC/VGA warning과 VGA 동작 중 ADC 측정, 잔여 critical warning risk 명시 처분. 임의 SDC 금지. | TimeQuest I/O/QSF, peer timing, ADC/VGA board 측정 | BLOCKED |

## 8. Trap / Exception

| ID | Sev | Gate | 현재 문제 | 필요한 결과 | 관련 spec | Verification | Status |
|---|---|---|---|---|---|---|---|
| `TRAP-001` | High | BC | 과거 MRET = mepc+4. | `PC <- canonical mepc`; interrupt-state restore는 PLIC stage. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R ECALL/MRET/정규화 | VERIFIED |
| `TRAP-002` | High | BC | 과거 bus/APB/load-use/CSR stall과 precise trap/mepc의 상호작용 근거 부족. | bus/APB/load-use/CSR stall에서 precise entry. | `03_cpu_interface`, `07_interrupt_architecture`, `21_cpu_core` | 3B-CLOSE 대표 AHB/APB wait, load-use, CSR hold/drain, MEM/EX/ID 우선순위·일회 service 매트릭스; 전체 Cartesian 증명은 아님 | VERIFIED |
| `TRAP-003` | High | BC | 과거 illegal/branch misalign/access fault 결함. | `CPU-009`, taken branch alignment, `BUS-003` access fault를 precise cause/PC와 통합. | `04_ahb_fabric`, `07_interrupt_architecture`, `21_cpu_core` | 3B3R illegal/target + 3A/3B2A bus fault | VERIFIED |
| `TRAP-004` | High | BC | 과거 EBREAK debug/SYSTEM noncanonical decode. | precise mepc, cause3, mtvec + exact SYSTEM legality; legacy debug_mode 의존 제거. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R EBREAK/SYSTEM; 구 controller 비인스턴스 | VERIFIED |
| `INT-001` | High | PLIC | MIE/MPIE/mie/mip/external IRQ 없음. | dedicated PLIC/CPU interrupt spec. | `07_interrupt_architecture`, `21_cpu_core` | later | DEFERRED |
| `INT-002` | High | PLIC | PLIC address/source/claim-complete 미정. | dedicated PLIC spec. | future PLIC | later | DEFERRED |

Phase 4A-3B CPU 아키텍처 구현과 해당 범위의 검증은 3B-CLOSE `TRAP-002` 정밀도 상호작용 매트릭스와 선행 회귀 PASS 후 **COMPLETE**다. 이미 held된 CSR과 older EX 사건은 CSR 최초 획득 우선순위상 도달 불가능하며, 실제 held-owner 취소는 older MEM final ERROR로 검증했다. 전체 baseline cleanup·외부 I/O·보드·펌웨어·PLIC·AXI 완료를 뜻하지 않는다.

---

# Part II — Board I/O

## 9. GPIO / SW / LED

| ID | Sev | Gate | 현재 문제 | 필요한 결과 | Verification | Status |
|---|---|---|---|---|---|---|
| `BOARDIO-001` | Blocker | BC | 과거 legacy mixed pseudo-GPIO. | slot1 true GPIO DATA_IN/OUT/DIR, sync, tri-state, IRQ 유지. | P04 direction/IRQ/W1C/post-fit OE | VERIFIED |
| `BOARDIO-002` | Blocker | BC | 과거 JP1 pin/cabling 불확실성 해소; 정량 외부 timing/electrical은 STA-002 소유. | `GPIO_WIDTH=16`, JP1 GPIO_0–15 승인 package pin 1:1 및 충돌 없음 유지. | P03A 사용자 확인 + P04 16/16 post-fit | VERIFIED |
| `BOARDIO-003` | High | BC | 과거 SW legacy GPIO 소유를 P04에서 제거. | slot8 APB_SW + sync/pending/W1C/sw_irq 유지. | P04 all switches + IRQ | VERIFIED |
| `BOARDIO-004` | High | BC | P04 단일 APB_LED 소유 구현; 필수 물리 LED board test 없음. | slot9 APB_LED, LEDR[9:0], reset hardwire 제거 상태 유지 및 승인 완료. | walking/all-on/off board | OPEN |
| `BOARDIO-005` | High | BC | 과거 active top에는 local gpio_irq/sw_irq가 없었으나 P04가 baseline-local wire를 구현·검증함. | local wires 유지, CPU는 PLIC 전 미연결; consumer가 없어 fitter가 prune하는 것은 허용. | P04 instrumentation + final closure review | VERIFIED |
| `BOARDIO-006` | High | BC | 과거 duplicate ownership 위험. | final top single owner 유지. | P04 lint/connectivity/post-fit | VERIFIED |

P04와 후속 User/Chat 승인으로 `BOARDIO-001/002/003/006`은 `VERIFIED`다. `BOARDIO-002`는 pin binding/ownership/no-conflict를 닫지만 peer별 voltage/load/timing, I/O delay, drive strength, ADC/VGA 공존은 `STA-002`에 남는다. `BOARDIO-004/005`, `FW-005/007`, `VER-005`는 각각의 별도 근거가 남아 있다.

---

# Part III — Peripheral Cleanup

## 10. VGA

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `VGA-001` | High | BC | P08B canonical decode/negative DV PASS; review 대기 | IN_PROGRESS |
| `VGA-002` | Medium | BC | aligned32 write-only, read/subword ERROR, byte helper 제거 PASS; review 대기 | IN_PROGRESS |
| `VGA-003` | High | BC | busy/not-ready 2-cycle ERROR와 rejected WE 억제 PASS; review 대기 | IN_PROGRESS |
| `VGA-004` | High | BC | clear target latch와 one-outstanding PASS; review 대기 | IN_PROGRESS |
| `VGA-005` | Medium | BC | sticky W1C DONE/ABORT, live BUSY/READY PASS; review 대기 | IN_PROGRESS |
| `VGA-006` | High | BC | 9600-word RTL clear PASS, Quartus/board NOT_RUN | IN_PROGRESS |
| `VGA-007` | Low | OPT | dormant APB VGA 정리 | OPEN |

## 11. UART

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `UART-001` | High | BC | 두 production UART의 exact 8-N-1/active-divisor timing과 stop 완료 즉시 TX_READY 복귀를 P07B waveform/cycle test로 검증 | VERIFIED |
| `UART-002` | High | BC | busy DATA PREADY backpressure, 정확히 1회 수락, pending-start hazard 제거; `p07b_uart_03` 실제 AHB/APB wait 2167 sampled cycles PASS | VERIFIED |
| `UART-003` | High | BC | 두 독립 module의 framing/no-commit, overflow drop-new/preserve-old, sticky/W1C, set-dominant collision, reset clear를 `p07b_uart_supplement_02` exit 0으로 검증; collision은 priority-logic test | VERIFIED |
| `UART-004` | Medium | BC | empty DATA zero/no-pop, CONTROL RAZ/WI, BAUD 217..65535/invalid ignore/active latch, canonical local decode를 P07B focused regression으로 검증 | VERIFIED |
| `UART-005` | High | BC | open protocol regression은 있으나 식별 가능한 source/build의 PC/LoRa physical multi-byte board evidence가 없음 | OPEN |
| `UART-006` | Medium | OPT | duplicate RTL refactor optional | OPEN |
| `UART-IRQ` | Medium | PLIC | IRQ contract | DEFERRED |

2026-09-16 User/Chat은 P07B와 focused supplement를 Open Verification으로
승인했다. 이 승인은 `UART-001..004`만 종결하며 post-fit timing, physical
UART/LoRa, external-I/O electrical acceptance가 아니다. `UART-005`는 OPEN,
`UART-006`은 optional/OPEN, `UART-IRQ`는 DEFERRED를 유지한다.

## 12. Timer

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `TIMER-001` | High | BC | A5 exact-N one-shot 구현; N=0/1/2/N, maximum near-terminal, terminal hold, repeated START 검증 | VERIFIED |
| `TIMER-002` | Medium | BC | STOP same-edge 우선순위와 programmed/active COMPARE 분리 검증 | VERIFIED |
| `TIMER-003` | High | BC | sticky READY/W1C, W1C no-auto-restart, terminal set-dominant collision 검증 | VERIFIED |
| `TIMER-004` | High | BC | self-checking focused Timer 및 open/bus/reset regression PASS | VERIFIED |
| `TIMER-005` | Low | OPT | `counter_debug` 제거, reference 없음, whole-SoC lint/elaboration PASS | VERIFIED |
| `TIMER-IRQ` | Medium | PLIC | IRQ contract | DEFERRED |

## 13. G-Sensor

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `GS-001` | Blocker | BC | atomic XYZ + VALID/SEQ | OPEN |
| `GS-002` | High | BC | Phase 3 known-pattern X/Y/Z extraction 검증 완료; GS-001/CDC-002는 별개 | VERIFIED |
| `GS-003` | Medium | BC | acquisition rate/INT policy | OPEN |
| `GS-004` | Medium | BC | pre-first-sample validity | OPEN |
| `GS-005` | High | BC | sim + board evidence | IN_PROGRESS |
| `GS-IRQ` | Medium | PLIC | PLIC source 선택 시 정의 | DEFERRED |

## 14. Private SPI

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `SPI-001` | High | BC | 16/56-bit bit/CS/sample timing regression | VERIFIED |
| `SPI-002` | High | BC | 승인된 A6 PCLK-only clock-enable FSM, registered mode-3 SCLK; active SPI PLL 제거 | IN_PROGRESS |
| `SPI-003` | Medium | OPT | generic SPI로 claim 금지 | DEFERRED |
| `SPI-004` | Medium | OPT | transport/policy 분리 optional | OPEN |

## 15. AES-GCM

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `AES-001` | Blocker | BC | actual VHDL core KAT | VERIFIED |
| `AES-002` | High | BC | LEN>16 reject | OPEN |
| `AES-003` | High | BC | byte/word ordering freeze | OPEN |
| `AES-004` | High | BC | auth 성공 전 plaintext release 금지 | OPEN |
| `AES-005` | High | BC | key zeroization policy | OPEN |
| `AES-006` | Medium | BC | BUSY mutation / CLR_STATUS semantics | OPEN |
| `AES-007` | Medium | BC | alias + timeout | OPEN |
| `AES-IRQ` | Medium | PLIC | IRQ | DEFERRED |
| `AES-DMA` | Medium | AXI | streaming/DMA | DEFERRED |

## 16. ADC / Joystick

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `ADC-001` | Blocker | BC | command owner 단일화 | OPEN |
| `ADC-002` | High | BC | enable/channel semantics 정상화 | OPEN |
| `ADC-003` | High | BC | atomic XY/sequence/error | OPEN |
| `ADC-004` | High | BC | physical polarity + a/d mapping | OPEN |
| `ADC-005` | Medium | BC | acquisition/joystick 경계 | OPEN |
| `ADC-006` | High | BC | async regression + board | OPEN |

## 17. HEX

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `HEX-001` | High | BC | stale HEXx[7] QSF 제거 | IN_PROGRESS |
| `HEX-002` | Medium | BC | raw mode proof | OPEN |
| `HEX-003` | Medium | BC | CTRL/reset/shadow ownership | OPEN |
| `HEX-004` | Low | OPT | DP/PWM/blink 등 별도 spec 전 금지 | DEFERRED |

---

# Part IV — Firmware Cleanup

## 18. Firmware

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `FW-001` | High | BC | P08B framebuffer byte-write API/use 제거와 영향 FW build/host test PASS; broader review 대기 | IN_PROGRESS |
| `FW-002` | High | BC | UART/LoRa finite TX/AUX budget, distinct timeout, zero-budget 및 caller migration evidence는 PASS; Timer/VGA/AES 등 global bounded-wait 잔여 | OPEN |
| `FW-003` | Medium | BC | driver ownership/direct-MMIO 정리 | OPEN |
| `FW-004` | High | BC | A5 fresh one-shot driver/application migration; host ordering 및 `final_main`/`benchmark_main` RV32I build PASS | VERIFIED |
| `FW-005` | High | BC | P04 driver 분리/host PASS, 필수 board evidence 없음 | OPEN |
| `FW-006` | High | BC | SW/LED constants + 16-slot map migration | VERIFIED |
| `FW-007` | High | BC | true GPIO/IRQ driver/host 구현; BOARDIO-001/002 dependency 해소, 명시적 GPIO board test 잔여 | IN_PROGRESS |
| `FW-008` | High | BC | coherent Gsensor API | OPEN |
| `FW-009` | High | BC | coherent ADC API | OPEN |
| `FW-010` | High | BC | AES hardening | OPEN |
| `FW-011` | Medium | BC | stale LED/GPIO assumption 제거 | VERIFIED |
| `FW-012` | High | BC | host + FPGA regression 확대 | IN_PROGRESS |

---

# Part V — Verification / Build / Evidence

## 19. Required Evidence

| ID | Sev | Gate | 핵심 작업 | Status |
|---|---|---|---|---|
| `VER-001` | Blocker | BC | repo-wide lint/elaboration/basic sim | IN_PROGRESS |
| `VER-002` | Blocker | BC | bus/APB/peripheral regression | IN_PROGRESS |
| `VER-003` | Blocker | BC | async clock/reset CDC regression | OPEN |
| `VER-004` | Blocker | BC | fresh Quartus + TimeQuest | IN_PROGRESS |
| `VER-005` | Blocker | BC | FPGA board acceptance | OPEN |
| `VER-006` | High | BC | actual-core AES KAT evidence | OPEN |
| `VER-007` | High | BC | source→ELF→MIF→SOF chain | OPEN |
| `VER-008` | Blocker | BC | `21_cpu_core` CPU regression: shift/JALR/legality/retire/trap/FENCE/CSR-ID/counter-write-ignore | VERIFIED |
| `DOC-001` | High | BC | verified target text를 active로 승격 | OPEN |
| `REPORT-001` | High | BC | cleanup milestone report | OPEN |

## 20. Board Acceptance

최소:

- VGA render/VSync/swap/HW clear,
- UART1 PC TX/RX,
- UART0 LoRa/electrical TX/RX/AUX,
- HEX decoded/raw(if retained),
- SW[9:0] + sw_irq instrumentation,
- LEDR[9:0],
- selected GPIO I/O + IRQ,
- G-sensor orientation/motion,
- ADC joystick center/polarity/direction,
- AES board smoke.

CPU architecture cleanup은 `VER-008`이 주 증거이며, cleaned CPU가 board acceptance firmware를 정상 boot/run하는 것도 확인한다.

---

# Part VI — Deferred

## 21. PLIC

Baseline cleanup 범위 아님:

- PLIC MMIO/source ID/priority/threshold/claim-complete,
- CPU external IRQ,
- functional MIE/MPIE/mie/mip,
- interrupt mcause/priority,
- optional UART/Timer/AES/Gsensor IRQ,
- ISR dispatch,
- full interrupt-state MRET restore.

`gpio_irq`, `sw_irq` local source wire는 cleanup에서 노출 가능하지만 CPU 연결은 PLIC stage까지 하지 않는다.

## 22. AXI / DMA / External Memory

- AXI interconnect / AXI-to-APB,
- multi-channel DMA/arbitration,
- SDRAM,
- staging buffer,
- D-cache,
- streaming AES,
- baseline CPU/DMEM sideband 대체.

## 23. Optional

- generic SPI,
- UART de-dup,
- HEX DP/PWM/blink,
- generalized ADC,
- GPIO pinmux/pull,
- optional framebuffer readback.

---

# Part VII — Dependency / Decision

## 24. Critical Dependency

```text
CPU-003..009 ------> VER-008
      |                |
      +--> TRAP-003/004|
BUS-003 --------------+

BOARDIO-002 [VERIFIED] -> BOARDIO-001 [VERIFIED] -> FW-007 [IN_PROGRESS: board test 잔여]
BUS-003 -> APB-004 / TRAP-003
APB-001..003 -> SW / LED / FW-006
RST-002 + STA-001 -> VGA/Gsensor/ADC CDC

all cleanup -> VER-001..008 -> DOC/REPORT -> cleanup gate close
```

## 25. 동결된 Phase 4A 설계 결정과 남은 물리 의존성

| 결정 | 승인된 cleanup 목표 | 구현/물리 상태 |
|---|---|---|
| A1 GPIO | `GPIO_WIDTH=16`, JP1 GPIO_0–15 1:1; UART/LoRa JP1 27/29/31/34/35 제외 | P04 source/open/post-fit과 User/Chat 승인으로 BOARDIO-001/002/003/005/006 VERIFIED. FW-007은 IN_PROGRESS이며 board test와 VER-005, STA-002는 별도 잔여. |
| A2 bus/APB fault | canonical invalid access는 2-cycle `HRESP=01` ERROR; APB default error/`PSLVERR` 전달; CPU load/store cause 5/7, precise mepc/side effect/retire | Phase 4A-3A와 후속 3B3R 근거로 BUS-003, APB-004, 전체 TRAP-003 VERIFIED. |
| A3 VGA | framebuffer write-only, aligned 32-bit; read/subword/gap/alias ERROR | P08B local candidate 구현/open DV PASS; `VGA-002`, `FW-001`은 User/Chat review 대기 IN_PROGRESS |
| A4 UART | busy DATA write PREADY=0 backpressure 후 정확히 1회 수락; programmed/per-direction-active divisor | P07B open verification과 User/Chat 승인으로 UART-001..004 VERIFIED; UART-005 physical board evidence OPEN, UART IRQ DEFERRED, P07B RTL은 later consolidated Quartus/P14 대상 |
| A5 timer | exact-N-edge one-shot, N=0 즉시, fresh START, STOP/RELOAD, sticky READY/set-dominant W1C | P06B evidence로 TIMER-001..005/FW-004 VERIFIED; APB-005는 Timer sub-scope evidence만 기록하고 OPEN, FW-002 OPEN, TIMER-IRQ DEFERRED 유지 |
| A6 private SPI | 50 MHz PCLK/clock-enable mode-3 FSM, registered 약 2 MHz SCLK; old dual-phase SPI PLL은 target에서 inactive | SPI-002 IN_PROGRESS; RST-002/STA-001 evidence 필요 |
| STA-002 external I/O | High/BC 외부 timing/electrical/physical gate; 임의 delay 금지, ADC/VGA warning 측정/처분 | 설계 동결; 물리 parameter/board evidence 대기로 BLOCKED |

CPU policy는 모두 종료됨:

```text
GPR reset       x1..x31 unspecified
mvendorid       0x0000_0000
marchid         0x0000_0000
mimpid          0x0001_0000
mhartid         0x0000_0000
FENCE/FENCE.I   legal no-op
EBREAK          precise breakpoint -> mtvec
counters        cleanup에서는 read-only; write는 legal no-effect/write-ignore, RO라는 이유만으로 trap 없음
```

A1–A6과 STA-002의 architecture 선택은 Phase 4A-1 local review decision package에 근거하여 **APPROVED/FROZEN**이다. 비공개 절대경로는 이 공개 spec에 기록하지 않는다. 이는 RTL/FW VERIFIED를 의미하지 않으며 각 BC item에는 구현 및 요구 evidence가 필요하다.

## 26. Tracker 유지 규칙

1. commit/PR에 tracker ID 기록.
2. behavior 변경 시 owning spec 먼저 수정.
3. RTL/FW 구현.
4. verification 추가/수정.
5. evidence 연결.
6. review 후에만 `VERIFIED`.

Code-only fix는 `IN_PROGRESS`이며 `VERIFIED`가 아니다.

## P08B 구현 진입 주석

User/Chat은 startup의 `mtvec` write commit 이후 firmware trap-policy
compatibility만 Gate 0 scoped PASS로 승인했다. 기존 Gate 0 STOP은 historical
evidence로 유지한다. 그 이전 구간은
`RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT`이라는 미검증 architectural
risk이다. 이 결정은 P08B 구현을 허가하지만 VGA/CDC/FW tracker row를
VERIFIED로 바꾸거나 Clean Baseline v1 release, 최신 local candidate의
publication을 뜻하지 않는다.
