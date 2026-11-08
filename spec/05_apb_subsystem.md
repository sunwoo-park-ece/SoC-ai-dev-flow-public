# Baseline SoC APB Subsystem Specification

> **P04 closure note (2026-09-15):** The public source routes slots 8/9 to dedicated SW/LED peripherals and retains 10–15 as ERROR. Open directed regression and the user-operated Quartus fit pass; User/Chat approved `APB-001` as `VERIFIED`. Earlier eight-slot, “SW/LED not active,” and pre-fit-pending passages are historical pre-P04 descriptions. Board acceptance remains a separate gate.

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `apb_subsystem.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `cpu_interface.md`, `ahb_fabric.md`.

> **Phase 4A-3A reading rule:** Earlier `PSEL[7:0]`, no-`PSLVERR`, and zero/OKAY passages reconstruct the pre-cleanup baseline. The final Phase 4A-3A APB status paragraph governs bridge/fault behavior at that milestone; P04 subsequently activated SW/LED slots 8/9. A4 UART cleanup remains open.

## Current Legacy contract and assurance boundary

The current bridge has IDLE/SETUP/ACCESS/ERROR_FINAL states, `PSEL[15:0]`, `HSIZE`, global `HREADY_IN` and completing `PSLVERR`. Canonical aligned word requests select slots 0..9; invalid requests select no real peripheral. SETUP holds HREADY low; successful ACCESS completes on PREADY. Address/control remain captured through waits; SETUP PWDATA comes from matching MEM HWDATA and is registered for ACCESS. UART DATA busy writes may deassert PREADY, so the old all-slaves-always-ready statement is historical. Completing PSLVERR or bridge validation failure returns two-cycle ERROR, and ERROR_FINAL accepts no next address. No PSTRB or universal RO/WO error policy is introduced.

Existing requirement/AC IDs and frozen intent are preserved. Pre-cleanup descriptions that conflict with this current contract are historical, not new implementation requirements. Status cites the existing accepted scope in the read-only tracker; this reconciliation does not promote it.

Traceability: [AHB_APB_bridge.v](../rtl/bus/AHB_APB_bridge.v); [AMBA_SoC_TOP.v](../rtl/soc/AMBA_SoC_TOP.v); [tb_ahb_apb_bridge_fault.sv](../verification/directed/bus/tb_ahb_apb_bridge_fault.sv); [tb_p07b_uart_ahb_wait.sv](../verification/directed/uart/tb_p07b_uart_ahb_wait.sv).

## 1. Purpose

This document defines the active APB subsystem behind `AHB_APB_bridge` and records the implemented 16-slot expansion and its historical migration requirements.

It covers:

- AHB-to-APB transaction conversion,
- bridge state-machine timing,
- APB clock/reset relationship,
- current `PSEL[15:0]` slot allocation,
- `PRDATA` / `PREADY` multiplexing,
- read/write completion and wait-state behavior,
- access-width and error limitations,
- historical expansion milestones and separately open acceptance gates.

The active implementation is APB-style and shall not be described as complete AMBA compliance.

## 2. Active Baseline Topology

One AHB→APB master serves the full-production allocation below. The P14 selected fixture exposes only 0,1,2,4,6.

| Slot | Base | Peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | 16-pin true GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM v2 |
| 5 | `0x4005_0000` | ADC v2 / Joystick Policy |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX |
| 8 | `0x4008_0000` | SW |
| 9 | `0x4009_0000` | LED |
| 10..15 | `0x400A_0000..0x400F_0000` | Reserved / ERROR |

## 3. Clock and Reset

```text
PCLK    = HCLK
PRESETn = HRESETn
```

In the baseline both are 50 MHz, so the AHB/APB boundary is protocol conversion, not CDC.

## 4. Bridge Interface

Current interface:

```text
AHB: HADDR[31:0], HWRITE, HTRANS[1:0], HSIZE[2:0], HWDATA[31:0],
     HSEL, HREADY_IN -> HRDATA[31:0], HREADY, HRESP[1:0]
APB: PCLK=HCLK, PRESETn=HRESETn, PADDR[31:0], PWRITE, PENABLE,
     PSEL[15:0], PWDATA[31:0] <- PRDATA[31:0], PREADY, PSLVERR
```
No PSTRB/PPROT is added; the aligned 32-bit MMIO contract remains.

## 5. Request Recognition and State Machine

Accept addresses only with global HREADY_IN && HSEL && HTRANS[1], in IDLE or successful completing ACCESS. Normal sequencing is IDLE→SETUP→ACCESS; PREADY-low retains ACCESS. Invalid requests or completing PSLVERR take ACCESS(first ERROR)→ERROR_FINAL(final ERROR)→IDLE. ERROR_FINAL accepts no next address.

## 6. State Outputs

| State / result | PSEL | PENABLE | HREADY | HRESP |
|---|---|---:|---:|---|
| IDLE | 0 | 0 | 1 | 00 |
| SETUP | valid one-hot or 0 | 0 | 0 | 00 |
| ACCESS, waiting | valid one-hot | 1 | 0 | 00 |
| ACCESS, success | valid one-hot | 1 | 1 | 00 |
| ACCESS, rejected | valid one-hot for completing PSLVERR; 0 for invalid request | 1 | 0 | 01 |
| ERROR_FINAL | 0 | 0 | 1 | 01 |

Always-ready slaves still incur SETUP. Rejected transactions shall have no peripheral side effect.

## 7. Active Baseline Slot Decode

Validate full canonical `addr[31:20]==0x400`, slot `addr[19:16]`, aligned word size and exact offset allowlist together. Reserved slots 10..15, upper aliases and invalid offsets produce ERROR with PSEL=0. Allocation is the current table above.

## 8. Active Baseline Response Multiplexing

PRDATA/PREADY select the response of PSEL[0..9]. Default PRDATA=0/PREADY=1 does not accept a reserved request. UART busy DATA writes can hold PREADY low. Completing G-sensor/ADC PSLVERR reaches the bridge; each slave suppresses effects of its rejected access.

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

## 11. Current PWDATA SETUP / ACCESS

In SETUP, PWDATA is the matching MEM HWDATA; the SETUP-ending edge captures wdata_reg for ACCESS and any waits. Address/control come from the accepted request registers. The former SETUP data gap is historical, not an outstanding implementation defect. This project timing contract does not establish generic APB compliance.

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

The bridge rejects noncanonical addresses before PSEL. UART/Timer/GPIO compare full 16-bit local offsets; AES v2 compares full canonical 32-bit addresses. Direct-APB reserved behavior and upper-slot ownership are separate. Global APB-005 remains IN_PROGRESS; completed sub-scopes do not promote the whole row.

## 16. Historical Approved Expansion — Implemented by P04

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
| 5 | `0x4005_0000` | ADC / Joystick Policy |
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

## 17. Historical Baseline Cleanup Requirements

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

### Historical pre-cleanup baseline

- `PSEL[7:0]` only.
- Eight active slots at `0x4000_0000`–`0x4007_0000`.
- Slot 1 is legacy pseudo-GPIO tied to SW/LED roles.
- No SW or LED dedicated APB peripheral exists.

### Current implemented topology

- `PSEL[15:0]`.
- Existing slot addresses 0–7 unchanged.
- Slot 1 remains GPIO but becomes true bidirectional GPIO.
- Slot 8 = SW at `0x4008_0000`.
- Slot 9 = LED at `0x4009_0000`.
- Slots 10–15 reserved.

The migration above is implemented; separate board/physical and global cleanup requirements retain their tracker status.

## P11 ADC Slot-5 Contract — Implemented / Bounded Acceptance

P11 retains slot 5 at `0x4005_0000` but changes its architectural identity from the historical joystick-owned wrapper to `APB_ADC_Controller`, a generic ADC MMIO slave with an optional `Joystick_Policy` child.

The slot-5 bridge/peripheral contract is:

- naturally aligned 32-bit APB accesses only;
- `PREADY=1` for valid accesses;
- exact full local-offset validation, not `PADDR[7:2]` mirroring;
- bridge allowlist updated through the highest implemented v2 register `+0x64`, admitting only the exact offsets listed in `01_memory_map.md` / `15_adc_joystick.md`;
- CH3..CH6 raw offsets are valid RO reserved-channel addresses and return zero in the baseline;
- CPU address/offset/size/alignment errors are rejected by the bridge before ADC PSEL; local reserved offsets (`+0x50..+0x5C`, `+0x68..+0xFC`), wrong direction and malformed control produce completing `PSLVERR`, propagated as the existing two-cycle AHB ERROR. The local ADC interface has no HSIZE/PSTRB;
- rejected accesses create no command, capture, calibration, counter, or error-clear side effect;
- `CAPTURE` with no new frame is a valid command with OKAY/no-op semantics, not `PSLVERR`.

The ADC completing `PSLVERR` path is implemented in the production response mux. The historical `PRDATA_JOYSTICK` / `JOYSTICK_READY` naming does not change slot ownership. P11 acceptance and the source-observed upper-zero local decode boundary are defined in [15_adc_joystick.md](15_adc_joystick.md); no additional CPU alias, generic rebase support or global APB-005 closure is inferred.

## Phase 4A-2 Approved APB Error and UART Target (APB fault portion active Phase 4A-3A)

A2 requires canonical APB aperture, complete slot and full register-offset validation before any real peripheral side effect. Reserved slots, aliases, invalid offsets and unsupported sizes select an internal/default error responder. `PSLVERR` is meaningful only on a completing ACCESS; the bridge converts it to project two-cycle AHB ERROR (`HRESP=01`, `HREADY=0` then `1`). The pre-cleanup zero/OKAY behavior was an implementation gap closed for this bus fault scope. Under A4, a busy UART_DATA write holds `PREADY=0` until one byte can be accepted exactly once; other UART registers do not stall solely because TX is busy. No UART-specific hardware timeout is introduced. Unsupported/unsafe baud settings must not become active.

**Phase 4A-3A implementation (historical checkpoint):** the bridge/top use `PSEL[15:0]`, validate the full slot/register offset and aligned word access before asserting a real peripheral select, and propagate completing `PSLVERR` as two-cycle AHB ERROR. SETUP request controls are valid and stable through ACCESS, including waits. At that checkpoint slots 8/9 were unimplemented/error; P04 subsequently activated SW/LED at slots 8/9 and verified the complete 16-slot selection behavior. Slots 10–15 remain reserved/error. At that historical checkpoint A4 was pending; the current accepted P07B digital UART busy-write contract is [09_uart.md](09_uart.md). Physical UART-005 remains separate.

## P09B slot-3 contract — paired publication update

> **Current Public integration:** This implementation is current with the paired P09B source/documentation commits. Earlier candidate wording in this section is pre-publication provenance only.

> **Publication synchronization:** Apply this implemented slot-3 contract only with the matching P09B source commit; it does not assert a final Public commit SHA before read-back.

The P09B Public implementation expands only canonical slot 3 to aligned word offsets `+0x00/+0x04/+0x08/+0x0C/+0x10`. The bridge validates the full address, size, alignment and listed offset **before** selecting the wrapper; mirrors and every other offset remain ERROR with no wrapper side effect. The wrapper checks read/write direction and exact SNAP_CTRL command encoding, raises PSLVERR only on completing ACCESS for invalid requests, and otherwise remains zero-wait. Top-level PSLVERR reaches the existing bridge two-cycle AHB ERROR path. An eligible CAPTURE is one command per completed ACCESS; an ineligible but well-encoded CAPTURE is OKAY/no-op. STATUS is read-only and side-effect-free, with pre-edge registered readback on a same-edge sample publication. The exact ABI and priorities are in [12_gsensor.md](12_gsensor.md). No new bus slot, PLIC route or generic SPI aperture is allocated.

The P09B Public implementation uses one common reset: G-sensor controller `iRSTN`, snapshot banks and scheduler use bridge-provided `PRESETn=HRESETn` directly, without the extra local delay. Normal ACCESS/pre-edge read rules apply only while reset is deasserted. Asynchronous assertion can overlap SETUP or ACCESS and abort an unfinished transfer; it must not create an accepted CAPTURE or a guaranteed read response. A read completed before assertion remains a historical completion. No particular response code is promised for reset-aborted traffic.

## P10-HEX slot-7 contract — implementation update

The P10-HEX implementation confirms canonical slot 7 (`0x4007_0000..0x4007_000C`):
- The AHB/APB bridge slot-7 allowlist forwards only the four canonical offsets `+0x00`, `+0x04`, `+0x08`, and `+0x0C` as aligned 32-bit transfers.
- Noncanonical CPU requests to slot 7 are blocked at the bridge without asserting `PSEL[7]` and terminate with 2-cycle AHB ERROR (`HRESP=01`).
- The peripheral slave itself (`APB_HEX_display.v`) implements exact decode on `PADDR[15:0]`. Any unmapped or noncanonical local offset reads zero and ignores writes without side effects (`PREADY=1`, no `PSLVERR`).
- Driver and verification details are defined in [16_hex_display.md](16_hex_display.md) and [19_firmware_contract.md](19_firmware_contract.md).
