# Baseline SoC UART Subsystem Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/09_uart.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.
>
> **P07B 현행 우선 규칙:** 20절은 구현된 P07B 계약이다. 앞부분의 복원된
> baseline 설명과 충돌하면 20절을 현행 구현 계약으로 적용한다. 이전 설명은
> Full Spec Refresh 전까지 역사적 cleanup 문맥으로 보존한다.
>
> **P07 종결(2026-09-16):** User/Chat은 P07B와 focused supplement를 Open
> Verification으로 승인했다. `UART-001..004`는 `VERIFIED`다. 식별 가능한
> source/build의 PC/LoRa physical acceptance가 없는 `UART-005`는 `OPEN`,
> `UART-006`은 optional/OPEN, UART IRQ는 DEFERRED를 유지한다.

## 1. 목적

이 문서는 active FPGA baseline의 두 APB UART peripheral을 정의한다.

- UART0 / LoRa: `0x4000_0000`, `APB_UART_LORA`
- UART1 / PC: `0x4006_0000`, `APB_UART`

Software-visible register behavior, UART line format, baud divisor, TX/RX state machine, RX FIFO, LoRa AUX extension, polling requirement, error behavior, baseline cleanup 항목을 포함한다.

현재 UART는 **polling peripheral**이며 interrupt output이 없다. `UART_CONTROL` register 역시 저장 기능만 있고 실제 control 동작은 없다.

## 2. Active RTL 경계

현재 실제 integration은 다음과 같다.

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +--> PSEL[0] --> APB_UART_LORA --> LoRa UART TX/RX + AUX
 |
 +--> PSEL[6] --> APB_UART      --> PC UART TX/RX
```

Active RTL:

```text
rtl/peripherals/APB_UART_LORA_RT.v
rtl/peripherals/APB_UART_RT.v
rtl/soc/AMBA_SoC_TOP.v
```

두 UART 모두 50 MHz APB clock domain에서 동작한다.

```text
PCLK = 50 MHz
PRESETn = system APB reset
```

두 slave는 보통 `PREADY=1`이다. 유일한 UART wait-state는 busy 상태의
`UART_DATA` write이며, TX가 해당 transfer를 정확히 한 번 수락할 때까지
`PREADY=0`을 유지한다. Read와 DATA 이외 write는 TX busy만으로 stall하지 않는다.

## 3. Canonical Address Map

### 3.1 UART0 / LoRa

```text
Base: 0x4000_0000
APB slot: PSEL[0]
```

### 3.2 UART1 / PC

```text
Base: 0x4006_0000
APB slot: PSEL[6]
```

두 UART의 canonical register offset은 동일하다.

| Offset | Register | Access | 구현 field 폭 | 요약 |
|---:|---|---|---:|---|
| `0x00` | `UART_DATA` | R / W | 8 bits | write 시 TX data, read 시 RX FIFO front, read는 1 byte pop |
| `0x04` | `UART_STATUS` | R | 3 또는 4 bits | TX ready, RX ready, RX error, UART0은 LoRa AUX 추가 |
| `0x08` | `UART_CONTROL` | RAZ/WI | — | reserved, read zero/write ignored |
| `0x0C` | `UART_BAUD` | R / W | 16 bits | baud divisor |

RTL은 full 16-bit local offset을 비교하고 네 canonical offset만 구현한다.
Noncanonical local read는 0, write는 무효이며 과거 16-byte mirror는 제거됐다.

Firmware는 위 exact offset에 대해 naturally aligned 32-bit MMIO access만 사용해야 한다.

## 4. UART Line Format

두 UART는 동일한 asynchronous serial format을 사용한다.

```text
Idle    : 1
Start   : 0
Data    : 8 bits, LSB first
Parity  : none
Stop    : 1 bit
```

즉 baseline format은:

```text
8-N-1
```

이다.

TX shift register는:

```text
{ stop=1, data[7:0], start=0 }
```

형태로 load되고 right shift되어 bit 0부터 송신된다.

Parity, word length, stop-bit 수를 software로 변경하는 기능은 없다.

## 5. Baud Divisor Contract

`UART_BAUD[15:0]`는 UART 한 bit period당 사용하는 PCLK cycle 수를 저장한다.

의도된 관계는:

```text
baud_rate ≈ PCLK / baud_div
```

이다.

Baseline PCLK 50 MHz, reset divisor 434에서는:

```text
50,000,000 / 434 ≈ 115,207.37 bit/s
```

로 약 115200 baud이다.

Reset 값:

```text
UART_BAUD = 434
```

### 5.1 Programming rule

현행 RTL은 217..65535를 수락하고 0..216 write는 이전 programmed 값을
보존한다. TX는 DATA 수락 시, RX는 start 검출 시 programmed divisor를 각 방향의
active 값으로 capture하며 현재 frame 동안 고정한다. 따라서 BAUD write는 진행 중
frame을 바꾸지 않고 다음 frame에 반영된다. 외부 peer는 호환되는 nominal rate를
사용해야 한다.

## 6. TX Architecture

### 6.1 TX FIFO 없음

현재 UART는 TX shift register를 가지며 **TX FIFO는 없다**.

Software flow는 다음과 같다.

```text
poll UART_STATUS.TX_READY
        |
        v
write UART_DATA[7:0]
        |
        v
one 8-N-1 serial frame
```

`TX_READY == 0`에서 DATA write가 제시되면 APB ACCESS가 `PREADY=0`으로
유지된다. TX가 가능해지면 handshake가 정확히 한 byte를 수락하고 transaction이
끝난다. Firmware는 latency/timeout 제어를 위해 bounded `TX_READY` polling을
사용하지만 데이터 보존 정확성이 polling 하나에만 의존하지 않는다.

### 6.2 TX_READY 의미

```text
UART_STATUS[0] = TX_READY = !tx_busy
```

| `TX_READY` | 의미 |
|---:|---|
| 0 | 새 TX byte를 받을 수 없음 |
| 1 | `UART_DATA` write로 새 byte 송신 가능 |

### 6.3 TX completion

실제 serial frame은 정상적으로 10 bit period이다.

```text
1 start + 8 data + 1 stop
```

`TX_READY`는 stop-bit interval을 완료하는 edge에 다시 1이 된다. 다음 DATA
수락 전 별도의 idle-high divisor interval을 추가하지 않는다.

## 7. RX Architecture

### 7.1 External input synchronization

`uart_rx`는 PCLK에 asynchronous하므로 RX FSM 전에 2-FF synchronizer를 통과한다.

```text
uart_rx
  |
  v
2-FF synchronizer
  |
  v
RX FSM
```

Synchronizer reset 값은 UART idle level과 같은 1이다.

### 7.2 RX state machine

현재 RX FSM:

```text
IDLE -> START -> DATA -> STOP -> IDLE
```

동작은 다음과 같다.

- `IDLE`: RX low를 potential start bit로 감지
- `START`: 약 half-bit 이후에도 low인지 재확인
- `DATA`: divisor 간격마다 8 bit를 LSB first로 sample
- `STOP`: stop bit를 sample하여 정상 frame 또는 framing error 판단

Start 확인 시점에 line이 다시 high라면 false start로 보고 FIFO push 없이 `IDLE`로 복귀한다.

## 8. RX FIFO

각 UART는 16-byte RX FIFO를 가진다.

```text
Depth : 16 entries
Width : 8 bits
```

내부 상태:

```text
rx_fifo_wr_ptr : 4 bits
rx_fifo_rd_ptr : 4 bits
rx_fifo_count  : 5 bits, 0..16
```

### 8.1 RX_READY

```text
UART_STATUS[1] = RX_READY = (rx_fifo_count != 0)
```

### 8.2 UART_DATA read / FIFO pop

`UART_DATA`에 대한 valid APB read는:

- 현재 FIFO front byte를 `PRDATA[7:0]`에 반환하고,
- FIFO가 비어 있지 않다면 정확히 1 byte를 pop한다.

Software는 `UART_DATA` read 전에 반드시 `RX_READY`를 확인해야 한다.

FIFO가 비어 있을 때 `UART_DATA` read는 0을 반환하며 pop, pointer/count,
error 부작용이 없다.

### 8.3 Simultaneous push / pop

RTL은 같은 PCLK cycle에 RX byte push와 software pop이 동시에 발생하는 경우를 명시적으로 처리한다.

```text
FIFO count remains unchanged
```

이며 필요한 read/write pointer는 각각 진행된다.

FIFO가 이미 full이라도 같은 cycle에 software pop이 있으면 새 RX byte를 받을 수 있다.

## 9. RX Error Semantics

`UART_STATUS[2]`는 `RX_ERROR`이다.

기존 주석 일부는 framing error만 설명하지만 active RTL은 다음 둘 중 하나일 때 bit를 set한다.

1. **framing error** — stop bit sample이 low
2. **RX FIFO overflow** — valid stop bit가 도착했지만 FIFO full이고 동시에 pop도 없음

Overflow 시 새로 수신된 byte는 버려진다.

### 9.1 Clear behavior

`RX_ERROR`는 sticky이다. 정상 FIFO push/pop으로 지워지지 않는다. Reset 또는
`UART_STATUS[2]` write-one으로 clear한다. 새 framing/overflow와 W1C가 같은
edge에 발생하면 error set이 우선하여 `RX_ERROR=1`을 유지한다.

## 10. UART_CONTROL

`UART_CONTROL`은 reserved RAZ/WI이며 read는 0, write는 무효다.

현재 baseline에서는 다음을 제어하지 않는다.

- TX enable
- RX enable
- interrupt enable
- FIFO behavior
- parity
- stop bits
- loopback
- flow control

Software는 `UART_CONTROL` write가 실제 UART behavior를 바꾼다고 기대하면 안 된다.

## 11. UART0 / LoRa AUX Extension

UART0은 다음 external input을 추가로 가진다.

```text
lora_aux
```

이 신호는 별도의 2-FF synchronizer를 거쳐:

```text
UART_STATUS[3] = LORA_AUX_HIGH
```

로 software에 보인다.

| Bit 3 | 의미 |
|---:|---|
| 0 | synchronized AUX low |
| 1 | synchronized AUX high |

UART hardware 자체는 AUX에 따라 TX를 gate하지 않고 상태만 제공한다.

따라서 LoRa firmware driver가 다음 순서를 책임진다.

```text
wait AUX high
wait TX_READY
write UART_DATA
```

현재 `lora_uart` driver도 각 byte 송신 전에 AUX를 polling한다.

### 11.1 AUX reset behavior

AUX synchronizer 두 stage는 LOW/NOT READY로 reset된다. Reset release 후
persistent external level이 기존 2FF path를 거쳐 전달되며 `HIGH=READY`는 edge가
아닌 level 조건이다.

UART1에는 AUX input이 없으며 status bit 3은 구현되지 않아 0으로 읽힌다.

## 12. Register Bit Definitions

### 12.1 UART_DATA — offset `0x00`

Write:

| Bits | Name | 동작 |
|---|---|---|
| `[7:0]` | TX_DATA | `TX_READY=1`일 때만 accepted |
| `[31:8]` | — | ignored |

Read:

| Bits | Name | 동작 |
|---|---|---|
| `[7:0]` | RX_DATA | RX FIFO front; available하면 read 시 1 byte pop |
| `[31:8]` | — | 0 |

### 12.2 UART_STATUS — offset `0x04`

| Bit | Name | UART0 | UART1 | 의미 |
|---:|---|---|---|---|
| 0 | `TX_READY` | R | R | 새 TX byte accepted 가능 |
| 1 | `RX_READY` | R | R | RX FIFO non-empty |
| 2 | `RX_ERROR` | R | R | 최근 framing error 또는 FIFO overflow |
| 3 | `LORA_AUX_HIGH` | R | 0 | synchronized LoRa AUX high |
| 31:4 | Reserved | 0 | 0 | zero read |

### 12.3 UART_CONTROL — offset `0x08`

| Bits | 동작 |
|---|---|
| `[31:0]` | read zero, write ignored (RAZ/WI) |

### 12.4 UART_BAUD — offset `0x0C`

| Bits | 동작 |
|---|---|
| `[15:0]` | read/write baud divisor |
| `[31:16]` | read zero, write ignored |

## 13. Reset State

`PRESETn=0`일 때 두 UART는 다음 상태로 reset된다.

```text
programmed_baud_div = 434
tx_active_baud_div  = 434
rx_active_baud_div  = 434
tx_busy        = 0
TX output      = 1 (idle)
RX state       = IDLE
RX FIFO count  = 0
RX pointers    = 0
RX_ERROR       = 0
RX synchronizer= 1 / 1
```

UART0은 추가로:

```text
AUX synchronizer = 0 / 0 (NOT READY)
```

로 reset된다.

FIFO data array 내용 자체는 architectural reset value가 정의되지 않으며 FIFO count가 0이므로 byte를 수신하기 전까지 invalid하다.

## 14. Interrupt Architecture

Active FPGA baseline에서 두 UART 모두 interrupt output이 없다.

다음 기능은 현재 존재하지 않는다.

```text
RX interrupt
TX-empty interrupt
error interrupt
AUX interrupt
```

모든 UART 동작은 software polling이다.

`UART_CONTROL`도 future PLIC/UART interrupt spec이 behavior를 명시하기 전까지 interrupt-enable register로 해석하면 안 된다.

향후 PLIC integration 전에 source ID, level/edge policy, pending/clear semantics, FIFO threshold, `RX_ERROR`와의 관계를 먼저 specification으로 확정해야 한다.

## 15. Firmware Contract

Baseline firmware는 다음을 지켜야 한다.

1. Canonical UART0/UART1 address만 사용한다.
2. Aligned 32-bit MMIO register access를 사용한다.
3. 모든 `UART_DATA` write 전에 `TX_READY`를 poll한다.
4. 모든 `UART_DATA` read 전에 `RX_READY`를 poll한다.
5. `UART_DATA` read 1회가 FIFO 1-byte pop임을 전제로 한다.
6. `RX_ERROR`를 sticky로 처리하고 `UART_STATUS[2]` W1C로 acknowledge한다.
7. `UART_CONTROL` write의 behavioral effect에 의존하지 않는다.
8. 217..65535 divisor만 program하며 active frame은 capture한 divisor를 유지한다.
9. LoRa TX의 경우 module-level firmware policy에 따라 synchronized AUX high도 확인한다.
10. Noncanonical local offset은 사용하지 않는다. Read zero/write-ignore다.

현재 production driver는 finite polling budget과 explicit
success/timeout/invalid result를 사용한다. LoRa wrapper는 각 byte 전에 AUX를
확인하고 AUX timeout과 UART TX timeout을 구분한다.

## 16. Verification Requirements

Baseline verification은 최소 다음을 포함해야 한다.

- reset register/status value
- default divisor와 실제 bit period
- 8-N-1 TX bit ordering
- 1 frame 전후 `TX_READY` transition
- busy 상태 DATA write behavior
- software-polled back-to-back TX byte
- RX false-start rejection
- LSB-first RX reconstruction
- RX FIFO 0~16 byte fill
- `UART_DATA` read당 1-byte pop
- simultaneous FIFO push/pop
- FIFO overflow byte drop
- framing-error detection
- 현재 `RX_ERROR` clear behavior
- empty FIFO read policy
- safe/unsafe timing의 baud change
- UART0 AUX synchronization/status
- UART1 bit 3 zero 확인
- canonical test가 register mirror에 의존하지 않는지 확인

FPGA validation에서는 UART1을 PC serial terminal/test harness와 연결하고 UART0은 LoRa module 또는 별도 UART peer와 검증할 수 있다. Firmware가 실행된다는 사실만으로 physical serial timing과 pin connectivity가 증명되는 것은 아니다.

## 17. Historical Pre-P07 Cleanup Targets

아래 표는 pre-P07 cleanup inventory를 역사적으로 보존한다. P07B가
C01..C08/C11의 closure-candidate evidence를 제공하지만 이 표가 현행 계약이나
tracker review gate를 덮어쓰지는 않는다.

| ID candidate | Priority | 문제 | 필요한 방향 |
|---|---|---|---|
| UART-C01 | P1 | TX completion이 끝난 후 `TX_READY=0`이 idle 1 bit만큼 추가 유지 | TX bit-count 종료 조건 수정 후 frame/baud 재검증 |
| UART-C02 | P1 | TX busy 중 write가 조용히 drop됨 | TX FIFO/backpressure/error 등 명시적 software-visible 정책 정의 |
| UART-C03 | P1 | `RX_ERROR`가 framing error와 FIFO overflow를 혼합 | separate/sticky error 또는 counter/status 정의 |
| UART-C04 | P1 | 정상 push/pop이 `RX_ERROR`를 자동 clear | reliable diagnostic을 위한 deterministic clear 정책 정의 |
| UART-C05 | P1 | empty `UART_DATA` read 결과가 의미 없음 | deterministic empty-read behavior 또는 hardware guard 정의 |
| UART-C06 | P1 | baud divisor legal range 없음, mid-frame write 가능 | legal range와 safe-update behavior 정의 |
| UART-C07 | P1 | `UART_CONTROL`이 storage-only | PLIC 작업과 함께 실제 control/IRQ semantics 정의 또는 misleading behavior 제거 |
| UART-C08 | P1 | low-bit decode로 16-byte register mirror 생성 | canonical offset만 decode하거나 reserved offset reject |
| UART-C09 | P2 | UART0/UART1 RTL 대부분 중복 | common UART core + LoRa AUX wrapper 구조 검토 |
| UART-C10 | P1 | interrupt architecture 없음 | PLIC 전에 RX/TX/error interrupt source contract 정의 |
| UART-C11 | P1 | UART protocol directed regression이 baseline signoff artifact로 충분히 정리되지 않음 | TX/RX/FIFO/error/AUX corner case deterministic RTL test 추가 |

이 cleanup target들은 현재 구현의 약점을 기록하는 것이며 승인된 RTL/spec update 전까지 현재 baseline behavior를 변경하지 않는다.

## 18. Baseline Invariants

현재 baseline은 다음 invariant로 취급한다.

```text
UART0 base = 0x4000_0000
UART1 base = 0x4006_0000
register offsets = 0x00 / 0x04 / 0x08 / 0x0C
PCLK = 50 MHz
PREADY = busy DATA write에서만 0, 그 외 1
format = 8-N-1, LSB first
reset baud divisor = 434
RX FIFO depth = 16 bytes
TX FIFO depth = 0
TX firmware polling은 bounded, busy DATA write는 hardware backpressure
RX requires software polling
UART0 status[3] = synchronized LoRa AUX
UART1 status[3] = 0
UART_CONTROL = RAZ/WI
no UART interrupt output exists
```

향후 이 architectural property를 변경하려면 먼저 승인된 specification update가 필요하다.

## 19. 관련 Specification 및 Source

Logical specification dependency:

```text
soc_architecture.md
memory_map.md
apb_subsystem.md
reset_clock.md
interrupt_architecture.md
firmware_contract.md   # future
```

Primary active implementation evidence:

```text
rtl/peripherals/APB_UART_RT.v
rtl/peripherals/APB_UART_LORA_RT.v
rtl/soc/AMBA_SoC_TOP.v
firmware/include/soc_memory_map.h
firmware/include/uart.h
firmware/include/lora_uart.h
firmware/drivers/uart.c
firmware/drivers/lora_uart.c
```

## Phase 4A-2 승인된 UART 목표 (현행 RTL 아님)

A4에서 busy `UART_DATA` APB write는 정확히 한 byte를 수락해 한 frame을 시작할 때까지 `PREADY=0`이며 silent drop 금지다. `TX_READY`는 지금 즉시 DATA write 수락 가능을 뜻하고 수락 edge에 false가 된다. 다른 register는 단순 TX busy 때문에 stall하지 않는다. UART 전용 hardware timeout은 없으므로 모든 지원 설정은 TX forward progress를 보장해야 한다. `UART_BAUD`는 rate enum이 아닌 divisor: nominal baud=50 MHz/BAUD_DIV, default=434(~115200). 표준 rate만 hardware whitelist하지 않는다. FW preset은 9600/19200/38400/57600/115200/230400이고 peer 오차가 허용되면 다른 안전한 rate도 가능하다. Divisor 0 또는 unsafe 값은 active가 될 수 없다. 현행 TX/RX counter·start sampling·input sync만으로 최소 수치를 신뢰성 있게 정할 수 없어 `MIN_SAFE_BAUD_DIV = unresolved implementation constraint`이다. 구현 검증 전 실제 안전 범위를 도출해야 하며 FW는 bounded TX_READY polling을 사용한다. STA-002는 UART pin 전압/standard/drive/load/peer timing을 담당하고 async RX에 가짜 synchronous input delay를 부여하지 않는다.

## Phase 4A-P05A 승인 LoRa AUX Contract — 구현 목표

Project interface에서 E220-900T22D AUX는 module-to-FPGA asynchronous **level-status** 신호다. `HIGH = READY`, `LOW = NOT READY`이며 현재 synchronized HIGH이면 다음 UART-side write/transmission을 허용한다. Ready는 edge event가 아니고 rising 이후 valid window 또는 post-rising UART delay 요구사항도 없다. 이 계약을 위해 AUX edge detector, pulse stretcher, minimum-high counter 또는 delay counter를 추가하지 않는다.

기존 `lora_aux -> aux_sync_1 -> aux_sync_2` CDC는 승인한다. P05B는 2FF 구조를 유지하되 두 synchronizer reset 값을 HIGH에서 LOW/NOT READY로 변경하여 reset만으로 false ready가 노출되지 않게 한다. 이 reset-value 변경은 승인된 target이며 현재 RTL 동작을 뜻하지 않는다. Hardware는 synchronized level만 노출하고 firmware가 readiness polling을 소유한다. Bounded wait, error handling, E220 mode management는 별도의 UART/firmware 작업이다.

## Phase 4A-P05B LoRa AUX — 현재 구현

승인된 AUX reset-value 변경이 현재 RTL에 반영되었다. 두 synchronization stage는 모두 LOW로 reset되므로 physical input이 HIGH여도 reset 동안 `UART_STATUS[3]`은 NOT READY를 표시한다. Reset 후에는 변경하지 않은 2FF path가 persistent level을 `HIGH=READY`로 전달한다. Edge detector, pulse stretcher, minimum-high qualifier, post-rising delay는 없다. UART0/UART1 RX synchronizer와 RX state machine은 변경하지 않았으며, 두 production module 모두 여러 input phase의 full-byte focused RX regression을 통과했다. 이 범위의 증거로 backpressure, divisor range, 전체 UART protocol signoff 같은 별도 cleanup 항목을 닫지는 않는다.

## 20. Phase 4A-P07B 현행 UART 계약

P07B 이후에도 UART0/LoRa와 UART1/PC의 public map과 polling-only 역할은
동일하다. UART IRQ는 없고 `UART_CONTROL`은 명시적인 RAZ/WI 예약
register이다.

- TX busy 중 `UART_DATA` write는 `PREADY=0`으로 ACCESS를 유지하고, TX가
  가능해지는 시점에 정확히 한 번 수락한다. 다른 UART register는 TX busy만으로
  stall하지 않는다.
- `TX_READY`는 DATA를 즉시 수락할 수 있음을 뜻한다. 수락 edge에 내려가고 한
  stop-bit interval 완료 edge에 다시 올라오며 추가 idle divisor는 없다.
- TX는 TX FIFO 없이 정확한 8-N-1, LSB-first이다.
- RX FIFO는 각 16 byte이다. 정상 stop bit 확인 후에만 push하며, full에서는 새
  byte를 drop하고 기존 queue를 보존한다.
- Empty `UART_DATA` read는 0을 반환하며 pop/error 부작용이 없다.
- `RX_ERROR`는 framing/overflow combined sticky bit이다. 정상 push/pop으로
  지워지지 않고 `UART_STATUS[2]` W1C로 지운다. 새 error와 W1C가 같은 edge면
  새 error가 우선한다.
- Local decode는 `0x00/0x04/0x08/0x0c`만 허용하며 과거 16-byte mirror는
  제거됐다.

`UART_BAUD`는 `programmed_baud_div`를 노출한다. Reset은 434, 유효 범위는
217..65535이며 0..216 write는 기존 값을 보존한다. TX는 DATA 수락 시, RX는
start 검출 시 각 방향의 active divisor를 capture한다. 따라서 이후 BAUD write는
그 방향의 다음 frame부터 반영된다. RX start 검출과 BAUD write가 같은 edge면
해당 frame은 이전 programmed 값을 사용한다.

P05 CDC/reset 경계는 유지한다. RX는 high/high reset 2FF, LoRa AUX는 low/low
reset 2FF이며 UART0 status에 persistent `HIGH=READY` level로 노출된다.
Hardware가 AUX로 TX를 직접 gate하지 않는다.

Focused evidence는 두 production module, divisor 217/434 TX cycle timing,
RX/FIFO/error corner case, active-divisor isolation, full duplex, reset, 실제
AHB/APB wait propagation, firmware mock MMIO ordering, P05 보존, open/bus
regression, whole-SoC lint/elaboration, 영향받은 RV32I firmware build를 포함한다.
Focused RX_ERROR supplement는 두 독립 production module을 각각 명시적으로
검사했고 `p07b_uart_supplement_02` wrapper exit 0으로 PASS했다. User/Chat이 이
결합 evidence를 Open Verification으로 승인하여 `UART-001..004`는 VERIFIED다.
이는 post-fit/physical serial acceptance가 아니므로 `UART-005`는 PC/LoRa board
evidence 대기로 OPEN이며 `UART-006`과 UART IRQ는 기존 optional/open 및
deferred 상태를 유지한다.
