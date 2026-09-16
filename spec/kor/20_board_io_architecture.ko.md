# Target SoC Board I/O Architecture Specification — 한국어 Companion

> **P04 종결 주석(2026-09-15):** 승인된 GPIO/SW/LED 단일 소유 구조와 JP1 16핀 공개 할당을 구현했다. 공개 검증과 사용자 실행 Quartus 피팅이 통과했고 User/Chat은 `APB-001`, `BOARDIO-001/002/003/005/006`, `FW-006`, `FW-011`을 `VERIFIED`로 승인했다. `FW-007`은 명시적 board test 대기 IN_PROGRESS다. 아래 P04 이전 그림은 이력이다. `BOARDIO-004`, `FW-005/007`, 보드 승인과 `STA-002`는 별도 잔여다.

> **상태:** TARGET DRAFT — baseline-cleanup 재설계를 위한 승인된 architecture direction이다. 이 구조는 아직 active FPGA baseline에 완전히 구현되어 있지 않다.
>
> **정본 언어:** 영어. 이 문서와 `spec/20_board_io_architecture.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`, `gpio.md`, `sw.md`, `led.md`.

## 1. 목적

이 문서는 legacy `APB_GPIO`, DE10-Lite switch, LED 사이의 결합을 제거하고 board I/O를 재구성하는 cross-cutting target architecture를 정의한다.

핵심 결정은 다음과 같다.

- APB select vector를 8 slot에서 16 slot로 확장
- 기존 GPIO APB slot 유지
- legacy GPIO를 true bidirectional GPIO로 재설계
- DE10-Lite slide switch를 전용 `APB_SW`로 분리
- DE10-Lite red LED를 전용 `APB_LED`로 분리
- SW/LED를 신규 APB slot 8/9에 배치
- slot 10~15 reserved
- GPIO/SW에 future PLIC 연결을 위한 IRQ wire 제공
- baseline cleanup 시 migration/verification 요구사항 정의

이 문서는 system-level integration과 ownership을 담당하며, 상세 local register semantics는 `gpio.md`, `sw.md`, `led.md`가 담당한다.

## 2. Baseline 문제

현재 active FPGA baseline은 `APB_GPIO`를 board-specific mixed I/O block처럼 사용한다.

```text
                    legacy APB_GPIO
                   /               \
                  /                 \
          SW[9:0] input        gpio_out[9:0]
                                   |
                                   +--> LEDR[8:0]

LEDR[9] <--------------------------- ~HRESETn
```

현재 `GPIO_DIR`은 실제 pin direction을 제어하지 않고 DATA read source만 선택한다.

따라서 target cleanup에서는 GPIO APB slot을 제거하지 않고, SW/LED board wiring만 제거한 뒤 실제 general-purpose GPIO로 재설계한다.

## 3. Target Architecture 요약

```text
                          APB subsystem
                               |
          +--------------------+--------------------+
          |                    |                    |
          v                    v                    v
      APB_GPIO              APB_SW               APB_LED
          |                    |                    |
          |                    |                    |
  GPIO_IO[N-1:0]          SW[9:0]              LEDR[9:0]
   bidirectional          input only            output only
          |                    |
          |                    +--> sw_irq ---------+
          |
          +--> gpio_irq ----------------------------+--> future PLIC
```

역할은 다음처럼 분리한다.

- `APB_GPIO`: reusable bidirectional external digital I/O
- `APB_SW`: DE10-Lite switch input + change-event IRQ
- `APB_LED`: DE10-Lite LED output

SW와 LED는 더 이상 `APB_GPIO`를 통하지 않는다.

## 4. APB Expansion Policy

### 4.1 Select width

```text
baseline: PSEL[7:0]
target:   PSEL[15:0]
```

Target APB subsystem은 approved APB region 안에서 `PADDR[19:16]`을 사용해 16개의 64-KiB slot을 제공한다.

### 4.2 Target slot allocation

| `PSEL` | Canonical base | Peripheral | Status |
|---:|---:|---|---|
| 0 | `0x4000_0000` | UART0 / LoRa | existing |
| 1 | `0x4001_0000` | GPIO | existing slot, redesign |
| 2 | `0x4002_0000` | Timer | existing |
| 3 | `0x4003_0000` | G-sensor | existing |
| 4 | `0x4004_0000` | AES-GCM | existing |
| 5 | `0x4005_0000` | ADC Joystick | existing |
| 6 | `0x4006_0000` | UART1 / PC | existing |
| 7 | `0x4007_0000` | HEX Display | existing |
| 8 | `0x4008_0000` | SW | new |
| 9 | `0x4009_0000` | LED | new |
| 10 | `0x400A_0000` | Reserved | reserved |
| 11 | `0x400B_0000` | Reserved | reserved |
| 12 | `0x400C_0000` | Reserved | reserved |
| 13 | `0x400D_0000` | Reserved | reserved |
| 14 | `0x400E_0000` | Reserved | reserved |
| 15 | `0x400F_0000` | Reserved | reserved |

기존 peripheral base address는 이동하지 않는다.

### 4.3 Reserved slot

slot 10~15는 별도 승인 spec이 생기기 전까지 reserved이다.

Software는 reserved slot을 사용하면 안 된다. 승인된 A2 default APB ERROR가 적용되며 baseline silent zero/OKAY는 target contract가 아니다.

## 5. APB Decoder / Response Mux 요구사항

다음 항목을 16-slot 기준으로 일관되게 확장해야 한다.

- bridge `PSEL` width
- `decode_psel()` 또는 equivalent decoder
- SoC top-level wiring
- `PRDATA` mux
- `PREADY` mux
- verification assertion/scoreboard
- 8-slot assumption이 들어간 debug/testbench logic

개념적으로:

```text
slot = PADDR[19:16]
PSEL = 16'b1 << slot
```

은 approved canonical APB region의 active transaction일 때만 생성되어야 한다.

기존 higher-address alias도 decoder 정리와 함께 제거한다.

## 6. Target GPIO Role

### 6.1 Slot / ownership

GPIO는 기존 위치를 유지한다.

```text
GPIO_BASE = 0x4001_0000
PSEL[1]
```

Target GPIO는 더 이상 다음에 연결되지 않는다.

```text
SW[9:0]
LEDR[9:0]
```

이 신호는 각각 `APB_SW`, `APB_LED`가 독점적으로 소유한다.

### 6.2 Authoritative local GPIO contract

Target GPIO 상세 peripheral contract는 이제 `gpio.md` (`spec/11_gpio.md`)에서 확정되었다.

따라서 RTL 구현 시 별도의 임의 register model을 만들지 않고 `gpio.md`를 그대로 따라야 한다.

Target GPIO는 parameterized true bidirectional bank이며:

```text
1 <= GPIO_WIDTH <= 32
```

를 지원한다.

Canonical target register map은:

```text
+0x00 GPIO_DATA_IN       RO
+0x04 GPIO_DATA_OUT      RW
+0x08 GPIO_DIR           RW
+0x0C GPIO_IRQ_ENABLE    RW
+0x10 GPIO_IRQ_TYPE      RW
+0x14 GPIO_IRQ_POLARITY  RW
+0x18 GPIO_IRQ_BOTH_EDGE RW
+0x1C GPIO_IRQ_PENDING   R/W1C
```

이다.

승인된 A1은 `GPIO_WIDTH=16`, JP1 `GPIO_[0:15]` 1:1 매핑이다. P04가 공개 할당을 구현하고 16개 핀을 정확히 피팅했으며 사용자가 실제 배선 충돌 없음으로 확인했다. peer별 정량 전기/timing 종결은 `STA-002`에 남는다.

### 6.3 True bidirectional semantics

```text
GPIO_DIR[i] = 0 -> input / output-enable off / Hi-Z
GPIO_DIR[i] = 1 -> output / GPIO_DATA_OUT[i] drive
```

`GPIO_DATA_OUT`은 input 상태에서도 preload 가능해야 한다.

외부 asynchronous pin은 `gpio.md`에 정의된 PCLK-domain synchronizer를 통과한 값만 `GPIO_DATA_IN`과 IRQ logic에 사용한다.

### 6.4 Finalized GPIO IRQ contract

GPIO IRQ 상세 semantics도 이제 `gpio.md`가 authoritative source다.

System-level path:

```text
gpio_irq -> future PLIC
```

Pin별로 다음 configuration을 제공한다.

```text
IRQ_ENABLE
IRQ_TYPE       : 0=level, 1=edge
IRQ_POLARITY   : level active-low/high 또는 edge falling/rising
IRQ_BOTH_EDGE  : edge mode only
IRQ_PENDING    : effective pending view, sticky edge pending은 W1C
```

필수 동작:

- input-configured pin만 GPIO IRQ source가 될 수 있다.
- level mode pending은 synchronized active level을 live하게 반영한다.
- edge mode event는 sticky pending에 저장한다.
- 같은 cycle의 edge event + W1C에서는 새 event가 우선하는 set-dominant semantics를 사용한다.
- direction change로 stale/false edge IRQ가 발생하면 안 된다.
- `gpio_irq`는 active-high level signal이다.

```text
gpio_irq = |(GPIO_IRQ_PENDING & GPIO_IRQ_ENABLE)
```

PLIC source ID, priority, threshold, claim/complete, CPU CSR, interrupt-entry semantics는 future PLIC spec이 담당한다.

## 7. Dedicated SW Peripheral

```text
SW_BASE  = 0x4008_0000
PSEL[8]
SW[9:0]  -> APB_SW
```

Detailed contract는 `sw.md`가 담당한다.

주요 기능:

- 10-bit synchronized switch input
- current-state readback
- sticky per-switch change pending
- per-switch IRQ enable
- set-dominant W1C race handling
- active-high level `sw_irq`

```text
SW[9:0]
   |
2FF synchronization
   |
change detect
   |
IRQ_PENDING[9:0]
   |
& IRQ_ENABLE[9:0]
   |
OR
   |
 sw_irq
   |
future PLIC
```

PLIC source ID는 아직 TBD다.

## 8. Dedicated LED Peripheral

```text
LED_BASE   = 0x4009_0000
PSEL[9]
APB_LED -> LEDR[9:0]
```

Detailed contract는 `led.md`가 담당한다.

10-bit output latch가 10개 LED 전체를 소유한다.

기존:

```verilog
assign LEDR[9] = ~HRESETn;
```

는 제거한다.

Reset/debug indicator가 필요하면 APB_LED bit ownership을 침범하지 않는 별도 mechanism으로 정의한다.

## 9. Interrupt Architecture 경계

Board I/O target은 다음 두 local interrupt source wire를 제공한다.

```text
gpio_irq
sw_irq
```

PLIC integration 전까지는 local peripheral output일 뿐 CPU와 연결되지 않는다.

이 문서가 정의하지 않는 항목:

- PLIC MMIO base
- PLIC source IDs
- priority
- threshold
- claim/complete
- CPU external-interrupt CSR behavior

LED에는 IRQ가 없다.

## 10. Target APB Map

```text
0x4000_0000 UART0 / LoRa
0x4001_0000 GPIO
0x4002_0000 Timer
0x4003_0000 G-sensor
0x4004_0000 AES-GCM
0x4005_0000 ADC Joystick
0x4006_0000 UART1 / PC
0x4007_0000 HEX Display
0x4008_0000 SW
0x4009_0000 LED
0x400A_0000 Reserved
0x400B_0000 Reserved
0x400C_0000 Reserved
0x400D_0000 Reserved
0x400E_0000 Reserved
0x400F_0000 Reserved
```

`memory_map.md`는 시스템 map을 기록한다. P04가 board-I/O RTL migration을 완료했으며 이 문서의 이전 baseline 그림은 이력이다.

## 11. Migration Sequence

```text
1. APB PSEL[7:0] -> PSEL[15:0] 확장
2. canonical APB decode tightening
3. PRDATA/PREADY mux 16-slot 확장
4. PSEL[0:7] 기존 주소 유지
5. PSEL[1] legacy APB_GPIO를 gpio.md target contract로 교체
6. GPIO에서 SW/LED wiring 제거
7. PSEL[8] APB_SW 추가
8. PSEL[9] APB_LED 추가
9. LEDR[9:0] 전체를 APB_LED로 연결
10. SW[9:0] 전체를 APB_SW로 연결
11. gpio_irq / sw_irq local interrupt wire 노출
12. PLIC 승인 전까지 CPU와 미연결
13. firmware memory map / driver 갱신
14. RTL regression + FPGA board acceptance
```

최종 cleanup 상태에서는 SW, LED, generic GPIO pin ownership이 중복되면 안 된다.

## 12. Firmware Migration

```text
legacy:
  gpio_read()       -> 경우에 따라 SW state
  gpio_led_write()  -> LED control

target:
  gpio_*()          -> external generic GPIO only
  gpio_irq_*()      -> GPIO IRQ config/status
  sw_read()         -> SW state
  sw_irq_*()        -> SW IRQ config/status
  led_write()       -> LED control
```

`display_smoke` 등 board diagnostic도 dedicated SW/LED driver를 사용해야 한다.

## 13. Verification Requirements

### 13.1 APB expansion

- `PSEL[15:0]`
- slot 0~9 정확한 one-hot select
- slot 10~15 reserved/default behavior
- 기존 slot 0~7 주소 불변
- slot 8/9의 `PRDATA/PREADY` routing
- low/high slot 간 back-to-back access
- unintended higher-address alias 제거

### 13.2 GPIO

`gpio.md`의 finalized target contract를 기준으로 최소 다음을 검증한다.

- parameterized width
- input/Hi-Z 및 output-drive direction behavior
- input 상태에서 DATA_OUT preload
- synchronized `GPIO_DATA_IN`
- level IRQ active-low / active-high
- rising-edge / falling-edge / both-edge
- per-pin IRQ enable
- sticky edge pending + W1C
- event와 W1C 동시 발생 시 event set-dominant
- live level pending semantics
- output-configured pin의 IRQ suppression
- direction-change 시 false/stale IRQ 방지
- active-high level `gpio_irq`
- GPIO가 `SW[9:0]`, `LEDR[9:0]`에 물리적으로 연결되지 않음

### 13.3 SW

`sw.md` 기준 synchronization, initial arm, any-change detect, sticky pending, enable masking, set-dominant W1C, repeated event, level `sw_irq`를 검증한다.

### 13.4 LED

reset-zero, 10-bit output, latch readback, independent LEDR9 reset driver 제거를 검증한다.

### 13.5 FPGA board acceptance

- 10개 SW 전체를 APB_SW로 read
- 10개 LED 전체를 APB_LED로 control
- PLIC hookup 전 local `sw_irq` behavior
- 승인된 JP1 GPIO_0–15 generic GPIO pin input/output
- QSF/실물 배선 검증 후 대표 GPIO IRQ mode

## 14. Cleanup Tracker Items

다음 번호는 과거 후보 목록이며 canonical `baseline_cleanup.md`의 정규화된 ID가 우선한다.

```text
BOARDIO-001  Expand APB PSEL[7:0] -> PSEL[15:0]
BOARDIO-002  Expand/tighten APB decoder and PRDATA/PREADY muxes
BOARDIO-003  Implement target true-bidirectional GPIO contract from gpio.md
BOARDIO-004  Remove SW/LED ownership from GPIO
BOARDIO-005  Add APB_SW at slot 8 / 0x4008_0000
BOARDIO-006  Add APB_LED at slot 9 / 0x4009_0000
BOARDIO-007  Remove LEDR[9] reset-indicator hard wiring
BOARDIO-008  Add and verify gpio_irq local source
BOARDIO-009  Add and verify sw_irq local source
BOARDIO-010  Update firmware drivers/memory map
BOARDIO-011  Add APB/board-I/O directed regression
BOARDIO-012  Perform FPGA board acceptance
```

Canonical `baseline_cleanup.md`가 정규화된 ID를 소유한다. 위 과거 후보 번호는 tracker ID로 사용하지 않는다. Slot/decode/error는 `APB-001/002/004/005`, GPIO/SW/LED 소유권과 local wire는 `BOARDIO-001..006`, FW driver는 `FW-005..007`, physical verification은 `VER-005`와 board acceptance evidence에 매핑한다. 특히 canonical `BOARDIO-002`는 위의 과거 decoder 항목이 아니라 동결된 16-pin GPIO binding/physical validation이다. 중복 tracker item은 만들지 않는다.

## 15. Architectural Invariants

Target implementation에서는 다음이 invariant다.

1. APB는 `PSEL[15:0]`을 사용한다.
2. 기존 slot 0~7 base address는 유지한다.
3. GPIO는 `PSEL[1] / 0x4001_0000`에 유지한다.
4. GPIO는 DE10-Lite SW/LED를 소유하지 않는다.
5. GPIO는 `gpio.md`의 finalized true-bidirectional + IRQ contract를 구현한다.
6. SW는 `PSEL[8] / 0x4008_0000`이다.
7. LED는 `PSEL[9] / 0x4009_0000`이다.
8. slot 10~15는 reserved다.
9. `LEDR[9:0]` 전체는 `APB_LED`가 소유한다.
10. `SW[9:0]` 전체는 `APB_SW`가 소유한다.
11. `gpio_irq`, `sw_irq`는 future PLIC용 active-high local level interrupt source다.
12. 이 문서는 PLIC source ID를 배정하지 않는다.
13. software는 reserved slot이나 noncanonical alias에 의존하지 않는다.

## 16. Related Specifications

- `01_memory_map.md` — current baseline map + approved 16-slot target migration
- `05_apb_subsystem.md` — active P04 16-slot 구현 + cleanup 전 이력
- `07_interrupt_architecture.md` — current no-PLIC baseline + future interrupt boundary
- `11_gpio.md` — baseline GPIO 기록과 **finalized target GPIO register/IRQ contract의 authoritative source**
- `17_sw.md` — detailed target SW contract
- `18_led.md` — detailed target LED contract
- future `19_firmware_contract.md`
- future consolidated `baseline_cleanup.md`
- future approved PLIC specification

System-level ownership/slot 결정과 local peripheral spec이 충돌하면 RTL 구현 전에 `spec/`에서 먼저 해결해야 한다.

## Phase 4A-2 승인된 pin/external-closure 계약 (pin binding 현행, STA-002 open)

A1 `GPIO_IO[0:15]` ↔ DE10-Lite JP1 `GPIO_[0:15]` 1:1이며 ascending package pin은 `V10,W10,V9,W9,V8,W8,V7,W7,W6,V5,W5,AA15,AA14,W13,W12,AB13`이다. P04 fit은 16개 모두를 bidirectional 3.3-V LVTTL 및 bit별 direction/OE로 배치했고 duplicate pin이나 UART/LoRa 충돌이 없으며 사용자가 배선 충돌 없음으로 확인했다. GPIO_27/29/31/34/35는 UART/LoRa 소유다. Reset DIR=input/Hi-Z, DIR=0 input/Hi-Z, DIR=1 drive, PCLK 2FF input sync 및 `11_gpio.md` local IRQ 계약을 적용한다.

### 재사용 가능한 GPIO 전기 사용 정책

- GPIO는 3.3-V LVTTL이며 5-V tolerance를 가정하지 않는다.
- FPGA GPIO가 output일 때 외부 output과 맞물려 연결하지 않는다.
- output mode 전에 외부 peer voltage와 drive/load 호환성을 확인한다.
- pin별 명시적 drive-strength가 없으면 Quartus 기본 동작을 사용하나 peer별 승인값은 아니다.
- peer 요구에 따라 근거 검토 후 명시적 drive strength나 추가 constraint가 필요할 수 있다.
- peer timing/load, I/O delay, signal integrity와 전체 external timing 종결은 `STA-002` 소유다.

`BOARDIO-002 VERIFIED`는 baseline pin binding, package ownership/no-conflict와 위 사용 계약 승인이다. `STA-002` 종결을 뜻하지 않는다. STA-002의 port 분류, 근거 있는 I/O delay/N/A, voltage/drive/load, unconstrained port, ADXL345 timing, ADC/VGA warning·보드 측정/위험 처분은 남아 있다.
