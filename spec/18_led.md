# Target SoC LED Output Peripheral Specification

> **P04 status note (2026-09-15):** APB_LED at slot 9 owns all LEDR[9:0]; reset-indicator ownership of LEDR[9] was removed. Open directed verification and the user-operated Quartus fit pass. `BOARDIO-004` remains OPEN because its explicit walking/all-on/off physical board test has not run. Pre-P04 “not implemented” text below is historical.

> **Status:** ACTIVE P04 IMPLEMENTATION / BOARD ACCEPTANCE OPEN.
>
> **Canonical language:** English. If this file and `led.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `gpio.md`, `board_io_architecture.md`.

## 1. Purpose

This document defines the dedicated APB peripheral for the ten DE10-Lite red LEDs.

The target design separates LED output control from the legacy `APB_GPIO` block and provides:

- one dedicated ten-bit output latch,
- direct control of `LEDR[9:0]`,
- deterministic reset behavior,
- software readback of the output latch,
- a minimal APB register interface.

It intentionally does not provide GPIO direction control, PWM brightness, blinking timers, interrupts, DMA, or hardware pattern generation.

## 2. Architectural Status and Address Ownership

The active baseline currently drives `LEDR[8:0]` through the legacy `APB_GPIO` block while `LEDR[9]` is a separate reset indicator.

The approved cleanup target assigns:

```text
LED_BASE = 0x4009_0000
APB slot = PSEL[9]
```

The target APB subsystem uses `PSEL[15:0]`; existing slots 0 through 7 retain their current addresses, slot 8 is SW, slot 9 is LED, and slots 10 through 15 are reserved.

These are target architectural assignments. The active FPGA baseline does not contain `APB_LED` yet, so `memory_map.md` must continue to distinguish current implementation from approved target allocation until cleanup RTL is integrated.

## 3. Target Module Boundary

Recommended module interface:

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

Conceptual topology:

```text
CPU
 |
 | APB
 v
+----------------+
|    APB_LED     |
|                |
| LED_DATA[9:0]  |
+--------+-------+
         |
         v
    LEDR[9:0]
```

The entire peripheral operates in the APB `PCLK` domain.

## 4. Physical Ownership

After integration, `APB_LED` owns all ten red LEDs:

```text
LED_DATA[0] -> LEDR[0]
...
LED_DATA[9] -> LEDR[9]
```

The legacy top-level assignment:

```verilog
assign LEDR[9] = ~HRESETn;
```

shall be removed when this target architecture becomes active.

If a visible reset/debug indicator is desired later, it shall use an explicitly approved board-status mechanism rather than taking one bit away from the software-visible LED peripheral.

## 5. Canonical Register Map

| Offset | Absolute address | Register | Access | Reset | Meaning |
|---:|---:|---|---|---:|---|
| `0x00` | `0x4009_0000` | `LED_DATA` | R/W | `0x000` | ten-bit LED output latch |

Only bits `[9:0]` are implemented. Reads return zero in bits `[31:10]`; writes ignore bits `[31:10]`.

The block shall explicitly decode `+0x00` and shall not intentionally reproduce legacy low-address register mirroring.

An earlier draft target proposed zero/no-effect for unknown registers; no standalone APB_LED RTL is active. Frozen A2 supersedes that draft: noncanonical offsets or unsupported sizes return APB ERROR without an LED peripheral side effect.

## 6. `LED_DATA` Write Semantics

A valid APB write performs:

```text
led_reg[9:0] <- PWDATA[9:0]
```

Physical outputs follow the latch directly:

```text
LEDR[9:0] = led_reg[9:0]
```

No direction register exists because these signals are dedicated outputs.

Software that needs to modify a subset of LEDs shall compute the desired ten-bit value or maintain a single software shadow.

## 7. `LED_DATA` Read Semantics

A read returns the output latch:

```text
PRDATA[9:0]   = led_reg[9:0]
PRDATA[31:10] = 0
```

This proves register state, not physical LED illumination. Board-level physical validation remains a separate acceptance step.

## 8. Reset Behavior

When `PRESETn = 0`:

```text
led_reg = 0x000
LEDR    = 0x000
```

All ten LEDs are therefore off during reset and remain off after reset until firmware writes another value.

This intentionally replaces the current special `LEDR[9]` reset-indicator behavior.

## 9. APB Behavior

The target LED block is always ready:

```text
PREADY = 1
```

Software-visible accesses are naturally aligned 32-bit MMIO operations. No byte-strobe contract is required.

## 10. Firmware Contract

The minimum API is conceptually:

```c
void led_write(uint32_t value);
uint32_t led_read(void);
```

with values masked to:

```text
value & 0x3FF
```

One LED driver should own the register so application code does not mix direct MMIO writes with an unrelated software shadow.

No interrupt or completion polling is required.

## 11. Relationship to GPIO and SW

The approved target board-I/O split is:

```text
SW[9:0]   -> APB_SW   at PSEL[8]
LEDR[9:0] <- APB_LED  at PSEL[9]
GPIO_IO[] <-> APB_GPIO at PSEL[1]
```

The legacy GPIO slot is **retained** and redesigned as a true bidirectional generic GPIO peripheral. It is not removed or reused for LED.

Legacy behavior that shall not be carried forward includes mixed SW/LED pseudo-GPIO semantics, the misleading old `GPIO_DIR` role, the 10-bit logical/9-bit physical LED mismatch, and software-inaccessible ownership of `LEDR[9]`.

## 12. Interrupt Behavior

The LED peripheral has no interrupt output. Writes complete synchronously and there is no asynchronous internal event source.

No PLIC source ID shall be allocated unless a future feature introduces asynchronous LED-related behavior through a separately approved specification revision.

## 13. Verification Requirements

Directed RTL verification shall cover at minimum:

1. reset `LED_DATA = 0`,
2. reset `LEDR[9:0] = 0`,
3. every individual LED bit 0 through 9,
4. walking-one and walking-zero patterns,
5. `0x000`, `0x3FF`, `0x155`, and `0x2AA`,
6. latch readback,
7. upper read bits zero,
8. upper write bits ignored,
9. exact register-offset decode,
10. `PREADY=1`,
11. top-level `PSEL[9]` mapping,
12. direct `led_reg[9:0] -> LEDR[9:0]` mapping,
13. proof that no independent `LEDR[9]` driver remains,
14. proof that `APB_GPIO` no longer drives board LEDs.

Board validation shall visually verify all ten LEDs and at least walking-one, all-on, all-off, and alternating patterns.

## 14. Remaining Open Decisions

The APB address, slot number, and decoder width are no longer open; they are fixed by `board_io_architecture.md`.

The A2 APB reserved/default-slave ERROR policy is frozen but not implemented. Future optional LED features remain separate and do not change the local register semantics defined here.

## 15. Target Invariants

Once implemented:

1. `LED_BASE = 0x4009_0000` and the peripheral is selected by `PSEL[9]`.
2. The APB subsystem uses the approved 16-slot target architecture.
3. `APB_LED` owns all ten `LEDR[9:0]` outputs.
4. `LED_DATA` is the sole architectural output latch.
5. Only bits `[9:0]` are implemented.
6. Reset drives all ten LEDs off.
7. Readback returns the latch, not a physical feedback signal.
8. No direction register exists.
9. No interrupt output exists.
10. The legacy `LEDR[9] = ~HRESETn` assignment is removed when this target design becomes active.
11. The legacy GPIO slot remains present but no longer owns board LED signals.
12. This block is not a general-purpose GPIO peripheral.
