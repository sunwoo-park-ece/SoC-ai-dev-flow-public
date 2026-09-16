# Baseline SoC HEX Display Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
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

### 3.1 Stale Decimal-Point Constraint

현재 Quartus QSF에는 여전히:

```text
HEX0[7]
HEX1[7]
...
HEX5[7]
```

pin/I/O assignment가 남아 있지만 top-level port는 `[6:0]`뿐이다.

따라서 `HEXx[7]`은 현재 동작 중인 decimal-point feature가 아니다. baseline cleanup에서 stale constraint를 제거하거나, decimal point를 실제 지원하려면 별도 approved contract를 만든 뒤 8-bit output으로 의도적으로 재도입해야 한다.

## 4. Register Map

| Offset | Register | Access | Active bits | 의미 |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | decoder mode용 6개 hex nibble |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` functional | enable / raw mode |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | HEX2..HEX0 raw segment |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | HEX5..HEX3 raw segment |

RTL은 `PADDR[3:2]`만 decode하므로 16-byte마다 register alias가 생긴다. Canonical offset은 위 네 개뿐이며 software는 mirror alias에 의존하면 안 된다.

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
| 31:2 | reserved/storage-only | 현재 display function 없음 |

RTL은 CTRL 전체 32-bit를 저장하지만 실제 출력에 영향을 주는 bit는 0,1뿐이다.

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

따라서 driver 외부 코드가 `HEX_CTRL`을 직접 MMIO write하면 shadow가 stale해질 수 있다. Baseline firmware에서는 `hex_display.c`가 CTRL의 단일 owner가 되어야 한다.

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

관련 board-result 기록은 diagnostic SOF가 physical board에서 문제없이 동작했다고 기록하고 있으며, 해당 범위에서 VGA/HEX/LED board-level 동작 evidence가 있다.

따라서 현재 evidence는 적어도:

- APB HEX access
- VALUE packing
- decoded HEX output
- HEX0..HEX5 physical display path

를 지원한다.

반면 raw mode, disable behavior, decimal point, register alias 등은 별도 directed verification이 필요하다.

## 14. Interrupt / Error

현재 HEX peripheral:

```text
IRQ          none
error status none
PREADY       1
```

이다.

일반 display update만을 위해 PLIC interrupt를 추가할 필요는 없다. 향후 autonomous display engine이나 DMA/event 기능을 추가할 경우에만 별도 interrupt contract를 정의한다.

## 15. Baseline Cleanup Targets

통합 `baseline_cleanup.md`로 넘길 항목:

1. **QSF/RTL width mismatch 해결 — HIGH**
   - RTL은 `HEXx[6:0]`.
   - QSF는 `HEXx[7]`까지 constraint.
   - stale DP pin assignment 제거 또는 정식 DP feature로 재설계.

2. **Raw mode directed verification — HIGH if feature retained**
   - 6개 digit field packing
   - active-low polarity
   - RAW_LOW/HIGH mapping

3. 16-byte register mirroring 제거.

4. CTRL[31:2]를 true reserved/read-zero로 정리하는 방안 검토.

5. reset visible state를 `000000`으로 유지할지 blank로 바꿀지 cleanup 단계에서 의도적으로 결정.

6. firmware CTRL shadow ownership 제약을 문서화하거나 read-modify-write 방식으로 개선.

7. 필요 시 별도 spec 후 추가 가능한 optional feature:
   - decimal point
   - brightness/PWM
   - blink
   - per-digit enable
   - atomic raw update

## 16. Directed Verification

최소 regression:

1. reset -> `000000`
2. VALUE `000000`, `123456`, `ABCDEF`, `FFFFFF`
3. HEX0=LS nibble, HEX5=MS nibble
4. ENABLE=0 -> all `1111111`
5. disable/enable 후 VALUE 보존
6. raw mode HEX0..5 mapping
7. raw blank/all-on
8. RAW register readback
9. CTRL readback
10. decoder/raw mode 전환
11. active display 중 reset
12. software test는 canonical offset 사용
13. pinout 변경 시 board active-low polarity 재검증

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
15. QSF의 `HEXx[7]` assignment는 architectural feature가 아니라 cleanup target이다.
