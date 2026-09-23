# Baseline SoC HEX Display Specification

> **Status:** VERIFIED / ACTIVE BASELINE — Issue #3 HEX cleanup target is implemented in RTL/firmware and verified through directed simulation, Quartus build, and physical FPGA board acceptance (2026-09-24).
>
> **Canonical language:** English. If this file and `spec/kor/16_hex_display.ko.md` conflict, this file is authoritative.
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

### 3.1 Historical QSF discrepancy and approved pin policy

The Owner confirms that a **historical local QSF** contained stale `HEXx[7]`
assignments although the actual top-level ports are seven bits. This is a
historical source, not a claim that the current public constraints contain bit
7. The Owner reviewed and approved retaining the current public
`fpga/quartus/constraints/de10_lite_pins.tcl` configuration, which assigns
only `HEX0..HEX5[6:0]`. `scripts/wsl/private_quartus.py` generates the
private QSF and includes that public pin Tcl with a `source` statement.

Do not create a speculative deletion patch for absent public `HEXx[7]`
lines or reintroduce DP support. In P10-HEX S6, the final Quartus Fitter Pin
report verified 42 unique pins `HEX0..HEX5[0:6]` with zero `HEX[7]` pins, and
physical board acceptance confirmed correct six-digit operation
(`reports/evidence/p10-hex-s6/summary.md`, `P10-HEX-S6-EV-01`).

## 4. Register Map

The canonical software-visible register offsets are:

| Offset | Register | Access | Active bits | Description |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | Six hexadecimal nibbles for decoder mode |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` | Display enable and raw-mode control |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | Raw segment patterns for HEX2..HEX0 |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | Raw segment patterns for HEX5..HEX3 |

The active RTL (`APB_HEX_display.v`) implements exact offset decode on the
full 16-bit slot offset:

```verilog
PADDR[15:0]
```

The slave compares `PADDR[15:0]` with exactly `16'h0000`, `16'h0004`,
`16'h0008`, and `16'h000C`. Every other local offset, including unaligned and
previously mirrored offsets, reads zero and has no write side effect,
without altering registers or physical HEX outputs. `PREADY=1` is preserved
and no `PSLVERR` port is added.

At the SoC interconnect level, the AHB/APB bridge's slot-7 allowlist
forwards only these four exact canonical offsets. Noncanonical CPU accesses
are blocked without asserting HEX `PSEL` and follow the bridge's 2-cycle AHB
ERROR path (`HRESP=01`). Both the local-slave exact decode and the
CPU-through-bridge ERROR paths are verified (S2, S5).

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
| 31:2 | Reserved | Owner-approved RAZ/WI: those bits are write-ignored and always read zero; a valid write still updates `[1:0]` |

The active RTL stores only the 2-bit functional field `ctrl_reg[1:0]`.
Reserved bits `[31:2]` are RAZ/WI (Read-As-Zero / Write-Ignored): writes to
`HEX_CTRL` latch only `PWDATA[1:0]` while bits `[31:2]` are ignored; reads
return `{30'b0, ctrl_reg[1:0]}`. A write containing nonzero values in
`[31:2]` updates functional bits `[1:0]` normally without corrupting stored
state or outputs. Firmware driver writes enforce `& HEX_CTRL_MASK` (`0x3`).

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

The firmware driver (`hex_display.c`) is the sole software writer of
`HEX_CTRL`; direct application/ISR writes are prohibited. The driver
maintains the Shadow architecture rather than routine hardware
read-modify-write. Shadow and hardware writes strictly enforce
`& HEX_CTRL_MASK` (`0x3`).

The initialization and resynchronization APIs are implemented:

```c
/* firmware/include/hex_display.h */
void hex_display_init(void);
void hex_display_resync(void);
```

- `hex_display_init()`: Establishes boot Shadow (`0x1`) and writes hardware `CTRL = 0x1`.
- `hex_display_resync()`: If the HEX hardware alone resets during execution,
  or an out-of-band change is suspected, the caller invokes `hex_display_resync()`
  before the next CTRL update. It reads hardware `HEX_CTRL`, masks `& HEX_CTRL_MASK`,
  and updates `hex_ctrl_shadow`.

This does not imply automatic reset detection or authorize out-of-driver
writes. Any future multi-context/ISR usage must serialize driver access.

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

All four canonical registers are readable. VALUE `[31:24]` and RAW
`[31:21]` read zero. The target CTRL `[31:2]` and invalid local offsets read
zero.

Register readback proves only the APB/register state. It does not independently prove:

- physical pin continuity,
- board segment polarity,
- a particular LED segment actually illuminating,
- generated pin assignments or the stale historical constraints functioning.

Physical display correctness requires board observation or pin-level measurement.

## 13. Validation Evidence

The HEX display peripheral has a complete multi-tier verification and acceptance chain across S0 through S6:

1. **S0 Standalone APB Baseline (`tb_hex_s0_apb.sv`):** 71 checks verifying reset values, PREADY, canonical register access, ACCESS-only writes, ENABLE blanking/restoration, and active-low decoder mapping with intentional fault-injection rejection.
2. **S1 CTRL RAZ/WI (`tb_hex_s1_ctrl_razwi.sv`):** Confirmed `[31:2]` write-ignored and read-as-zero without side effects on `[1:0]`.
3. **S2 Exact Offset Decode (`tb_hex_s2_exact_decode.sv`):** Confirmed full `PADDR[15:0]` decode for `0x0000`, `0x0004`, `0x0008`, `0x000C`, and read-zero/write-no-side-effect for all unmapped/unaligned/mirrored offsets.
4. **S3 Firmware Shadow Host Suite (`hex_s3_shadow_host.c`):** Verified boot initialization (`hex_display_init()`), post-reset resynchronization (`hex_display_resync()`), mask enforcement (`& 0x3`), and sole-owner Shadow integrity.
5. **S4 Directed Functional Suite (`tb_hex_s4_functional.sv`):** 1,774 checks covering all 16 hexadecimal patterns per digit, active-low raw polarity, single/multi-segment packing, blanking, mode switching, and 100% detection across 3 mutation suites.
6. **S5 Interconnect & CPU E2E Suite (`tb_hex_s5_*.sv`):**
   - Tier L1 (Bridge): 4 canonical offsets forward with zero wait; noncanonical offsets suppressed with 2-cycle AHB ERROR.
   - Tier L2 (SoC Bus): Verified bus interconnect and continuous register immutability during cross-slave traffic.
   - Tier L3 (CPU E2E): RV32I load/store execution, cycle-accurate access-fault exceptions (cause 5/7) on invalid offsets, and precise MEPC alignment.
7. **S6 FPGA Build and Physical Acceptance (`P10-HEX-S6-EV-01`):**
   - Quartus Prime Lite 19.1 Fitter Pin report verified 42 unique pins `HEX0..HEX5[0:6]` with zero `HEX[7]` pins.
   - Owner-confirmed board acceptance application (`firmware/apps/s6_hex_board_acceptance.c`) on MAX 10 DE10-Lite verified states B0 through B6 plus repeated B1/B2 regression checks, documented with photo sequence B0~B8 in `reports/evidence/p10-hex-s6/summary.md`.

## 14. Interrupt and Error Behavior

The active HEX display peripheral has:

```text
IRQ output   = none
error status = none
PREADY       = 1
```

Invalid local offsets read zero and ignore writes without side effects.
The production bridge blocks noncanonical CPU requests without asserting
HEX `PSEL` and returns 2-cycle AHB ERROR (`HRESP=01`). Do not add an IRQ
or change bus-error topology in HEX display.

The display is a polling/configuration-style output peripheral and is not
assigned a PLIC source in the baseline.

## 15. Owner-Approved Cleanup Scope (Issue #3) — Status Resolution

1. **HEX-001 (VERIFIED):** Retained approved public `[6:0]` pin Tcl; verified by final Quartus Fitter Pin report (42 pins, zero `[7]`) and physical board acceptance B0~B8.
2. **HEX-002 (VERIFIED):** Retained RAW mode; independently verified all six fields, active-low polarity, packing, masking, readback, disable/enable, and reset in S0, S4, S5, and S6.
3. **HEX-003 (VERIFIED):** CTRL reserved `[31:2]` RAZ/WI implemented in RTL; reset decoded `000000` verified; sole-owner firmware Shadow with `hex_display_init()` and `hex_display_resync()` implemented and verified.
4. **Local decode / APB-005 sub-scope (VERIFIED):** RTL decodes exact `PADDR[15:0]` offsets; internal mirrors removed; bridge AHB ERROR verified.
5. **HEX-004 (DEFERRED):** DP, PWM, blink, per-digit, and atomic-RAW features remain deferred without a separate specification.

## 16. Directed Verification Requirements

A complete peripheral regression should include at least:

1. reset CTRL=`0x1`, VALUE=`0`, raw registers blank, and decoded `000000`,
2. VALUE patterns `000000`, `123456`, `ABCDEF`, `FFFFFF`,
3. verify HEX0 receives least-significant nibble and HEX5 the most-significant nibble,
4. `ENABLE=0` -> all six outputs `1111111`,
5. CTRL `[31:2]` RAZ/WI and no unintended output change,
6. raw-mode mapping for all fields, polarity, packing, masking, blank/all-on,
   readback, and disable/enable preservation,
7. decoder/raw switching and reset during active operation,
8. HEX-alone noncanonical, unaligned, and mirrored offsets: read-zero and
   write-no-side-effect; valid offsets still work,
9. CPU/AHB-through-production-bridge invalid requests: `PSEL` suppressed
   and existing AHB ERROR, independently of local-slave tests,
10. firmware Shadow initialization, explicit resync after a modeled HEX-only
    reset, and ENABLE/RAW_MODE preservation,
11. independent expected-model checking, failing-case runner behavior, and
    honest recording of commands, source identities, and unrun checks,
12. once authorized, generated-QSF/Pin Report and source-matched FPGA board
    observations; static Tcl review is not a physical PASS.

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
15. Historical QSF `HEXx[7]` assignments are not an architectural feature;
    the approved public `[6:0]` configuration is retained.
16. Exact local-offset decoding (`PADDR[15:0]`) and explicit firmware Shadow
    resynchronization (`hex_display_init()`, `hex_display_resync()`) are
    verified active baseline invariants.
