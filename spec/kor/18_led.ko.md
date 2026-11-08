# SoC LED Output Peripheral Specification — 한국어 Companion

> **P04 상태 주석(2026-09-15):** 슬롯 9 APB_LED가 LEDR[9:0] 전체를 소유하며 LEDR[9] 리셋 표시 소유권은 제거되었다. 공개 검증과 사용자 실행 Quartus 피팅이 통과했다. `BOARDIO-004`는 명시적 walking/all-on/off 보드 시험이 없어 OPEN이다. 아래 ‘미구현’ 문구는 P04 이전 이력이다.

> **상태:** ACTIVE P04 IMPLEMENTATION / BOARD ACCEPTANCE OPEN.
>
> **정본 언어:** 영어. 이 문서와 `spec/18_led.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `gpio.md`, `board_io_architecture.md`.

## 현행 계약과 source/evidence 경계

APB_LED는 0x4009_0000 / PSEL[9]의 구현된 P04이며 LEDR[9:0] 전체를 소유한다. +0x00 LED_DATA는 10-bit latch, 상위 bit는 write-ignore/read-zero, reset은 모든 출력을 끄며 readback은 illumination이 아닌 latch다. 과거 LEDR[9] reset-indicator driver는 제거됐다. PREADY=1이며 IRQ/PWM/blink hardware는 없다. Direct local invalid offset은 PSLVERR 없는 RAZ/WI이고 CPU bridge는 invalid address/size/alignment를 PSEL 전에 2-cycle ERROR로 거부한다. BOARDIO-004는 명시적 physical walking/all-on/off test가 남아 OPEN이며 FW-006 map 수용과 digital test가 이 board 결과를 대신하지 않는다.

추적: [APB_LED.v](../../rtl/peripherals/APB_LED.v); [AMBA_SoC_TOP.v](../../rtl/soc/AMBA_SoC_TOP.v); [led.c](../../firmware/drivers/led.c); [tb_p04_boardio.sv](../../verification/directed/bus/tb_p04_boardio.sv).

## 1. 목적

이 문서는 DE10-Lite의 10개 red LED를 위한 전용 APB output peripheral을 정의한다.

목표 구조는 legacy `APB_GPIO`에서 LED 역할을 분리하고 다음을 제공한다.

- dedicated 10-bit output latch
- `LEDR[9:0]` 직접 제어
- deterministic reset
- output-latch readback
- 최소 APB register interface

GPIO direction, PWM, blink timer, interrupt, DMA, hardware pattern generation은 제공하지 않는다.

## 2. 주소 및 APB slot

현행 P04 production top은 PSEL[9], base `0x4009_0000`에 APB_LED를 instantiate하며 LEDR[9:0] 전체를 연결한다. PSEL[8]은 SW, PSEL[1]은 true GPIO이고 10..15는 reserved/error다. 과거 GPIO-to-LED/reset-indicator 구성은 역사적이다. 주소 권위는 memory map이며 새 배정은 없다.

## 3. 권장 module interface

```text
module APB_LED

Inputs:
  PCLK
  PRESETn
  PADDR[31:0]
  PWRITE
  PSEL
  PENABLE
  PWDATA[31:0]

Outputs:
  PRDATA[31:0]
  PREADY
  LEDR[9:0]
```

구조:

```text
CPU -> APB_LED -> LEDR[9:0]
```

전체 peripheral은 PCLK domain에서 동작한다.

## 4. Physical Ownership

APB_LED는 LEDR[9:0]을 일대일 소유한다. 과거 `LEDR[9] = ~HRESETn` assignment는 더 이상 active가 아니다. 향후 reset/debug indicator는 별도 승인 resource ownership이 필요하며 LED_DATA bit를 임의로 사용하면 안 된다.

## 5. Canonical Register Map

| Offset | Absolute address | Register | Access | Reset | 의미 |
|---:|---:|---|---|---:|---|
| `0x00` | `0x4009_0000` | `LED_DATA` | R/W | `0x000` | 10-bit output latch |

`[9:0]`만 구현한다. Read `[31:10]`은 0, write `[31:10]`은 ignored이다.

Exact offset decode를 사용하고 legacy register mirroring은 만들지 않는다.

이전 target 초안은 unknown offset에 zero/no-effect를 제안했다. 승인된 A2와 active P04 APB_LED가 이를 대체하여 CPU bridge가 비정규 offset/size/alignment를 LED PSEL 전에 2-cycle AHB ERROR로 거부한다. Direct slave에는 PSLVERR가 없으며 invalid local offset은 RAZ/WI다.

## 6. Write Semantics

```text
led_reg[9:0] <- PWDATA[9:0]
LEDR[9:0]    = led_reg[9:0]
```

Dedicated output이므로 direction register는 없다.

일부 bit만 변경하려면 software가 원하는 10-bit 값을 계산하거나 하나의 shadow를 유지한다.

## 7. Read Semantics

```text
PRDATA[9:0]   = led_reg[9:0]
PRDATA[31:10] = 0
```

Readback은 APB/output latch 상태이며 physical LED 점등 자체의 feedback은 아니다.

## 8. Reset Behavior

```text
PRESETn = 0
-> led_reg = 0x000
-> LEDR[9:0] = 0x000
```

Reset 중과 reset 직후 10개 LED는 모두 off이다.

## 9. APB Behavior

```text
PREADY = 1
```

Naturally aligned 32-bit MMIO만 normative하다.

## 10. Firmware Contract

최소 API:

```c
void led_write(uint32_t value);
uint32_t led_read(void);
```

사용 값은 `value & 0x3FF`로 제한한다.

한 LED driver가 register ownership을 갖고 application에서 direct MMIO와 별도 shadow를 혼용하지 않는 것을 권장한다.

Interrupt나 completion polling은 필요 없다.

## 11. GPIO / SW와의 관계

현행 P04 구조:

```text
SW[9:0]   -> APB_SW    @ PSEL[8]
LEDR[9:0] <- APB_LED   @ PSEL[9]
GPIO_IO[] <-> APB_GPIO @ PSEL[1]
```

기존 GPIO slot은 **유지**하며 true bidirectional GPIO로 재설계한다. LED slot으로 재사용하지 않는다.

Legacy의 mixed SW/LED pseudo-GPIO, 10-bit logical/9-bit physical LED mismatch, `LEDR[9]` 별도 ownership은 모두 제거한다.

## 12. Interrupt Behavior

LED peripheral에는 IRQ가 없다. Asynchronous internal event source가 없으므로 PLIC source를 할당하지 않는다.

## 13. Verification Requirements

최소 directed verification:

1. reset `LED_DATA=0`
2. reset `LEDR[9:0]=0`
3. bit0~9 개별 동작
4. walking-one / walking-zero
5. `0x000`, `0x3FF`, `0x155`, `0x2AA`
6. latch readback
7. upper read zero / upper write ignored
8. exact offset decode
9. `PREADY=1`
10. `PSEL[9]` top-level mapping
11. direct `led_reg -> LEDR` mapping
12. independent `LEDR[9]` driver가 없음
13. `APB_GPIO`가 더 이상 board LED를 구동하지 않음

Board에서는 10개 LED 전체를 육안 검증한다.

## 14. 남은 결정

주소/slot/16-bit PSEL routing/A2 CPU validation은 이미 구현됐다. BOARDIO-004 physical pattern 수용은 OPEN이며 향후 optional LED feature는 별도 spec 권위가 필요하다. 새 IRQ/PWM/blink를 정의하지 않는다.

## 15. Current Invariants

1. `LED_BASE = 0x4009_0000`, `PSEL[9]`이다.
2. 현행 APB는 16-slot 구조다.
3. `APB_LED`가 `LEDR[9:0]` 전체를 소유한다.
4. `LED_DATA`가 유일한 architectural output latch이다.
5. `[9:0]`만 구현한다.
6. reset에서 모두 off이다.
7. readback은 latch 상태다.
8. direction register가 없다.
9. IRQ가 없다.
10. 현행 P04에서 과거 `LEDR[9] = ~HRESETn` assignment는 제거됐다.
11. legacy GPIO slot은 유지하지만 board LED를 더 이상 소유하지 않는다.
12. 이 peripheral은 general-purpose GPIO가 아니다.
