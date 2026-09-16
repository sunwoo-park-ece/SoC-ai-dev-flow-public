# Baseline SoC HEX Display Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `hex_display.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`.

## 1. Purpose

This document defines the software-visible six-digit seven-segment HEX display peripheral in the active FPGA baseline.

It specifies:

- the APB/MMIO register contract,
- six-digit value packing,
- hexadecimal decoder mode,
- raw segment mode,
- active-low segment encoding,
- display-enable behavior,
- reset state,
- firmware programming rules,
- physical top-level integration,
- current verification evidence,
- cleanup requirements before major feature integration.

The block is a small synchronous APB output peripheral. It does not contain a scan engine, PWM brightness control, interrupt source, DMA interface, or decimal-point control.

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

Top-level integration:

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
      +-- VALUE register
      +-- CTRL register
      +-- RAW_LOW register
      +-- RAW_HIGH register
      +-- hexadecimal decoder
      |
      +--> HEX0[6:0]
      +--> HEX1[6:0]
      +--> HEX2[6:0]
      +--> HEX3[6:0]
      +--> HEX4[6:0]
      +--> HEX5[6:0]
```

The block operates entirely in the APB `PCLK` domain. In the baseline, `PCLK = HCLK = 50 MHz`, so no CDC exists inside this peripheral.

The APB slave permanently asserts:

```text
PREADY = 1
```

and has no interrupt output.

## 3. Physical Display Contract

The active top-level exposes:

```verilog
output wire [6:0] HEX0;
output wire [6:0] HEX1;
output wire [6:0] HEX2;
output wire [6:0] HEX3;
output wire [6:0] HEX4;
output wire [6:0] HEX5;
```

The seven bits use active-low segment encoding:

```text
[6:0] = {g, f, e, d, c, b, a}
```

Therefore:

```text
segment bit = 0 -> segment illuminated
segment bit = 1 -> segment off
```

The peripheral does **not** expose a decimal-point bit.

### 3.1 Stale Decimal-Point Constraints

The current Quartus QSF still contains pin and I/O-standard assignments for:

```text
HEX0[7]
HEX1[7]
...
HEX5[7]
```

while the active RTL top exposes only `[6:0]`.

Those bit-7 assignments shall not be interpreted as an active decimal-point feature. They are stale board constraints and shall be removed or deliberately reintroduced through an approved eight-bit display contract during baseline cleanup.

## 4. Register Map

The canonical software-visible register offsets are:

| Offset | Register | Access | Active bits | Description |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | Six hexadecimal nibbles for decoder mode |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` functional | Display enable and raw-mode control |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | Raw segment patterns for HEX2..HEX0 |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | Raw segment patterns for HEX5..HEX3 |

The RTL decodes only:

```verilog
PADDR[3:2]
```

so the four-register bank is physically mirrored every 16 bytes throughout the broader APB slot. Only the offsets above are canonical. Software shall not depend on mirrored aliases.

The current APB subsystem has no `PSTRB`, so these registers are defined as 32-bit MMIO accesses even though only subsets of each register are functional.

## 5. `HEX_VALUE` — Decoder-Mode Data

`HEX_VALUE[23:0]` contains six independent hexadecimal nibbles:

```text
VALUE[ 3: 0] -> HEX0
VALUE[ 7: 4] -> HEX1
VALUE[11: 8] -> HEX2
VALUE[15:12] -> HEX3
VALUE[19:16] -> HEX4
VALUE[23:20] -> HEX5
```

Thus a software value written as:

```text
0xABCDEF
```

appears physically as:

```text
HEX5 HEX4 HEX3 HEX2 HEX1 HEX0
 A    B    C    D    E    F
```

when decoder mode is selected and the display is enabled.

Bits `[31:24]` of a write are discarded. Reads return them as zero.

### 5.1 Hexadecimal Decoder

Each 4-bit nibble is converted to the active-low seven-segment pattern below.

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

The decoder therefore supports the full hexadecimal range `0..F` on every digit.

## 6. `HEX_CTRL`

Functional bits are:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `ENABLE` | `1`: drive selected display pattern, `0`: blank all six digits |
| 1 | `RAW_MODE` | `0`: hexadecimal decoder mode, `1`: raw segment mode |
| 31:2 | reserved/storage-only | retained by RTL but have no current display function |

The RTL stores the entire 32-bit `CTRL` write value, but only bits 0 and 1 affect outputs.

Software shall write zero to reserved bits unless preserving an already-read value intentionally.

### 6.1 Display Disable

When:

```text
ENABLE = 0
```

all digits are forced to:

```text
7'b1111111
```

which is blank because the segments are active-low.

Disabling the display does **not** clear:

- `VALUE`,
- `RAW_LOW`,
- `RAW_HIGH`,
- `RAW_MODE`.

Re-enabling the display therefore restores the pattern selected by the stored mode/data registers.

## 7. Raw Segment Mode

When:

```text
RAW_MODE = 1
```

`VALUE` and the hexadecimal decoder do not determine the physical segment outputs. The raw 21-bit registers are used directly.

### 7.1 `HEX_RAW_LOW`

```text
RAW_LOW[ 6: 0] -> HEX0[6:0]
RAW_LOW[13: 7] -> HEX1[6:0]
RAW_LOW[20:14] -> HEX2[6:0]
```

### 7.2 `HEX_RAW_HIGH`

```text
RAW_HIGH[ 6: 0] -> HEX3[6:0]
RAW_HIGH[13: 7] -> HEX4[6:0]
RAW_HIGH[20:14] -> HEX5[6:0]
```

Each 7-bit field uses the same active-low order:

```text
{g, f, e, d, c, b, a}
```

Examples:

```text
7'b1111111 -> blank digit
7'b0000000 -> all seven segments on
7'b1000000 -> digit 0 pattern
```

Bits `[31:21]` of RAW-register writes are discarded, and reads return those upper bits as zero.

Raw mode provides direct seven-segment control only. It does not provide decimal-point, brightness, blink, or per-digit enable registers.

## 8. Reset Behavior

On `PRESETn = 0`, the RTL initializes:

```text
VALUE     = 0x000000
CTRL      = 0x00000001
RAW_LOW   = {3{7'b1111111}}
RAW_HIGH  = {3{7'b1111111}}
```

Therefore the post-reset functional state is:

```text
ENABLE   = 1
RAW_MODE = 0
VALUE    = 000000
```

and, once the system is out of reset and the display outputs are active, the intended visible decoded state is:

```text
000000
```

The reset state is **not blank** in decoder mode.

The raw registers themselves reset to blank patterns, but they are inactive until `RAW_MODE=1`.

## 9. Update Timing

Register writes occur on the APB/PCLK edge satisfying:

```text
PSEL && PENABLE && PWRITE
```

The physical HEX outputs are combinational functions of the stored registers.

There is no display scan/multiplex FSM because the six board digits are independently driven by dedicated segment outputs.

Conceptually:

```text
APB write edge
    |
    v
VALUE / CTRL / RAW register
    |
    v
combinational decode/mux
    |
    v
HEX0..HEX5
```

A multi-register raw-mode update is not atomic. For example, writing `RAW_LOW` and then `RAW_HIGH` can temporarily present a mixed old/new pattern between the two APB writes. Software shall not assume six-digit atomic update in raw mode.

Decoder-mode `VALUE` update is a single 24-bit register write and therefore updates all six decoded digits from one APB write.

## 10. Firmware Contract

The active driver is:

```text
firmware/drivers/hex_display.c
firmware/include/hex_display.h
```

The driver provides:

```text
hex_display_enable()
hex_display_set_raw_mode()
hex_display_write_value()
hex_display_write_raw()
hex_display_write_monitor()
hex_display_read_value()
hex_display_read_ctrl()
```

### 10.1 Decoder-Mode Sequence

Recommended sequence:

```c
hex_display_enable(1);
hex_display_set_raw_mode(0);
hex_display_write_value(value & 0x00ffffffu);
```

### 10.2 Raw-Mode Sequence

Recommended sequence:

```c
hex_display_write_raw(raw_low, raw_high);
hex_display_set_raw_mode(1);
hex_display_enable(1);
```

If visual atomicity matters, software may temporarily disable the display while updating both raw registers:

```text
ENABLE=0
write RAW_LOW
write RAW_HIGH
RAW_MODE=1
ENABLE=1
```

### 10.3 Driver CTRL Shadow

The active firmware driver keeps a software-side:

```c
static uint32_t hex_ctrl_shadow = HEX_CTRL_ENABLE;
```

and uses it to preserve `ENABLE` and `RAW_MODE` across helper calls.

This works only if the driver is the sole owner of `HEX_CTRL`. If other firmware writes `HEX_CTRL` directly, the software shadow may become stale and a later driver call may overwrite that external state.

Baseline firmware shall therefore treat `hex_display.c` as the single owner of `HEX_CTRL`, or explicitly resynchronize the shadow before mixing direct MMIO writes with driver calls.

## 11. Monitor Packing Used by Baseline Firmware

`hex_display_write_monitor()` packs six 4-bit software fields into the display:

```text
HEX5 = mode
HEX4 = state
HEX3 = retry_count
HEX2 = err
HEX1 = rx_seq
HEX0 = tx_seq
```

Equivalent 24-bit layout:

```text
[23:20] mode
[19:16] state
[15:12] retry_count
[11: 8] err
[ 7: 4] rx_seq
[ 3: 0] tx_seq
```

This is a firmware convention, not additional RTL state.

## 12. Readback Semantics

All four registers are readable.

Register readback proves only the APB/register state. It does not independently prove:

- physical pin continuity,
- board segment polarity,
- a particular LED segment actually illuminating,
- the stale decimal-point constraints functioning.

Physical display correctness requires board observation or pin-level measurement.

## 13. Validation Evidence

The current `display_smoke` diagnostic explicitly exercises the decoded HEX path.

Its firmware:

1. enables the HEX display,
2. selects decoder mode,
3. writes startup marker `b00701`,
4. cycles the six digits through `000000`, `111111`, ... `FFFFFF`,
5. reads back the `HEX_VALUE` register and emits an error marker on mismatch.

The associated board-result record states that the delivered diagnostic SOF operated without problems on the physical board and establishes board-level VGA/HEX/LED operation for that diagnostic firmware.

This evidence supports:

- APB access to the active HEX peripheral,
- 24-bit decoder-mode value packing,
- physical HEX0..HEX5 output operation in the diagnostic path.

It does **not** independently prove:

- raw segment mode,
- every raw bit pattern,
- display-disable behavior,
- decimal-point behavior,
- reserved-bit behavior,
- mirrored aliases.

Those items require separate directed verification if they become important to a future milestone.

## 14. Interrupt and Error Behavior

The active HEX display peripheral has:

```text
IRQ output   = none
error status = none
PREADY       = 1
```

All supported APB transactions complete without peripheral-generated error reporting.

The display is therefore a polling/configuration-style output peripheral and shall not be assigned a PLIC source in the baseline.

There is no reason to add an interrupt solely for ordinary display updates unless a future architecture adds autonomous scan/DMA/event behavior that requires one.

## 15. Baseline Cleanup Targets

The following items shall be carried into the consolidated `baseline_cleanup.md` pass.

### 15.1 High / correctness and contract hygiene

1. **Resolve QSF/RTL display-width mismatch.**
   - Active RTL exposes `HEXx[6:0]`.
   - QSF still constrains `HEXx[7]`.
   - Remove stale decimal-point assignments or deliberately add DP control through a new approved contract.

2. **Add directed raw-mode verification if raw mode remains a supported feature.**
   - Verify all six 7-bit field mappings.
   - Verify active-low polarity.
   - Verify RAW_LOW/RAW_HIGH packing.

### 15.2 Medium / interface quality

3. **Remove noncanonical 16-byte register mirroring** when the peripheral decode is hardened.

4. **Define reserved CTRL bits as true reserved/read-zero** rather than storing irrelevant values, unless future features intentionally use them.

5. **Decide whether post-reset visible state should be `000000` or blank.**
   - Preserve baseline behavior unless intentionally changed by an approved cleanup decision.

6. **Document or eliminate the firmware CTRL shadow ownership constraint.**
   - A register read-modify-write helper is preferable if multiple software components may control the display.

### 15.3 Optional future enhancement

7. If desired, specify separate features before implementation for:
   - decimal points,
   - brightness/PWM,
   - blink,
   - per-digit enable,
   - atomic raw six-digit update.

These are not baseline requirements.

## 16. Directed Verification Requirements

A complete peripheral regression should include at least:

1. reset -> decoded `000000`,
2. VALUE patterns `000000`, `123456`, `ABCDEF`, `FFFFFF`,
3. verify HEX0 receives least-significant nibble and HEX5 the most-significant nibble,
4. `ENABLE=0` -> all six outputs `1111111`,
5. disable/enable preserves stored VALUE,
6. raw-mode mapping for HEX0..HEX5,
7. raw blank/all-on patterns,
8. RAW_LOW and RAW_HIGH readback,
9. CTRL readback,
10. decoder/raw mode switching without register corruption,
11. reset during active display operation,
12. canonical offsets only in software-facing tests,
13. board check of physical active-low segment polarity if the pinout is changed.

## 17. Baseline Invariants

Until superseded by an approved future specification:

1. `HEX_DISPLAY_BASE = 0x4007_0000`.
2. The peripheral is APB `PSEL[7]`.
3. `PREADY=1`.
4. There are six independently driven seven-segment digits.
5. Active physical RTL outputs are `HEX0..HEX5[6:0]` only.
6. Segment encoding is active-low `{g,f,e,d,c,b,a}`.
7. `VALUE[3:0]` drives HEX0 and `VALUE[23:20]` drives HEX5 in decoder mode.
8. Decoder mode supports hexadecimal `0..F`.
9. `CTRL[0]` is display enable.
10. `CTRL[1]` selects raw mode.
11. `RAW_LOW` owns HEX0..HEX2; `RAW_HIGH` owns HEX3..HEX5.
12. Reset selects enabled decoder mode with VALUE=`000000`.
13. No decimal-point control is active in RTL.
14. No interrupt source exists.
15. QSF `HEXx[7]` assignments are not an architectural feature and remain cleanup targets.
