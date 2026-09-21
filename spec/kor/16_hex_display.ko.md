# Baseline SoC HEX Display Specification — 한국어 Companion

> **상태:** DRAFT — current RTL과 Owner-approved HEX Cleanup target(private Issue #3, 2026-09-21)을 구분한다. Target behavior는 구현 또는 검증 evidence가 아니다.
>
> **정본 언어:** 영어. 이 문서와 `spec/16_hex_display.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`.

## 1. 목적

이 문서는 active FPGA baseline의 6-digit seven-segment HEX display peripheral을 정의한다.

주요 범위는 다음과 같다.

- APB/MMIO register contract
- 6-digit VALUE packing
- hexadecimal decoder mode
- raw segment mode
- active-low segment encoding
- display enable behavior
- reset state
- firmware programming rule
- physical top-level integration
- 현재 verification evidence
- 향후 major feature integration 전 cleanup requirement

현재 블록은 단순한 synchronous APB output peripheral이다. scan engine, PWM brightness control, interrupt, DMA, decimal-point control은 없다.

## 2. Active Architecture

Canonical base address:

```text
HEX_DISPLAY_BASE = 0x4007_0000
APB slot         = PSEL[7]
```

Active RTL:

```text
rtl/peripherals/APB_HEX_display.v
```

구조:

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +-- PSEL[7]
      |
      v
APB_HEX_display                 PCLK = 50 MHz
      |
      +-- VALUE
      +-- CTRL
      +-- RAW_LOW
      +-- RAW_HIGH
      +-- hexadecimal decoder
      |
      +--> HEX0[6:0]
      +--> HEX1[6:0]
      +--> HEX2[6:0]
      +--> HEX3[6:0]
      +--> HEX4[6:0]
      +--> HEX5[6:0]
```

Baseline에서 `PCLK = HCLK = 50 MHz`이므로 이 peripheral 내부 CDC는 없다.

```text
PREADY = 1
IRQ    = none
```

## 3. Physical Display Contract

Active top-level은 각 display에 대해 7-bit만 노출한다.

```verilog
HEX0[6:0]
...
HEX5[6:0]
```

Segment bit order:

```text
[6:0] = {g, f, e, d, c, b, a}
```

Active-low이므로:

```text
0 -> segment ON
1 -> segment OFF
```

Decimal point는 active RTL contract에 포함되지 않는다.

### 3.1 과거 QSF 불일치와 승인된 pin 정책

Owner는 과거 로컬 QSF에 stale `HEXx[7]` assignment가 있었지만 실제 top-level
port는 7-bit였음을 확인했다. 이는 과거 소스에 대한 설명이며 현재 공개
constraint에 bit 7이 존재한다는 뜻이 아니다. Owner는
`fpga/quartus/constraints/de10_lite_pins.tcl`의 `HEX0..HEX5[6:0]` 구성을
검토하고 유지 승인했다. `scripts/wsl/private_quartus.py`는 private QSF를
생성하면서 이 공개 pin Tcl을 `source`한다.

공개 Tcl에 없는 `HEXx[7]` line의 추측성 삭제 patch를 만들거나 DP를
재도입하지 않는다. generated QSF/Pin Report와 source-matched 물리 board
acceptance는 아직 수행되지 않은 별도 evidence다.

## 4. Register Map

| Offset | Register | Access | Active bits | 의미 |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | decoder mode용 6개 hex nibble |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` | enable / raw mode |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | HEX2..HEX0 raw segment |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | HEX5..HEX3 raw segment |

**Current RTL**은 `PADDR[3:2]`만 decode하므로 직접 PSEL을 거는
testbench에서는 16-byte local mirror가 생긴다. production bridge의
slot-7 allowlist는 정확한 네 canonical offset만 전달하고, 비정규 CPU access는
HEX PSEL 없이 차단되어 AHB ERROR 경로를 따른다. Owner-approved cleanup
target은 `PADDR[15:0]` 전체를 네 offset과 정확 비교하여 나머지를
read-zero/write-no-side-effect로 처리하는 것이다. `PREADY=1`, bridge
allowlist/PSEL suppression/AHB ERROR는 유지하고 `PSLVERR`은 추가하지 않는다.
local-slave와 CPU-through-bridge test는 구분한다.

현재 APB에는 `PSTRB`가 없으므로 software contract는 32-bit MMIO access이다.

## 5. `HEX_VALUE` — Decoder Mode

Packing:

```text
VALUE[ 3: 0] -> HEX0
VALUE[ 7: 4] -> HEX1
VALUE[11: 8] -> HEX2
VALUE[15:12] -> HEX3
VALUE[19:16] -> HEX4
VALUE[23:20] -> HEX5
```

예를 들어:

```text
VALUE = 0xABCDEF
```

이면 물리 display는:

```text
HEX5 HEX4 HEX3 HEX2 HEX1 HEX0
 A    B    C    D    E    F
```

로 보인다.

Write `[31:24]`는 버려지고 read에서는 0으로 반환된다.

### 5.1 Hex Decoder

각 nibble은 `0..F` 전체를 지원한다.

| Hex | `{g,f,e,d,c,b,a}` |
|---:|---|
| `0` | `1000000` |
| `1` | `1111001` |
| `2` | `0100100` |
| `3` | `0110000` |
| `4` | `0011001` |
| `5` | `0010010` |
| `6` | `0000010` |
| `7` | `1111000` |
| `8` | `0000000` |
| `9` | `0010000` |
| `A` | `0001000` |
| `B` | `0000011` |
| `C` | `1000110` |
| `D` | `0100001` |
| `E` | `0000110` |
| `F` | `0001110` |

## 6. `HEX_CTRL`

| Bit | 이름 | 의미 |
|---:|---|---|
| 0 | `ENABLE` | `1`: display 출력, `0`: 6개 digit 모두 blank |
| 1 | `RAW_MODE` | `0`: decoder mode, `1`: raw segment mode |
| 31:2 | Reserved | Owner-approved RAZ/WI: 예약 bit는 write 무시·항상 0 read, 같은 valid write의 `[1:0]`은 정상 반영 |

**Current RTL**은 CTRL 전체 32-bit를 저장하지만 실제 출력에는 bit 0,1만
영향을 준다. 이는 구현 gap이다. Cleanup target은 valid write에서
`PWDATA[1:0]`만 저장하고 `{30'b0, CTRL[1:0]}`을 read한다. 예약 bit 값은
write-ignored이지만 같은 valid write의 기능 bit `[1:0]`은 정상 반영된다.
예약 bit 값은 state/output/readback을 바꾸지 않는다.

### 6.1 Disable

`ENABLE=0`이면 모든 digit은:

```text
7'b1111111
```

로 강제되어 blank가 된다.

Disable은 VALUE/RAW register나 RAW_MODE를 clear하지 않는다. 다시 enable하면 저장되어 있던 mode/data가 복구된다.

## 7. Raw Segment Mode

`RAW_MODE=1`일 때 hexadecimal decoder 대신 raw register가 직접 출력된다.

### `HEX_RAW_LOW`

```text
[ 6: 0] -> HEX0
[13: 7] -> HEX1
[20:14] -> HEX2
```

### `HEX_RAW_HIGH`

```text
[ 6: 0] -> HEX3
[13: 7] -> HEX4
[20:14] -> HEX5
```

각 7-bit field의 order는 동일하게:

```text
{g,f,e,d,c,b,a}
```

이다.

예:

```text
1111111 -> blank
0000000 -> 모든 segment ON
1000000 -> digit 0 pattern
```

Raw mode는 decimal point, brightness, blink, per-digit enable을 제공하지 않는다.

## 8. Reset Behavior

Reset 시:

```text
VALUE     = 0x000000
CTRL      = 0x00000001
RAW_LOW   = blank x3
RAW_HIGH  = blank x3
```

따라서 functional reset state는:

```text
ENABLE   = 1
RAW_MODE = 0
VALUE    = 000000
```

이다.

즉 reset 이후 의도된 visible state는 blank가 아니라 **`000000`**이다.

## 9. Update Timing

Register write는:

```text
PSEL && PENABLE && PWRITE
```

인 PCLK edge에서 반영된다.

HEX output은 register의 combinational decode/mux 결과다.

```text
APB write
  -> register
  -> decode/mux
  -> HEX0..HEX5
```

6개 digit을 multiplex scan하는 별도 FSM은 없다.

Decoder mode VALUE는 하나의 24-bit register라 한 write로 6개 digit이 함께 갱신된다.

Raw mode는 RAW_LOW/RAW_HIGH 두 번의 write가 필요하므로 두 write 사이에 old/new pattern이 섞여 보일 수 있다. 원자성이 필요하면 잠시 display를 disable하고 두 raw register를 쓴 후 enable하는 것이 안전하다.

## 10. Firmware Contract

Active driver:

```text
firmware/drivers/hex_display.c
firmware/include/hex_display.h
```

주요 API:

```text
hex_display_enable()
hex_display_set_raw_mode()
hex_display_write_value()
hex_display_write_raw()
hex_display_write_monitor()
hex_display_read_value()
hex_display_read_ctrl()
```

Decoder mode 권장 sequence:

```c
hex_display_enable(1);
hex_display_set_raw_mode(0);
hex_display_write_value(value & 0x00ffffffu);
```

Raw mode 권장 sequence:

```c
hex_display_write_raw(raw_low, raw_high);
hex_display_set_raw_mode(1);
hex_display_enable(1);
```

### 10.1 CTRL Shadow

현재 firmware driver는:

```c
static uint32_t hex_ctrl_shadow = HEX_CTRL_ENABLE;
```

를 유지한다.

Owner-approved target에서 `hex_display.c`는 `HEX_CTRL`의 단일 software
writer다. application/ISR direct write와 무단 concurrent writer는 금지한다.
Shadow와 CTRL write는 `[1:0]`만 (`& 0x3`) 유지하고 normal helper는 hardware
RMW가 아닌 Shadow 방식을 유지한다. 정상 system reset과 firmware
initialization 후 hardware CTRL/Shadow는 `0x1`이다.

HEX-only reset 또는 out-of-band change가 의심되면 **다음 CTRL update 전**
hardware CTRL을 읽고 `& 0x3`으로 Shadow를 명시적으로 resynchronize하는
절차/API를 사용한다. 자동 reset detection은 없으며 resynchronization이
driver 외 direct write를 허용하지 않는다. API 이름/구현은 아직 존재한다고
주장하지 않으며 future ISR/multi-context는 driver access를 직렬화한다.

## 11. Monitor Packing

`hex_display_write_monitor()`의 firmware convention:

```text
HEX5 = mode
HEX4 = state
HEX3 = retry_count
HEX2 = err
HEX1 = rx_seq
HEX0 = tx_seq
```

즉:

```text
[23:20] mode
[19:16] state
[15:12] retry
[11: 8] error
[ 7: 4] rx sequence
[ 3: 0] tx sequence
```

이다.

이건 firmware convention일 뿐 RTL에 별도 monitor state가 있는 것은 아니다.

## 12. Readback Limitation

VALUE/CTRL/RAW register는 모두 read 가능하다.

하지만 register readback 성공은 다음을 증명하지 않는다.

```text
physical segment illumination
pin continuity
board polarity
stale DP constraint 동작
```

실제 물리 표시 검증에는 board observation 또는 pin-level measurement가 필요하다.

## 13. Validation Evidence

현재 `display_smoke` firmware는 decoded HEX path를 실제로 사용한다.

```text
startup: b00701
scan:    000000 -> 111111 -> ... -> FFFFFF
```

또 VALUE register readback mismatch를 별도 error code로 확인한다.

역사적 board-result 진술은 diagnostic 동작 성공을 기록하지만, public
snapshot에는 원래 board-result provenance가 충분하지 않다. 따라서 이를
fresh, source-matched HEX Cleanup board acceptance로 취급할 수 없다.

이 역사적 evidence는 다음을 지원한다:

- APB HEX access
- VALUE packing
- decoded HEX output
- historical decoded-path physical operation

를 지원한다.

raw mode, disable behavior, decimal point, reserved-bit RAZ/WI, local mirror
rejection, generated pin assignment는 별도 directed verification이 필요하다.

## 14. Interrupt / Error

현재 HEX peripheral:

```text
IRQ          none
error status none
PREADY       1
```

이다.

일반 display update만을 위해 PLIC interrupt를 추가할 필요는 없다. 향후 autonomous display engine이나 DMA/event 기능을 추가할 경우에만 별도 interrupt contract를 정의한다.

## 15. Owner-Approved Cleanup Scope (Issue #3, 2026-09-21)

1. **HEX-001:** 승인된 공개 `[6:0]` pin Tcl을 유지한다. 가상의 공개 pin
   삭제 patch를 만들지 않으며 generated-QSF/Pin Report와 current board
   evidence는 미검증이다.
2. **HEX-002:** RAW mode를 유지하고 여섯 field/mapping/active-low,
   masking/readback, disable/enable, reset을 독립 검증한다.
3. **HEX-003:** CTRL `[31:2]`은 RAZ/WI, reset visible state는 decoded
   `000000`으로 유지하며 explicit initialization/resynchronization을 가진
   sole-owner firmware Shadow를 사용한다. routine hardware RMW는 사용하지
   않는다.
4. **Local decode / APB-005:** full-offset exact check로 내부 16-byte
   mirror를 제거하되 production bridge 동작은 유지한다.
5. **HEX-004:** DP/PWM/blink/per-digit/atomic-RAW 추가는 DEFERRED다.

이는 Owner-approved requirement이며 구현 또는 verification 완료 상태가 아니다.

## 16. Directed Verification

최소 regression:

1. reset CTRL=`0x1`, VALUE=`0`, RAW blank 및 decoded `000000`
2. VALUE `000000`, `123456`, `ABCDEF`, `FFFFFF`
3. HEX0=LS nibble, HEX5=MS nibble
4. ENABLE=0 -> all `1111111`
5. CTRL `[31:2]` RAZ/WI와 의도하지 않은 output 변화 없음
6. 모든 RAW field의 mapping/polarity/packing/masking/readback/blank/all-on,
   disable/enable 보존
7. decoder/RAW 전환과 active operation 중 reset
8. HEX-alone 비정규/비정렬/mirror offset의 read-zero/write-no-side-effect
9. CPU-through-production-bridge 비정규 요청의 PSEL suppression/AHB ERROR
10. Shadow initialization, HEX-only reset 뒤 explicit resync, ENABLE/RAW_MODE 보존
11. independent expected-model, failing-case runner, 실행/미실행 evidence 기록
12. 승인 후 generated-QSF/Pin Report와 source-matched FPGA board 관찰;
    static Tcl review는 physical PASS가 아님

## 17. Baseline Invariants

향후 approved spec이 대체하기 전까지:

1. `HEX_DISPLAY_BASE = 0x4007_0000`.
2. APB `PSEL[7]` peripheral이다.
3. `PREADY=1`.
4. 6개의 independent 7-segment digit을 구동한다.
5. active RTL output width는 `[6:0]`이다.
6. segment order는 active-low `{g,f,e,d,c,b,a}`이다.
7. VALUE LSB nibble은 HEX0, MS nibble은 HEX5다.
8. decoder는 `0..F`를 지원한다.
9. CTRL[0]=enable.
10. CTRL[1]=raw mode.
11. RAW_LOW=HEX0..2, RAW_HIGH=HEX3..5.
12. reset은 enabled decoder mode + `000000`이다.
13. decimal-point control은 active RTL에 없다.
14. interrupt source는 없다.
15. 과거 local QSF의 `HEXx[7]` assignment는 architectural feature가 아니다.
    승인된 공개 `[6:0]` pin configuration은 유지한다.
16. exact local-offset decoding과 explicit firmware Shadow resynchronization은
    RTL/FW verification이 구현을 입증할 때까지 cleanup target이다.
