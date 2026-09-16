# Target SoC Board I/O Architecture Specification

> **P04 closure note (2026-09-15):** The approved GPIO/SW/LED one-owner topology and JP1 16-pin public assignments are implemented. Open verification and the user-operated Quartus fit pass. User/Chat approved `APB-001`, `BOARDIO-001/002/003/005/006`, `FW-006`, and `FW-011` as `VERIFIED`; `FW-007` is IN_PROGRESS pending its explicit board test. Pre-P04 diagrams below are historical. `BOARDIO-004`, `FW-005/007`, board acceptance, and `STA-002` retain their separate gaps.

> **Status:** ACTIVE P04 ARCHITECTURE WITH OPEN ACCEPTANCE ITEMS — see the closure note and canonical tracker for row-level state.
>
> **Canonical language:** English. If this file and `board_io_architecture.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`, `gpio.md`, `sw.md`, `led.md`.

## 1. Purpose

This document defines the cross-cutting board-I/O architecture that replaces the legacy coupling among `APB_GPIO`, DE10-Lite switches, and DE10-Lite LEDs.

It owns the system-level decisions that span multiple local peripheral specifications:

- expansion of the APB select vector from 8 slots to 16 slots,
- preservation of the existing GPIO APB slot,
- redesign of the legacy GPIO block into a true bidirectional GPIO peripheral,
- separation of DE10-Lite slide switches into a dedicated `APB_SW` peripheral,
- separation of DE10-Lite red LEDs into a dedicated `APB_LED` peripheral,
- assignment of SW and LED to APB slots 8 and 9,
- reservation of APB slots 10 through 15,
- provision of GPIO and SW interrupt wires for future PLIC integration,
- migration and verification requirements for the baseline-cleanup pass.

This file owns system-level integration and resource ownership. Detailed local register semantics are owned by `gpio.md`, `sw.md`, and `led.md`.

## 2. Baseline Problem Statement

The active FPGA baseline currently uses `APB_GPIO` as a board-specific mixed input/output block:

```text
                    legacy APB_GPIO
                   /               \
                  /                 \
          SW[9:0] input        gpio_out[9:0]
                                   |
                                   +--> LEDR[8:0]

LEDR[9] <--------------------------- ~HRESETn
```

The existing `GPIO_DIR` register does not control physical pin direction. It only selects which source is returned by `GPIO_DATA` reads.

Therefore the target cleanup shall remove the board-specific SW/LED coupling while preserving the GPIO APB slot for a real general-purpose GPIO implementation.

## 3. Target Architecture Summary

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

Responsibilities are strictly separated:

- `APB_GPIO`: reusable bidirectional external digital I/O,
- `APB_SW`: DE10-Lite switch input + change-event IRQ,
- `APB_LED`: DE10-Lite LED output.

SW and LED board signals shall no longer pass through `APB_GPIO`.

## 4. APB Expansion Policy

### 4.1 Select width

The target APB subsystem shall expand:

```text
baseline: PSEL[7:0]
target:   PSEL[15:0]
```

The target decoder shall expose sixteen canonical 64-KiB slots selected by `PADDR[19:16]` inside the approved APB region.

### 4.2 Target slot allocation

| `PSEL` | Canonical base | Peripheral | Status |
|---:|---:|---|---|
| 0 | `0x4000_0000` | UART0 / LoRa | existing |
| 1 | `0x4001_0000` | GPIO | existing slot, redesigned peripheral |
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

Existing peripheral base addresses shall not move.

### 4.3 Reserved-slot policy

Slots 10 through 15 remain architecturally reserved until a later approved specification allocates them.

Software shall not use reserved-slot addresses. Frozen A2 requires the internal/default APB error responder for them; baseline silent zero/OKAY behavior is not the target contract.

## 5. APB Decoder and Response-Mux Requirements

Implementation shall consistently widen the APB infrastructure from 8 to 16 slots, including:

- bridge `PSEL` output width,
- `decode_psel()` or equivalent decoder,
- SoC top-level wiring,
- `PRDATA` mux,
- `PREADY` mux,
- verification assertions/scoreboards,
- testbench/debug logic containing eight-slot assumptions.

Conceptually:

```text
slot = PADDR[19:16]
PSEL = 16'b1 << slot
```

shall be produced only for an active transaction inside the approved canonical APB region.

The current aliasing caused by incomplete higher-address checks shall be removed when this decoder is revised.

## 6. Target GPIO Role

### 6.1 Slot and ownership

GPIO retains:

```text
GPIO_BASE = 0x4001_0000
PSEL[1]
```

The target GPIO shall no longer connect to:

```text
SW[9:0]
LEDR[9:0]
```

Those signals are exclusively owned by `APB_SW` and `APB_LED`.

### 6.2 Authoritative local GPIO contract

The detailed target GPIO peripheral contract is now finalized in `gpio.md` (`spec/11_gpio.md`).

This architecture requires that implementation conform to that local contract rather than inventing another GPIO register model during RTL work.

The target GPIO is a parameterized true bidirectional bank with:

```text
1 <= GPIO_WIDTH <= 32
```

and the following canonical target registers:

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

Frozen A1 selects `GPIO_WIDTH=16` and JP1 `GPIO_[0:15]` in 1:1 bit order. P04 implements the public assignments and the fresh fit places all 16 as intended; User confirms no actual wiring conflict. Peer-specific quantitative electrical/timing closure remains `STA-002` work.

### 6.3 True bidirectional semantics

The required physical behavior is:

```text
GPIO_DIR[i] = 0 -> input / output-enable disabled / pin Hi-Z
GPIO_DIR[i] = 1 -> output / drive GPIO_DATA_OUT[i]
```

`GPIO_DATA_OUT` may be written while the pin is configured as input, allowing output data to be preloaded before direction changes.

All asynchronous external input sampling and GPIO IRQ detection shall use synchronized PCLK-domain input state as defined by `gpio.md`.

### 6.4 Finalized GPIO IRQ contract

`gpio.md` now owns the detailed GPIO IRQ behavior. At system level, the required interface is:

```text
gpio_irq -> future PLIC
```

The local GPIO design supports per-pin:

```text
IRQ_ENABLE
IRQ_TYPE       : 0=level, 1=edge
IRQ_POLARITY   : level active-low/high or edge falling/rising
IRQ_BOTH_EDGE  : edge mode only
IRQ_PENDING    : effective pending view, W1C for sticky edge pending
```

Required system-facing properties include:

- input pins only may generate GPIO IRQs,
- level-mode pending reflects the current synchronized active level,
- edge-mode events are captured into sticky pending state,
- simultaneous edge event and W1C is set-dominant so the new event is preserved,
- direction changes shall not create stale or false edge IRQs,
- `gpio_irq` is active-high and level-sensitive:

```text
gpio_irq = |(GPIO_IRQ_PENDING & GPIO_IRQ_ENABLE)
```

This document deliberately does **not** allocate a PLIC source ID. Source ID, priority, threshold, claim/complete, CPU CSR behavior, and interrupt-entry semantics remain owned by the future PLIC specification.

## 7. Dedicated Switch Peripheral

Target mapping:

```text
SW_BASE  = 0x4008_0000
PSEL[8]
SW[9:0]  -> APB_SW
```

The local switch contract is owned by `sw.md` and includes:

- ten synchronized switch inputs,
- software-visible current state,
- sticky per-switch change pending,
- per-switch IRQ enable,
- set-dominant W1C race handling,
- active-high level `sw_irq`.

Conceptually:

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

The PLIC source ID remains TBD.

## 8. Dedicated LED Peripheral

Target mapping:

```text
LED_BASE   = 0x4009_0000
PSEL[9]
APB_LED -> LEDR[9:0]
```

The local LED contract is owned by `led.md`.

All ten LEDs shall be driven by the dedicated 10-bit output latch. The legacy assignment:

```verilog
assign LEDR[9] = ~HRESETn;
```

shall be removed.

If a reset/debug indicator is desired later, it shall use an explicit debug/board-status mechanism rather than taking ownership of an APB_LED bit.

## 9. Interrupt Architecture Boundary

This board-I/O target exposes two local interrupt-source wires:

```text
gpio_irq
sw_irq
```

They remain local peripheral outputs until the PLIC integration specification is approved and implemented.

This document does not define:

- PLIC MMIO base,
- PLIC source IDs,
- source priorities,
- threshold,
- claim/complete,
- CPU external-interrupt CSR behavior.

LED has no interrupt source.

## 10. Target Address Map

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

`memory_map.md` records the system map. P04 has completed this board-I/O RTL migration; earlier pre-migration diagrams in this document remain historical context.

## 11. Migration Sequence

Recommended cleanup order:

```text
1. Expand APB PSEL[7:0] -> PSEL[15:0].
2. Tighten canonical APB region / slot decode.
3. Expand PRDATA/PREADY muxes to 16 slots.
4. Preserve existing PSEL[0:7] addresses.
5. Replace legacy APB_GPIO behavior at PSEL[1] with the target gpio.md contract.
6. Disconnect SW/LED board signals from GPIO.
7. Add APB_SW at PSEL[8].
8. Add APB_LED at PSEL[9].
9. Route LEDR[9:0] only through APB_LED.
10. Route SW[9:0] only through APB_SW.
11. Expose gpio_irq and sw_irq as local SoC interrupt-source wires.
12. Keep both IRQ wires disconnected from the CPU until approved PLIC integration.
13. Update firmware memory-map constants and drivers.
14. Run directed RTL regression and FPGA board acceptance.
```

The final cleanup state shall contain no conflicting physical ownership of SW, LED, or generic GPIO pins.

## 12. Firmware Migration

Firmware ownership shall change from:

```text
legacy:
  gpio_read()       -> sometimes SW state
  gpio_led_write()  -> LED control
```

to:

```text
target:
  gpio_*()          -> external generic GPIO only
  gpio_irq_*()      -> GPIO interrupt configuration/status
  sw_read()         -> SW state
  sw_irq_*()        -> SW interrupt configuration/status
  led_write()       -> LED control
```

Board diagnostics such as `display_smoke` shall use the dedicated SW/LED drivers and shall no longer treat `GPIO_BASE` as the board switch/LED interface.

## 13. Verification Requirements

### 13.1 APB expansion

Verification shall prove:

- `PSEL[15:0]` width,
- one-hot slot selection for slots 0 through 9,
- reserved/default behavior for slots 10 through 15,
- unchanged addresses for slots 0 through 7,
- correct slot 8/9 `PRDATA` and `PREADY` routing,
- back-to-back accesses across low/high slot numbers,
- removal of unintended higher-address aliases.

### 13.2 GPIO

Verification shall use the finalized target contract in `gpio.md` and cover at minimum:

- parameterized implemented width,
- true input/Hi-Z and output-drive direction behavior,
- output-data preload while input,
- synchronized `GPIO_DATA_IN`,
- level IRQ active-low and active-high behavior,
- rising-edge, falling-edge, and both-edge modes,
- per-pin IRQ enable masking,
- sticky edge pending and W1C,
- event-set dominance over simultaneous W1C,
- live level pending semantics,
- suppression of IRQ generation from output-configured pins,
- direction-change re-arm behavior without false/stale IRQs,
- active-high level `gpio_irq`,
- no physical connection from GPIO to `SW[9:0]` or `LEDR[9:0]`.

### 13.3 SW

Verification shall cover the complete `sw.md` contract: synchronization, initial arm, any-change detection, sticky pending, enable masking, set-dominant W1C, repeated events, and level `sw_irq`.

### 13.4 LED

Verification shall prove reset-zero behavior, all ten output bits, latch readback, and removal of the independent `LEDR[9]` reset driver.

### 13.5 FPGA board acceptance

Board acceptance shall verify:

- all ten switches through `APB_SW`,
- all ten LEDs through `APB_LED`,
- local `sw_irq` behavior before PLIC hookup,
- all frozen JP1 GPIO_0–15 generic GPIO pins as input/output,
- representative GPIO IRQ modes after QSF and physical wiring are validated.

## 14. Cleanup Tracker Items

The canonical `baseline_cleanup.md` now owns the normalized IDs. The historical candidate numbering below is superseded and must not be used as tracker IDs:

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

Use `APB-001/002/004/005` for slot/decode/error work; `BOARDIO-001..006` for GPIO/SW/LED ownership and local wires; `FW-005..007` for drivers; and `VER-005` plus board-acceptance evidence for physical verification. In particular, canonical `BOARDIO-002` is the frozen 16-pin GPIO binding/physical validation item, **not** the historical decoder item above. No duplicate tracker item is created.

## 15. Architectural Invariants

Once this target architecture enters implementation:

1. APB uses `PSEL[15:0]`.
2. Existing slot 0 through 7 base addresses remain unchanged.
3. GPIO remains at `PSEL[1] / 0x4001_0000`.
4. GPIO no longer owns DE10-Lite SW or LED signals.
5. GPIO implements the finalized true-bidirectional + IRQ contract in `gpio.md`.
6. SW is at `PSEL[8] / 0x4008_0000`.
7. LED is at `PSEL[9] / 0x4009_0000`.
8. Slots 10 through 15 remain reserved.
9. `LEDR[9:0]` is owned only by `APB_LED`.
10. `SW[9:0]` is owned only by `APB_SW`.
11. `gpio_irq` and `sw_irq` are active-high local level interrupt-source wires intended for future PLIC connection.
12. This document does not assign PLIC source IDs.
13. Software shall not depend on reserved APB slots or noncanonical aliases.

## 16. Related Specifications

This document shall remain consistent with:

- `01_memory_map.md` — current baseline map plus approved 16-slot target migration,
- `05_apb_subsystem.md` — active P04 16-slot implementation plus pre-cleanup historical record,
- `07_interrupt_architecture.md` — current no-PLIC baseline and future interrupt architecture boundary,
- `11_gpio.md` — authoritative baseline GPIO record **and finalized target GPIO register/IRQ contract**,
- `17_sw.md` — detailed target switch peripheral contract,
- `18_led.md` — detailed target LED peripheral contract,
- future `19_firmware_contract.md`,
- future consolidated `baseline_cleanup.md`,
- future approved PLIC specification.

If a local peripheral specification conflicts with the system-level ownership or slot decisions in this document, the conflict shall be resolved explicitly in `spec/` before RTL implementation proceeds.

## Phase 4A-2 Approved Pin and External-Closure Contract (active pin binding; STA-002 open)

A1 maps `GPIO_IO[0:15]` one-to-one to DE10-Lite JP1 `GPIO_[0:15]`. The ascending package-pin map is `V10,W10,V9,W9,V8,W8,V7,W7,W6,V5,W5,AA15,AA14,W13,W12,AB13`. P04's fresh fit places all 16 as bidirectional 3.3-V LVTTL with per-bit direction/OE inference, without duplicate package ownership or UART/LoRa collision; the user confirms the intended wiring has no physical conflict. JP1 `GPIO_27/29/31/34/35` retain existing UART/LoRa ownership; all other fixed board functions remain reserved. Generic GPIO defaults to input/Hi-Z at reset, DIR=0 input/Hi-Z, DIR=1 output drive, with PCLK 2FF input synchronization and the local IRQ contract in `11_gpio.md`; `gpio_irq` is boundary-only until PLIC.

### Reusable GPIO electrical-use policy

- GPIO is configured as 3.3-V LVTTL. Do not assume 5-V tolerance.
- Do not connect an externally driven output against an FPGA GPIO configured as an output.
- Before output mode, verify the external peer voltage and drive/load compatibility.
- Quartus uses default drive-strength behavior where no explicit per-pin assignment exists. The observed default is not a peer-specific approved rating.
- A future peer-specific electrical requirement may justify an explicit drive strength or additional constraint.
- Peer timing/load characterization, input/output-delay derivation, signal integrity and full external timing closure belong to `STA-002`.

`BOARDIO-002 VERIFIED` means the baseline pin binding, package ownership/no-conflict map, and this electrical-use contract are accepted. It does **not** mean `STA-002` is closed. STA-002 still requires port classification, evidence-based I/O delays or N/A, voltage/drive/load review, unconstrained-port review, ADXL345 timing, ADC/VGA warning analysis and board measurement/risk disposition. Internal positive slack is insufficient for that signoff.
