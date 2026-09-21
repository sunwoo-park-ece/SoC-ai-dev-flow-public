# Baseline SoC HEX Display Specification

> **Status:** DRAFT — current implementation is distinguished from the Owner-approved HEX Cleanup target (private Issue #3, 2026-09-21). Target behavior is not yet implementation or verification evidence.
>
> **Canonical language:** English. If this file and `spec/kor/16_hex_display.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`.

## 1. Purpose

This document defines the software-visible six-digit seven-segment HEX display peripheral in the active FPGA baseline and its approved cleanup target.

It specifies the APB/MMIO registers, value and raw-mode packing, active-low outputs, reset, firmware ownership, physical integration, evidence limits, and directed cleanup acceptance.

The block has no scan engine, PWM brightness control, interrupt, DMA interface, or decimal-point control. These capabilities are not being added by HEX Cleanup.

## 2. Active Architecture

```text
HEX_DISPLAY_BASE = 0x4007_0000
APB slot         = PSEL[7]
```

Active RTL: `rtl/peripherals/APB_HEX_display.v`.

```text
CPU -> AHB -> AHB/APB bridge -> PSEL[7] -> APB_HEX_display
                                             |-- VALUE
                                             |-- CTRL
                                             |-- RAW_LOW / RAW_HIGH
                                             |-- decoder / raw mux
                                             `--> HEX0..HEX5[6:0]
```

The block operates in the APB `PCLK` domain. In this baseline, `PCLK = HCLK = 50 MHz`; the peripheral has no internal CDC or interrupt. `PREADY = 1`.

## 3. Physical Display Contract

The top exposes `HEX0[6:0]` through `HEX5[6:0]`, and no eighth decimal-point bit. Segment order is `{g,f,e,d,c,b,a}`; output `0` illuminates the segment and `1` turns it off (active-low).

### 3.1 Historical QSF discrepancy and approved pin policy

The Owner confirms that a **historical local QSF** contained stale `HEXx[7]` assignments, although the actual top-level ports are seven bits. This is a historical source, **not a statement that the current public constraints still contain bit 7**.

The current public `fpga/quartus/constraints/de10_lite_pins.tcl` assigns only `HEX0..HEX5[6:0]`; the Owner has reviewed and approved retaining it unchanged. `scripts/wsl/private_quartus.py` generates the private Quartus QSF and includes that public pin Tcl via a `source` path. Do not add a speculative removal patch for absent public `HEXx[7]` lines or reintroduce DP support.

This approves the public pin-width/configuration policy only. A generated-QSF/Pin Report check and source-matched physical HEX board acceptance are separate evidence and are **not claimed performed here**.

## 4. Register Map and Address Decode

The only canonical software-visible registers are:

| Offset | Register | Access | Functional bits | Description |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | Six decoder-mode hexadecimal nibbles |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` | Display enable and raw-mode control |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | HEX0..HEX2 raw patterns |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | HEX3..HEX5 raw patterns |

**Current RTL:** `PADDR[3:2]` alone selects the four registers. Consequently, a testbench directly selecting the HEX slave can trigger a 16-byte local mirror. **Current production path:** the AHB/APB bridge's slot-7 allowlist already forwards only the four exact canonical offsets. Noncanonical accesses are blocked without asserting HEX `PSEL` and use the bridge's AHB ERROR path; software does not have a supported alias.

**Owner-approved cleanup target:** the HEX slave itself must compare the **entire `PADDR[15:0]` offset** against exactly `0x0000`, `0x0004`, `0x0008`, and `0x000C`. Every other offset, including unaligned and previously mirrored offsets, must read as zero and have **no write side effect**, without changing any register or HEX output. Preserve `PREADY=1`; do not add a `PSLVERR` port. Retain the production bridge's existing allowlist, `PSEL` suppression, and AHB ERROR behavior unchanged. Local-slave rejection and CPU-through-bridge rejection require distinct tests.

The APB interface lacks `PSTRB`; supported firmware accesses are naturally aligned 32-bit MMIO operations.

## 5. `HEX_VALUE` — Decoder-Mode Data

`HEX_VALUE[23:0]` contains six nibbles:

```text
VALUE[ 3: 0] -> HEX0
VALUE[ 7: 4] -> HEX1
VALUE[11: 8] -> HEX2
VALUE[15:12] -> HEX3
VALUE[19:16] -> HEX4
VALUE[23:20] -> HEX5
```

Writing `0xABCDEF` displays `A B C D E F` from HEX5 through HEX0 in enabled decoder mode. Write bits `[31:24]` are discarded and read as zero.

### 5.1 Hexadecimal Decoder

The active-low `{g,f,e,d,c,b,a}` decoder is:

| Hex | Pattern |
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

Every digit supports `0..F`.

## 6. `HEX_CTRL`

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `ENABLE` | `1`: selected pattern; `0`: blank all six digits |
| 1 | `RAW_MODE` | `0`: decoder; `1`: raw segments |
| 31:2 | Reserved | Owner-approved **RAZ/WI**: ignore writes, always read zero |

**Current RTL:** stores the complete 32-bit CTRL value, although only bits `[1:0]` affect display output. This is an implementation gap, not the approved behavior.

**Cleanup target:** retain only `PWDATA[1:0]` on a valid CTRL write; reads return `{30'b0, CTRL[1:0]}`. Writing ones to reserved bits must not alter stored state, any display output, or future reads. Firmware writes reserved bits as zero. There are no extra reserved-bit control features.

### 6.1 Display Disable

When `ENABLE=0`, each digit outputs `7'b1111111` (blank). Disable must preserve VALUE, both RAW registers, and RAW_MODE. Re-enable must restore the selected stored pattern.

## 7. Raw Segment Mode

**Retained and supported in cleanup.** When `RAW_MODE=1`, the stored raw fields drive the six outputs instead of VALUE/decoder:

```text
RAW_LOW [ 6: 0] -> HEX0[6:0]
RAW_LOW [13: 7] -> HEX1[6:0]
RAW_LOW [20:14] -> HEX2[6:0]
RAW_HIGH[ 6: 0] -> HEX3[6:0]
RAW_HIGH[13: 7] -> HEX4[6:0]
RAW_HIGH[20:14] -> HEX5[6:0]
```

All fields use `{g,f,e,d,c,b,a}` active-low. For example, `7'b1111111` is blank, `7'b0000000` turns all segments on, and `7'b1000000` displays zero. RAW write bits `[31:21]` are discarded and read zero. There is no DP, brightness, blink, or per-digit enable control.

## 8. Reset Behavior

The Owner explicitly approves preserving the existing reset state:

```text
VALUE     = 0x000000
CTRL      = 0x00000001
RAW_LOW   = {3{7'b1111111}}
RAW_HIGH  = {3{7'b1111111}}
ENABLE    = 1
RAW_MODE  = 0
```

Post-reset visible display is decoded **`000000`**, not blank. Reserved CTRL bits reset/read as zero in the target. Raw registers reset blank but are inactive until raw mode is selected.

## 9. Update Timing

Valid register writes occur at the PCLK edge for `PSEL && PENABLE && PWRITE`. Cleanup adds exact-offset qualification so invalid local addresses do not write. Outputs are combinational functions of stored registers; no scan FSM exists.

Two independent RAW_LOW/RAW_HIGH writes are **not atomic**. The visible pattern may mix old/new halves between writes. A single VALUE write updates all six decoder-mode nibbles together.

## 10. Firmware Contract

Active driver:

```text
firmware/drivers/hex_display.c
firmware/include/hex_display.h
```

Current APIs:

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

```c
hex_display_enable(1);
hex_display_set_raw_mode(0);
hex_display_write_value(value & 0x00ffffffu);
```

### 10.2 Raw-Mode Sequence

```c
hex_display_write_raw(raw_low, raw_high);
hex_display_set_raw_mode(1);
hex_display_enable(1);
```

When visual atomicity matters, software may blank the display, write RAW_LOW and RAW_HIGH, select RAW_MODE, then re-enable. This avoids showing the mixed intermediate pattern but does not make the two writes an atomic hardware operation.

### 10.3 Single CTRL Owner, Shadow and Explicit Resynchronization

**Current:** `hex_display.c` maintains `static uint32_t hex_ctrl_shadow = HEX_CTRL_ENABLE` and writes full CTRL values from that state. Direct writes from other code or a HEX-only hardware reset during firmware execution can leave Shadow stale.

**Owner-approved cleanup target:** `hex_display.c` is the **sole software writer** of `HEX_CTRL`; direct application/ISR writes and concurrent uncontrolled writers are prohibited. Keep the software Shadow design rather than converting normal helpers to hardware read-modify-write. Shadow and CTRL writes contain only functional bits `[1:0]` (`& 0x3`). After a normal system reset and firmware initialization, both hardware CTRL and Shadow must be `0x1`.

Define an explicit driver initialization/resynchronization procedure or API. If the HEX hardware alone resets during firmware execution, or out-of-band changes are suspected, the caller must resynchronize **before the next CTRL update** by reading hardware CTRL, masking `& 0x3`, and updating Shadow. No automatic reset detection is implied; resynchronization does not authorize direct out-of-driver writes. The API name and implementation are not claimed to exist yet. Validate initialization, explicit resynchronization after a separately modeled reset, and ENABLE/RAW_MODE preservation. Any future multi-context/ISR ownership must serialize driver accesses.

## 11. Monitor Packing Used by Baseline Firmware

`hex_display_write_monitor()` packs six firmware fields:

```text
HEX5 = mode
HEX4 = state
HEX3 = retry_count
HEX2 = err
HEX1 = rx_seq
HEX0 = tx_seq
```

Equivalent VALUE bits: `[23:20] mode`, `[19:16] state`, `[15:12] retry_count`, `[11:8] err`, `[7:4] rx_seq`, `[3:0] tx_seq`. This is a firmware convention, not new RTL state.

## 12. Readback Semantics

All four canonical registers are readable. VALUE `[31:24]` and RAW `[31:21]` read zero. The target CTRL `[31:2]` reads zero and invalid local offsets read zero. A register readback does **not** prove physical pin continuity, board segment polarity, or actual segment illumination; board observation or pin-level measurement is required for those claims.

## 13. Validation Evidence and Limits

The historical `display_smoke` diagnostic selects decoder mode, writes `b00701`, cycles six digits through `000000` to `FFFFFF`, and checks VALUE readback. A historical board-result statement reports successful physical diagnostic behavior; the public snapshot does not include sufficient original board-result provenance to make that statement fresh, source-matched HEX Cleanup board acceptance.

This historical diagnostic does **not** independently establish raw six-field mapping, disable semantics, reserved-bit RAZ/WI, local mirror rejection, generated pin assignments, or the cleanup candidate's physical behavior. Owner design approval and source-code inspection are not simulation PASS or FPGA verification.

## 14. Interrupt and Error Behavior

The HEX slave has no IRQ or local error-status register and asserts `PREADY=1`. It has no `PSLVERR` output. Its target invalid-local-offset behavior is read-zero/write-ignore; the existing **production bridge** is responsible for blocking noncanonical CPU requests and returning AHB ERROR. Do not add an IRQ or change bus error topology in HEX Cleanup.

## 15. Owner-Approved Cleanup Scope (Issue #3, 2026-09-21)

1. **HEX-001:** historical local QSF had stale HEXx[7]; preserve the already corrected/approved public `[6:0]` pin Tcl and record the `private_quartus.py` source path. No imaginary public pin patch. Generated-QSF/Pin Report and current board results remain separate unverified evidence.
2. **HEX-002:** preserve RAW mode and independently verify six distinct fields, bit mapping, active-low output, masking/readback, disable/enable and reset.
3. **HEX-003:** CTRL reserved `[31:2]` RAZ/WI; keep reset decoded `000000`; sole-owner firmware Shadow with explicit initialization and resynchronization; no routine HW RMW.
4. **Local decode / APB-005 sub-scope:** remove HEX's internal 16-byte mirror by exact full-offset checks. For invalid local addresses return zero and ignore writes without adding PSLVERR. Preserve the production bridge's existing canonical allowlist/error behavior.
5. **HEX-004 remains deferred:** no DP, PWM, blink, per-digit, or atomic-RAW feature addition.

The above are approved **requirements**, not implemented/verified statuses. Keep the public cleanup tracker evidence-based.

## 16. Directed Verification Requirements

The cleanup regression shall independently check:

1. Reset CTRL=`0x1`, VALUE=`0`, raw registers blank, and decoded six-digit `000000`.
2. VALUE `000000`, `123456`, `ABCDEF`, `FFFFFF`; HEX0 LSB through HEX5 MSB and complete `0..F` decoder table as applicable.
3. ENABLE=0 blanks all six outputs; re-enable preserves VALUE/RAW/mode.
4. All six RAW fields with distinct patterns, active-low polarity, RAW_LOW/HIGH packing, blank/all-on cases, readback and high-bit masking.
5. CTRL `[31:2]` RAZ/WI under writes with reserved bits set; readback only `[1:0]`; no unintended output change.
6. Decoder/raw transitions and reset during active operation without register corruption.
7. HEX-alone noncanonical/unaligned/mirrored offsets: read-zero, write-no-side-effect, state and outputs unchanged; valid offsets still work.
8. CPU/AHB-through-production-bridge invalid requests: `PSEL` suppressed and existing AHB ERROR; do not infer this solely from local-slave tests.
9. Firmware sole-writer Shadow behavior, default initialization, explicit resync after simulated HEX-only reset, preservation of ENABLE/RAW_MODE, and no unauthorized application MMIO writes.
10. Parent runner returns nonzero on a failing case. Checkers must compare actual outputs against an independent expected model and reject a targeted counterexample. Report actual commands/source identities and honestly mark unrun checks.
11. Once authorized, generated-QSF/Pin Report and source-matched FPGA board observations for decoder and retained raw mode; do not mark these PASS from static Tcl review.

## 17. Baseline Invariants

1. `HEX_DISPLAY_BASE = 0x4007_0000`; APB `PSEL[7]`; `PREADY=1`.
2. Six independently driven `HEX0..HEX5[6:0]`, active-low `{g,f,e,d,c,b,a}`; no DP.
3. Decoder VALUE LSB nibble to HEX0, MSB nibble to HEX5, full `0..F` support.
4. CTRL bit 0 ENABLE, bit 1 RAW_MODE. Cleanup target reserves `[31:2]` RAZ/WI.
5. RAW_LOW drives HEX0..2 and RAW_HIGH drives HEX3..5; RAW mode remains supported.
6. Reset is enabled decoder mode and visible `000000`.
7. There is no HEX interrupt, and the production bridge's invalid-offset AHB ERROR path remains unchanged.
8. Approved public pin constraints are `[6:0]`; historical local QSF `[7]` is not a current feature.
9. Internal exact-offset decoding and explicit FW Shadow resynchronization are cleanup targets until RTL/FW verification proves them implemented.
