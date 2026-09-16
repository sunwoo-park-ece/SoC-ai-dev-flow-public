# Baseline and Target SoC GPIO Subsystem Specification

> **P04 closure note (2026-09-15):** Part I records the historical pre-P04 SW/LED pseudo-GPIO. The public source implements Part II with 16 JP1 GPIO_IO pins, reset Hi-Z, synchronized input, and local IRQ. Open directed checks and the user-operated 16/16 post-fit pin/OE review pass; User/Chat approved `BOARDIO-001/002` as `VERIFIED`. Board-functional and full external electrical/timing closure remain separate (`VER-005`, `STA-002`).

> **Status:** DRAFT — sections 1–16 preserve the historical pre-P04 baseline; sections 17 onward define the active P04 GPIO contract. Board/electrical acceptance remains separate.
>
> **Canonical language:** English. If this file and `gpio.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`, `board_io_architecture.md`.

## 1. Purpose

This document has two explicitly separated roles.

First, it records the active baseline `APB_GPIO` implementation, including its non-general-purpose switch/LED behavior and known limitations.

Second, it defines the approved target contract that replaces that implementation during baseline cleanup while preserving the existing architectural APB location:

```text
GPIO_BASE = 0x4001_0000
PSEL[1]
```

The target GPIO becomes a reusable true bidirectional digital-I/O peripheral with synchronized input sampling and a PLIC-ready interrupt output. The DE10-Lite slide switches and red LEDs are removed from GPIO ownership and are instead owned by `APB_SW` and `APB_LED` as specified in `sw.md`, `led.md`, and `board_io_architecture.md`.

---

# Part I — Active FPGA Baseline

## 2. Active RTL Boundary

The active peripheral is:

```text
rtl/peripherals/APB_GPIO.v
```

and is instantiated in `AMBA_SoC_TOP` as APB slot 1:

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +--> PSEL[1]
       |
       v
    APB_GPIO
      |   |
      |   +--> gpio_in  <- SW[9:0]
      |
      +------> gpio_out -> LEDR[8:0] only

LEDR[9] <- ~HRESETn
```

Canonical base address:

```text
GPIO_BASE = 0x4001_0000
```

Clock/reset domain:

```text
PCLK    = 50 MHz
PRESETn = APB/system reset
```

The active peripheral permanently asserts `PREADY = 1` and has no interrupt output.

## 3. Baseline Canonical Register Map

| Offset | Register | Access | Reset | Summary |
|---:|---|---|---:|---|
| `0x00` | `GPIO_DATA` | R/W | output latch = `0x000` | write output latch; read selected input/output value |
| `0x04` | `GPIO_DIR` | R/W | `0x000` | bit `1` selects output-latch readback, bit `0` selects input readback |

Only bits `[9:0]` are implemented. Reads return zero in bits `[31:10]`; writes ignore bits `[31:10]`.

The active peripheral decodes only `PADDR[3:2]`, so the small register bank is physically mirrored every 16 bytes inside the slot. Those mirrors are implementation artifacts and are not canonical addresses.

## 4. Baseline `GPIO_DATA` Write Semantics

A valid APB write performs:

```text
gpio_out[9:0] <- PWDATA[9:0]
```

independently of `GPIO_DIR`.

The active `GPIO_DIR` therefore does not gate output driving and does not control physical FPGA output-enable logic.

## 5. Baseline `GPIO_DIR` Semantics

For each implemented bit:

```text
GPIO_DIR[i] = 0 -> GPIO_DATA read returns gpio_in[i]
GPIO_DIR[i] = 1 -> GPIO_DATA read returns gpio_out[i]
```

The read value is effectively:

```text
(gpio_out & direction) | (gpio_in & ~direction)
```

Thus the baseline `GPIO_DIR` is a readback-source selector rather than a physical bidirectional-pin direction register.

## 6. Baseline Board Mapping

Inputs:

```text
gpio_in[9:0] <- SW[9:0]
```

Outputs:

```text
gpio_out[8:0] -> LEDR[8:0]
gpio_out[9]   -> no GPIO-controlled physical LED
LEDR[9]       <- ~HRESETn
```

A software readback of logical output bit 9 can therefore succeed even though physical `LEDR[9]` is unaffected.

## 7. Baseline Read Semantics

For each bit `i` from 0 through 9:

```text
GPIO_DATA[i] = GPIO_DIR[i] ? gpio_out[i] : gpio_in[i]
```

Examples:

```text
DIR = 0x000  -> DATA read reports SW[9:0]
DIR = 0x3FF  -> DATA read reports internal output latch
```

## 8. Baseline Reset Behavior

Reset produces:

```text
gpio_out  = 0x000
direction = 0x000
```

`LEDR[8:0]` are low; `GPIO_DATA` selects the switch inputs; `LEDR[9]` remains separately owned by reset indication.

## 9. Baseline Asynchronous Input Limitation

`SW[9:0]` enters the active GPIO logic directly. There is no input synchronizer, debounce stage, sampled-input register, or event detector.

Therefore the baseline has no formal metastability or mechanical-bounce guarantee for switch reads.

## 10. Baseline Firmware Contract

The active firmware driver provides logical 10-bit operations such as:

```c
gpio_set_direction(mask & 0x3ffu);
gpio_write(value & 0x3ffu);
gpio_read() & 0x3ffu;
```

and `gpio_led_write()` configures all logical bits for output-latch readback before writing the value.

These APIs describe the active legacy block only. They shall be revised during target migration.

## 11. Baseline Diagnostic Readback Limitation

Legacy output-latch readback proves APB/register state only. It does not prove physical board-pin behavior, especially for logical bit 9.

## 12. Baseline Interrupt Behavior

The active `APB_GPIO` has no interrupt output and no edge/level detection, enable, polarity, pending, or W1C register.

GPIO is polling-only in the active FPGA baseline.

## 13. Baseline Invariants

1. Baseline GPIO base is `0x4001_0000` / `PSEL[1]`.
2. Baseline registers are `GPIO_DATA +0x00` and `GPIO_DIR +0x04`.
3. Only bits `[9:0]` are implemented.
4. `GPIO_DIR` is not a real pin-direction control.
5. `SW[9:0]` feed GPIO input directly.
6. Only output bits `[8:0]` reach `LEDR[8:0]`.
7. `LEDR[9]` is a separate reset indicator.
8. `PREADY=1`.
9. There is no baseline GPIO IRQ.
10. Register mirrors are noncanonical artifacts.

## 14. Baseline Verification Requirements

Baseline-directed verification should retain coverage of reset state, legacy DATA/DIR semantics, mixed readback, logical bit-9 behavior, APB completion, and the physical switch/LED ownership mismatch so that migration does not accidentally reinterpret old FPGA evidence.

## 15. Baseline Cleanup Motivation

The baseline implementation shall not be incrementally extended while retaining its pseudo-GPIO semantics. The approved cleanup instead separates board switch/LED ownership and replaces this slot's internal behavior with the target contract in Part II.

## 16. Active Sources of Truth

Baseline behavior was reconstructed from:

```text
rtl/peripherals/APB_GPIO.v
rtl/soc/AMBA_SoC_TOP.v
firmware/include/gpio.h
firmware/drivers/gpio.c
firmware/apps/display_smoke.c
```

---

# Part II — Approved Target GPIO Contract

> **TARGET MIGRATION NOTE — NOT CURRENT FPGA BASELINE:** The remainder of this document defines the approved cleanup target. Until RTL, firmware, directed verification, FPGA build, and board acceptance are completed, it shall not be cited as evidence of current hardware behavior.

## 17. Target Architectural Role

The target GPIO retains the existing APB ownership:

```text
GPIO_BASE = 0x4001_0000
PSEL[1]
```

but no longer owns:

```text
SW[9:0]
LEDR[9:0]
```

Those are moved to dedicated peripherals.

The target GPIO instead owns a selected bank of external bidirectional FPGA pins:

```text
GPIO_IO[GPIO_WIDTH-1:0]
```

The exact DE10-Lite expansion-header pin mapping remains a board-integration decision, but the logical peripheral contract is fixed here.

## 18. GPIO Width Policy

The target module shall be parameterized:

```text
1 <= GPIO_WIDTH <= 32
```

All software-visible registers remain 32 bits wide.

For every register containing per-pin fields:

```text
implemented bits              = [GPIO_WIDTH-1:0]
read bits [31:GPIO_WIDTH]     = 0
write bits [31:GPIO_WIDTH]    = ignored
```

The register architecture is parameterized, but frozen A1 selects 16 bits and the JP1 GPIO_0–15 physical mapping for this board target.

## 19. Recommended Target Module Boundary

```text
module APB_GPIO #(
    parameter integer GPIO_WIDTH = 16
)

Inputs:
  PCLK
  PRESETn
  PADDR[31:0]
  PWRITE
  PSEL
  PENABLE
  PWDATA[31:0]

Inout:
  GPIO_IO[GPIO_WIDTH-1:0]

Outputs:
  PRDATA[31:0]
  PREADY
  gpio_irq
```

Conceptually:

```text
                 +----------------------+
APB ------------>|      APB_GPIO        |
                 |                      |
                 | DATA_OUT             |
                 | DIR / output-enable  |----+
                 |                      |    |
                 | 2FF input sync       |<---+---- GPIO_IO[]
                 |                      |
                 | IRQ detect/pending   |
                 +----------+-----------+
                            |
                         gpio_irq
                            |
                         future PLIC
```

## 20. Target Canonical Register Map

| Offset | Register | Access | Reset | Meaning |
|---:|---|---|---:|---|
| `0x00` | `GPIO_DATA_IN` | RO | synchronized pin state | synchronized physical input levels |
| `0x04` | `GPIO_DATA_OUT` | R/W | `0` | output-data latch |
| `0x08` | `GPIO_DIR` | R/W | `0` | `0=input/Hi-Z`, `1=output drive` |
| `0x0C` | `GPIO_IRQ_ENABLE` | R/W | `0` | per-pin local IRQ enable |
| `0x10` | `GPIO_IRQ_TYPE` | R/W | `0` | `0=level`, `1=edge` |
| `0x14` | `GPIO_IRQ_POLARITY` | R/W | `0` | level: `0=low`, `1=high`; edge: `0=falling`, `1=rising` |
| `0x18` | `GPIO_IRQ_BOTH_EDGE` | R/W | `0` | for edge mode only: `1=both edges` |
| `0x1C` | `GPIO_IRQ_PENDING` | R / W1C | `0` edge-pending | effective pending view; W1C clears sticky edge events only |

Only these offsets are canonical. The target peripheral shall explicitly decode them and shall not intentionally recreate the baseline register mirroring.

Current unknown reads return zero and unknown writes have no functional effect. Frozen A2 instead requires ERROR for noncanonical register offsets or unsupported access sizes, with no peripheral side effect.

## 21. True Bidirectional Pin Semantics

Per pin `i`:

```text
GPIO_DIR[i] = 0
    -> FPGA output-enable deasserted
    -> pin is input / high-impedance from this peripheral

GPIO_DIR[i] = 1
    -> FPGA output-enable asserted
    -> pin driven from GPIO_DATA_OUT[i]
```

Conceptually:

```verilog
assign GPIO_IO[i] = GPIO_DIR[i] ? GPIO_DATA_OUT[i] : 1'bz;
```

Actual FPGA I/O-buffer inference may be implemented in the top-level or peripheral wrapper, but this architectural behavior is mandatory.

No pull-up, pull-down, drive-strength, slew-rate, or pin-mux control is provided through MMIO in this target revision. Those remain board constraints or future features.

## 22. `GPIO_DATA_OUT`

A valid write updates the output latch:

```text
GPIO_DATA_OUT[GPIO_WIDTH-1:0] <- PWDATA[GPIO_WIDTH-1:0]
```

The latch may be written regardless of `GPIO_DIR`.

This is intentional: software may preload output data while the pin is still an input and then set `GPIO_DIR` to output, avoiding an unintended intermediate output value.

Reads return the output latch, not physical pin feedback.

No SET/CLEAR/TOGGLE alias registers are required in this target revision.

## 23. `GPIO_DATA_IN` and Input Synchronization

Every external GPIO pin is asynchronous relative to `PCLK` and shall pass through at least a two-flop destination-domain synchronizer before becoming software-visible or entering IRQ detection:

```text
GPIO_IO[i]
    |
    v
sync_ff1[i]
    |
    v
sync_ff2[i] = gpio_in_sync[i]
```

`GPIO_DATA_IN[i]` returns `gpio_in_sync[i]`.

The synchronized input shall remain available even when the pin is configured as an output. This permits optional observation of the physical pin level, but software shall not treat this as guaranteed external electrical feedback under contention.

## 24. Direction-Change IRQ Arming Rule

Changing a pin from output to input shall not create a false edge interrupt merely because the current synchronized input differs from stale edge-history state.

Therefore on an effective direction transition:

```text
GPIO_DIR[i]: 1 -> 0
```

edge-history for that pin shall be re-armed to the current synchronized input value before edge detection resumes.

Changing a pin to output:

```text
GPIO_DIR[i]: 0 -> 1
```

shall remove the pin from local IRQ qualification and clear any sticky edge-pending bit for that pin. This prevents stale input events from unexpectedly reasserting if the pin is later returned to input mode.

## 25. IRQ Source Eligibility

Only pins configured as inputs may contribute to `gpio_irq`:

```text
input_mask = ~GPIO_DIR
```

An output-configured pin shall never assert the local GPIO IRQ, regardless of IRQ configuration registers.

This rule keeps interrupt behavior tied to external input observation rather than software-driven output transitions.

## 26. IRQ Mode Selection

Each pin independently chooses level or edge mode.

```text
GPIO_IRQ_TYPE[i] = 0 -> level-sensitive local source
GPIO_IRQ_TYPE[i] = 1 -> edge-sensitive sticky event source
```

### 26.1 Level mode

For a level-mode input pin:

```text
GPIO_IRQ_POLARITY[i] = 0 -> active when synchronized input is 0
GPIO_IRQ_POLARITY[i] = 1 -> active when synchronized input is 1
```

The level condition is not stored as a sticky event. It remains active as long as the synchronized input matches the configured active level.

### 26.2 Edge mode

For an edge-mode input pin with `GPIO_IRQ_BOTH_EDGE[i] = 0`:

```text
GPIO_IRQ_POLARITY[i] = 0 -> falling edge
GPIO_IRQ_POLARITY[i] = 1 -> rising edge
```

If:

```text
GPIO_IRQ_BOTH_EDGE[i] = 1
```

then either synchronized logical transition sets the sticky edge-pending bit and `GPIO_IRQ_POLARITY[i]` is ignored for that pin.

`GPIO_IRQ_BOTH_EDGE` has no effect in level mode.

## 27. Sticky Edge-Pending State

Edge-mode events set an internal sticky state:

```text
edge_pending[i] = 1
```

that remains set until software writes one to the corresponding bit of `GPIO_IRQ_PENDING` or until the pin is changed to output mode as defined above.

The required simultaneous event/clear rule is set-dominant:

```text
edge_pending_next = (edge_pending & ~w1c_mask) | edge_event
```

for eligible input/edge pins.

A new event therefore cannot be lost merely because software clears the bit in the same PCLK cycle.

## 28. `GPIO_IRQ_PENDING` Read Semantics

`GPIO_IRQ_PENDING` is an **effective pending view**, combining sticky edge events with live level conditions.

Conceptually:

```text
edge_view  = edge_pending & GPIO_IRQ_TYPE
level_view = level_active & ~GPIO_IRQ_TYPE

GPIO_IRQ_PENDING = (edge_view | level_view) & ~GPIO_DIR
```

The register is readable independent of `GPIO_IRQ_ENABLE` so software may inspect sources even while masked.

### 28.1 W1C semantics

A write-one-to-clear operation affects sticky edge pending only.

For level-mode pins, W1C does not suppress an active physical level. If the input remains at the configured active level, the pending read value remains asserted.

This behavior is intentional and matches normal level-interrupt semantics.

## 29. IRQ Enable and Module-Level IRQ

`GPIO_IRQ_ENABLE` masks which effective pending sources contribute to the module-level interrupt output.

Pending/event capture itself is independent of the enable bit.

The local output is:

```text
gpio_irq = |(GPIO_IRQ_PENDING & GPIO_IRQ_ENABLE)
```

Properties:

- active high,
- level output toward the future PLIC,
- remains high while any enabled effective pending source is active,
- output pins are excluded by `GPIO_DIR`,
- no pulse-only IRQ behavior.

No PLIC source ID is assigned here. Source ID, priority, threshold, claim/complete, CPU CSR behavior, and interrupt-vs-exception priority remain owned by the future PLIC specification.

## 30. Reset Behavior

Target reset shall produce:

```text
GPIO_DATA_OUT      = 0
GPIO_DIR           = 0          // all pins input / Hi-Z
GPIO_IRQ_ENABLE    = 0
GPIO_IRQ_TYPE      = 0          // level mode default
GPIO_IRQ_POLARITY  = 0          // active-low default
GPIO_IRQ_BOTH_EDGE = 0
edge_pending       = 0
gpio_irq           = 0
```

The input synchronizer shall be allowed to acquire the physical pin state after reset release.

Edge detection shall use a warm-up/arming mechanism so static pin levels present during reset do not create false edge events.

Because IRQ enables reset to zero, level-active inputs cannot assert `gpio_irq` until software explicitly enables them.

## 31. APB Behavior

The target GPIO remains a simple always-ready register peripheral:

```text
PREADY = 1
```

Software-visible accesses shall be naturally aligned 32-bit operations.

No `PSTRB` or partial-write contract is required unless the future APB/AXI bridge architecture explicitly adds one.

## 32. Firmware Programming Contract

A safe generic initialization sequence is:

```text
1. GPIO_IRQ_ENABLE = 0
2. configure GPIO_DATA_OUT for pins that will become outputs
3. configure GPIO_DIR
4. configure IRQ_TYPE / IRQ_POLARITY / IRQ_BOTH_EDGE for input pins
5. W1C stale edge pending bits through GPIO_IRQ_PENDING
6. write GPIO_IRQ_ENABLE mask
```

For a PLIC-connected level interrupt, ISR service shall clear the peripheral cause before PLIC complete whenever the source is edge-pending. For level mode, software or the external device must remove the active level before completion if immediate retriggering is not desired.

Suggested driver ownership is split into explicit operations such as:

```text
gpio_read_inputs()
gpio_read_outputs()
gpio_write_outputs()
gpio_set_direction()
gpio_irq_configure()
gpio_irq_pending()
gpio_irq_clear()
gpio_irq_enable()
```

Legacy board-specific helpers such as `gpio_led_write()` shall be removed from GPIO ownership after `APB_LED` is introduced.

## 33. Verification Requirements for Target GPIO

Directed RTL verification shall cover at minimum:

1. reset of all target registers and all pins in input/Hi-Z mode,
2. output preload while direction remains input,
3. transition to output without an incorrect intermediate driven value,
4. input-to-output and output-to-input direction changes,
5. synchronized DATA_IN behavior,
6. DATA_OUT latch readback independent of physical input,
7. upper unused register bits read zero/write ignored,
8. exact register-offset decode with no legacy mirroring,
9. rising-edge interrupt,
10. falling-edge interrupt,
11. both-edge interrupt,
12. active-high level interrupt,
13. active-low level interrupt,
14. IRQ enable masking without suppressing event capture,
15. W1C edge-pending clear,
16. set-dominant simultaneous edge event + W1C,
17. level pending remaining active despite W1C while the pin level remains asserted,
18. no IRQ contribution from output-configured pins,
19. output-to-input re-arm without a false edge event,
20. input-to-output clearing/masking of stale edge pending,
21. multiple simultaneous pin sources,
22. `gpio_irq` assertion/deassertion from the OR of enabled effective pending sources,
23. `PREADY=1`,
24. physical tri-state/output-enable behavior at the top-level I/O boundary.

FPGA board acceptance shall additionally verify selected expansion-header pins as both input and output and exercise at least one edge-triggered and one level-triggered local IRQ source before PLIC hookup.

## 34. Target Invariants

Once implemented and promoted from target to active contract:

1. GPIO remains at `0x4001_0000` / `PSEL[1]`.
2. `SW[9:0]` and `LEDR[9:0]` are not GPIO-owned signals.
3. The module may be parameterized 1–32, but the frozen DE10-Lite target binds `GPIO_WIDTH=16` to JP1 GPIO_0–15.
4. `GPIO_DIR=0` means input/Hi-Z; `GPIO_DIR=1` means driven output.
5. Inputs are synchronized before software/IRQ use.
6. DATA_IN, DATA_OUT, and DIR are separate architectural registers.
7. Only input-configured pins can create GPIO IRQs.
8. Level and edge IRQ modes are selectable per pin.
9. Edge mode supports rising, falling, and both-edge detection.
10. Edge events are sticky and W1C with set-dominant simultaneous-event behavior.
11. Level sources are live conditions and cannot be cleared by W1C while the active level remains.
12. `gpio_irq` is an active-high level signal for future PLIC integration.
13. No PLIC source ID is implied by this document.
14. Target register mirroring is prohibited.
15. The target GPIO is a reusable general-purpose digital-I/O peripheral rather than a board-specific SW/LED wrapper.

## 35. Relationship to Other Target Specifications

System-level ownership and APB slot expansion are governed by `board_io_architecture.md`.

Dedicated board I/O remains:

```text
SW[9:0]   -> APB_SW  @ 0x4008_0000 / PSEL[8]
LEDR[9:0] <- APB_LED @ 0x4009_0000 / PSEL[9]
```

The future PLIC specification shall assign source IDs for `gpio_irq` and `sw_irq` and define CPU-visible interrupt behavior.

## Phase 4A-2 Approved GPIO Physical Target (active after P04)

A1 freezes `GPIO_WIDTH=16`, `GPIO_IO[0:15]` mapped 1:1 to DE10-Lite JP1 `GPIO_[0:15]`, package pins `V10,W10,V9,W9,V8,W8,V7,W7,W6,V5,W5,AA15,AA14,W13,W12,AB13` in ascending bit order. P04 implements and fits this mapping. JP1 `GPIO_27/29/31/34/35` remain existing UART/LoRa functions, not generic GPIO; preserve other fixed-function pins. Canonical registers are DATA_IN, DATA_OUT, DIR/OE and the local IRQ registers defined above. DIR=0 means input/Hi-Z; DIR=1 drives DATA_OUT; reset is Hi-Z. External inputs use two PCLK synchronizer flops. Local IRQ semantics above remain; `gpio_irq` reaches the SoC boundary but not the CPU before PLIC.

### GPIO electrical-use contract

- The pins are configured as 3.3-V LVTTL; do not assume or claim 5-V tolerance.
- Never connect an externally driven output against an FPGA GPIO configured as an output.
- Verify the external peer's voltage compatibility and drive/load requirements before enabling output mode.
- Where no explicit per-pin drive-strength assignment exists, Quartus currently uses its default drive-strength behavior; that default is not a peer-specific approval.
- A peer-specific requirement may justify an explicit drive strength or additional constraint after evidence review.
- Peer timing/load characterization, I/O-delay derivation, signal integrity and full external timing closure belong to `STA-002`. `BOARDIO-002` being `VERIFIED` does not close `STA-002`.
