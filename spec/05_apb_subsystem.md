# Baseline SoC APB Subsystem Specification

> **P04 closure note (2026-09-15):** The public source routes slots 8/9 to dedicated SW/LED peripherals and retains 10–15 as ERROR. Open directed regression and the user-operated Quartus fit pass; User/Chat approved `APB-001` as `VERIFIED`. Earlier eight-slot, “SW/LED not active,” and pre-fit-pending passages are historical pre-P04 descriptions. Board acceptance remains a separate gate.

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `apb_subsystem.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `cpu_interface.md`, `ahb_fabric.md`.

> **Phase 4A-3A reading rule:** Earlier `PSEL[7:0]`, no-`PSLVERR`, and zero/OKAY passages reconstruct the pre-cleanup baseline. The final Phase 4A-3A APB status paragraph governs bridge/fault behavior at that milestone; P04 subsequently activated SW/LED slots 8/9. A4 UART cleanup remains open.

## 1. Purpose

This document defines the active APB subsystem behind `AHB_APB_bridge` and records the approved target expansion that will be implemented during baseline cleanup.

It covers:

- AHB-to-APB transaction conversion,
- bridge state-machine timing,
- APB clock/reset relationship,
- baseline `PSEL[7:0]` slot allocation,
- `PRDATA` / `PREADY` multiplexing,
- read/write completion and wait-state behavior,
- access-width and error limitations,
- the approved future expansion to `PSEL[15:0]`.

The active implementation is APB-style and shall not be described as complete AMBA compliance.

## 2. Active Baseline Topology

```text
CPU
 |
 v
AHB-style fabric
 |
 v
AHB_APB_bridge
 |
 | PADDR / PWRITE / PSEL[7:0]
 | PENABLE / PWDATA
 v
+------------------------------------------+
| Active APB subsystem                     |
|                                          |
| PSEL[0] UART0 / LoRa                     |
| PSEL[1] legacy GPIO                      |
| PSEL[2] Timer                            |
| PSEL[3] G-sensor                         |
| PSEL[4] AES-GCM                          |
| PSEL[5] ADC Joystick                     |
| PSEL[6] UART1 / PC                       |
| PSEL[7] HEX Display                      |
|                                          |
| PRDATA mux + PREADY mux                  |
+------------------------------------------+
```

There is one APB master: the AHB-to-APB bridge. No APB arbiter or second APB master exists.

## 3. Clock and Reset

```text
PCLK    = HCLK
PRESETn = HRESETn
```

In the baseline both are 50 MHz, so the AHB/APB boundary is protocol conversion, not CDC.

## 4. Bridge Interface

### 4.1 AHB side

Inputs:

```text
HADDR[31:0]
HWRITE
HTRANS[1:0]
HWDATA[31:0]
HSEL
```

Outputs:

```text
HRDATA[31:0]
HREADY
HRESP[1:0] = 2'b00
```

The bridge does not receive `HSIZE`.

### 4.2 APB side

Active baseline signals:

```text
PCLK
PRESETn
PADDR[31:0]
PWRITE
PENABLE
PSEL[7:0]
PWDATA[31:0]
PRDATA[31:0]
PREADY
```

Not implemented:

```text
PSTRB
PSLVERR
PPROT
```

## 5. Request Recognition and State Machine

A request is accepted when:

```text
HSEL = 1
and
HTRANS = NONSEQ or SEQ
```

The bridge uses:

```text
IDLE -> SETUP -> ACCESS
```

Behavior:

```text
IDLE
  valid request -> SETUP

SETUP
  -> ACCESS

ACCESS
  PREADY=0 -> stay ACCESS
  PREADY=1 + next request -> SETUP
  PREADY=1 + no next request -> IDLE
```

## 6. State Outputs

| State | PSEL | PENABLE | AHB HREADY |
|---|---|---|---|
| IDLE | 0 | 0 | 1 |
| SETUP | decoded one-hot | 0 | 0 |
| ACCESS | decoded one-hot | 1 | `PREADY` |

Even an always-ready APB peripheral therefore causes a mandatory SETUP stall from the AHB/CPU perspective.

## 7. Active Baseline Slot Decode

The active bridge checks:

```text
addr[31:28] == 4'h4
```

then uses:

```text
addr[19:16]
```

for slot selection, but only produces `PSEL[7:0]`.

Active canonical slots:

| Slot | Base | Peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | legacy GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM |
| 5 | `0x4005_0000` | ADC Joystick |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX Display |

Address bits `[27:20]` are ignored by the active decoder, so the same selections can alias elsewhere in `0x4xxx_xxxx`. These aliases are non-canonical.

For slot values 8 through 15 the active decoder produces no select.

## 8. Active Baseline Response Multiplexing

### 8.1 PRDATA

```text
PSEL[0] -> PRDATA_UART0
PSEL[1] -> PRDATA_GPIO
PSEL[2] -> PRDATA_TIMER
PSEL[3] -> PRDATA_GSENSOR
PSEL[4] -> PRDATA_AES
PSEL[5] -> PRDATA_JOYSTICK
PSEL[6] -> PRDATA_UART1
PSEL[7] -> PRDATA_HEX
otherwise -> 0
```

### 8.2 PREADY

```text
PSEL[0] -> UART0_READY
PSEL[1] -> GPIO_READY
PSEL[2] -> TIMER_READY
PSEL[3] -> GSENSOR_READY
PSEL[4] -> AES_READY
PSEL[5] -> JOYSTICK_READY
PSEL[6] -> UART1_READY
PSEL[7] -> HEX_READY
otherwise -> 1
```

All active baseline APB slaves currently use `PREADY=1`.

## 9. Read Transaction

Conceptually:

```text
AHB load accepted
 -> SETUP: PSEL active, HREADY=0
 -> ACCESS: PENABLE=1
 -> selected slave supplies PRDATA/PREADY
 -> PREADY=1 completes AHB load
```

## 10. Write Transaction

Conceptually:

```text
AHB store accepted
 -> SETUP
 -> bridge captures HWDATA into PWDATA at SETUP-ending edge
 -> ACCESS
 -> slave commits write on PSEL && PENABLE && PWRITE
 -> PREADY=1 completes transfer
```

## 11. PWDATA Setup-Phase Deviation

The active bridge does not guarantee the new write data throughout the complete SETUP phase. Correct `PWDATA` is guaranteed in ACCESS because it is registered at the edge ending SETUP.

Current slaves work because they commit only in ACCESS, but this is a protocol-quality gap and shall be corrected during cleanup before claiming generic APB compliance.

## 12. Back-to-Back Transfers

The bridge structurally supports:

```text
ACCESS(current) -> SETUP(next)
```

without an intervening IDLE cycle when the current transfer completes and another valid AHB request is present.

Directed regression shall cover read/read, write/write, read/write, and cross-slot back-to-back transactions.

## 13. Access Width Policy

The pre-cleanup bridge had no `HSIZE` input. Phase 4A-3A added `HSIZE` validation but no `PSTRB` output. Therefore the normative peripheral MMIO contract remains:

> Use naturally aligned 32-bit reads and writes unless a peripheral specification explicitly defines and verifies another access form.

`SB` / `SH` shall not be assumed to provide safe generic APB byte/halfword semantics.

## 14. Error Handling

Before Phase 4A-3A, the APB subsystem had no `PSLVERR` path, bridge `HRESP` was always OKAY, and the CPU did not consume it. The active bridge now accepts completing `PSLVERR`, handles internal invalid requests, and returns two-cycle AHB ERROR to the CPU.

Invalid/unmapped APB accesses now error before any real peripheral select or side effect. The former zero-read/discarded-write behavior was a pre-cleanup limitation, not an architectural feature.

## 15. Peripheral Register Mirroring

Many active peripherals decode only a small subset of low `PADDR` bits, so registers can physically mirror inside a 64-KiB slot. Only exact offsets defined by `memory_map.md` and the peripheral spec are canonical.

## 16. Approved Target Expansion — Not Yet Active

> **HISTORICAL PHASE 4A-3A MIGRATION NOTE:** Phase 4A-3A widened bridge/top selection to `PSEL[15:0]`, while slots 8/9 still errored until P04. P04 now routes slots 8/9 to SW/LED; 10–15 remain reserved/error.

Target interface:

```text
PSEL[15:0]
```

Approved target allocation:

| Slot | Base | Target peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | true bidirectional GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM |
| 5 | `0x4005_0000` | ADC Joystick |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX Display |
| 8 | `0x4008_0000` | SW |
| 9 | `0x4009_0000` | LED |
| 10–15 | `0x400A_0000` – `0x400F_0000` | Reserved |

Existing addresses 0 through 7 shall not move.

### 16.1 Target decoder requirement

The target decoder shall cleanly represent the complete 4-bit slot field:

```text
slot = PADDR[19:16]
PSEL = one-hot 16-bit select
```

only for accesses inside the approved canonical APB region.

The current aliasing caused by insufficient higher-address qualification shall be removed as part of the same cleanup.

### 16.2 Target response mux requirement

The top-level response path shall widen consistently to 16 slots:

```text
PRDATA mux  : PSEL[15:0]
PREADY mux  : PSEL[15:0]
```

Slots 8 and 9 shall route SW and LED response channels. Slots 10 through 15 shall return the frozen A2 default-slave error rather than silently inheriting baseline zero/OKAY behavior.

### 16.3 GPIO / SW / LED relationship

The target board-I/O architecture is:

```text
PSEL[1] -> APB_GPIO -> true bidirectional external GPIO + gpio_irq
PSEL[8] -> APB_SW   -> SW[9:0] + sw_irq
PSEL[9] -> APB_LED  -> LEDR[9:0]
```

The existing GPIO slot is retained; only its board-specific SW/LED wiring is removed.

PLIC source IDs are not defined here.

## 17. Baseline Cleanup Requirements

The consolidated cleanup pass shall include at minimum:

1. widen `PSEL[7:0]` to `PSEL[15:0]`,
2. widen top-level PRDATA/PREADY muxes,
3. tighten canonical APB-region decoding and remove higher-address aliases,
4. correct PWDATA setup timing,
5. implement the frozen A2 reserved/default-slot error behavior,
6. preserve existing slots 0 through 7,
7. add SW at slot 8 and LED at slot 9,
8. redesign GPIO at slot 1 without removing the slot,
9. update firmware memory-map constants/drivers,
10. run cross-slot/back-to-back regression and FPGA acceptance.

Detailed board-I/O sequencing is owned by `board_io_architecture.md`.

## 18. Baseline vs Target Invariants

### Active baseline

- `PSEL[7:0]` only.
- Eight active slots at `0x4000_0000`–`0x4007_0000`.
- Slot 1 is legacy pseudo-GPIO tied to SW/LED roles.
- No SW or LED dedicated APB peripheral exists.

### Approved target

- `PSEL[15:0]`.
- Existing slot addresses 0–7 unchanged.
- Slot 1 remains GPIO but becomes true bidirectional GPIO.
- Slot 8 = SW at `0x4008_0000`.
- Slot 9 = LED at `0x4009_0000`.
- Slots 10–15 reserved.

The target section is a migration contract until the corresponding RTL and verification are complete.

## Phase 4A-2 Approved APB Error and UART Target (APB fault portion active Phase 4A-3A)

A2 requires canonical APB aperture, complete slot and full register-offset validation before any real peripheral side effect. Reserved slots, aliases, invalid offsets and unsupported sizes select an internal/default error responder. `PSLVERR` is meaningful only on a completing ACCESS; the bridge converts it to project two-cycle AHB ERROR (`HRESP=01`, `HREADY=0` then `1`). The pre-cleanup zero/OKAY behavior was an implementation gap closed for this bus fault scope. Under A4, a busy UART_DATA write holds `PREADY=0` until one byte can be accepted exactly once; other UART registers do not stall solely because TX is busy. No UART-specific hardware timeout is introduced. Unsupported/unsafe baud settings must not become active.

**Phase 4A-3A implementation (historical checkpoint):** the bridge/top use `PSEL[15:0]`, validate the full slot/register offset and aligned word access before asserting a real peripheral select, and propagate completing `PSLVERR` as two-cycle AHB ERROR. SETUP request controls are valid and stable through ACCESS, including waits. At that checkpoint slots 8/9 were unimplemented/error; P04 subsequently activated SW/LED at slots 8/9 and verified the complete 16-slot selection behavior. Slots 10–15 remain reserved/error. A4 UART busy-write behavior remains cleanup work.
