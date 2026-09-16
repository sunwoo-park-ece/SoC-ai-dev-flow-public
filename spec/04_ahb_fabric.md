# Baseline SoC AHB Fabric Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `ahb_fabric.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`.

> **Phase 4A-3A reading rule:** Earlier broad-decode/zero-OKAY and undriven-`HSIZE` passages reconstruct the pre-cleanup baseline. The final Phase 4A-3A section supersedes those passages for active bus fault, decode, and response behavior; other future features are unchanged.

## 1. Purpose

This document defines the active baseline SoC data interconnect between the CPU-side `AHB_Master_Interface` and the three top-level AHB-side targets:

1. DMEM
2. VGA / dual-VRAM subsystem
3. AHB-to-APB bridge

It specifies top-level slave selection, address-phase to data-phase selection retention, response multiplexing, back-pressure propagation, unmapped-access behavior, and the implementation gaps that shall not be promoted into future architectural contracts.

This document describes the **implemented AHB-style / AHB-Lite-derived baseline**, not a claim of full AMBA AHB-Lite compliance. CPU-side pipeline mapping is defined in `cpu_interface.md`; the APB bridge and peripheral slot behavior are refined in `apb_subsystem.md`.

## 2. Fabric Topology

The baseline has exactly one system data-bus master.

```text
                       RV32I CPU
                           |
                           v
                 AHB_Master_Interface
                           |
              single-master AHB-style bus
                           |
          +----------------+----------------+
          |                |                |
          v                v                v
        DMEM          VGA / VRAM       AHB -> APB
   AHB_MEMORY_SLAVE  AHB_VRAM_DUAL_     bridge
                       BUFFER              |
                                           v
                                      APB subsystem
```

Baseline topology properties:

- The CPU is the only AHB-side master.
- No bus arbiter is required in the baseline.
- No DMA master is present.
- No PLIC slave is present in the active FPGA baseline.
- No burst-capable system master exists in the baseline.
- Each CPU load/store is issued as an independent `NONSEQ` transfer.

Future AXI/DMA/PLIC integration shall not be inferred from legacy snapshots or roadmap text.

## 3. Top-Level AHB Signals

The active top-level fabric carries:

| Signal | Width | Direction relative to CPU master | Baseline role |
|---|---:|---|---|
| `HADDR` | 32 | master -> fabric/slaves | Byte address |
| `HWRITE` | 1 | master -> fabric/slaves | Read/write direction |
| `HTRANS` | 2 | master -> fabric/slaves | `IDLE` or `NONSEQ` in active CPU master |
| `HSIZE` | 3 | master -> fabric/slaves | Phase 4A-3A drives byte/halfword/word size; pre-cleanup source left it undriven |
| `HBURST` | 3 | master -> fabric | Constant single transfer in active master |
| `HWDATA` | 32 | master -> slaves | Write data, aligned to the data phase |
| `HRDATA` | 32 | fabric -> master | Selected slave read data |
| `HREADY` | 1 | fabric -> master | Selected data-phase completion / back-pressure |
| `HRESP` | 2 | fabric -> CPU | Phase 4A-3A final ERROR is consumed for load/store access faults |

Project-specific DMEM sidebands such as `CUSTOM_WRITE_MASK_OUT` and `BRAM_HAZARD` are not general fabric signals. They are direct CPU/DMEM integration signals and are specified in `cpu_interface.md` and `memory_subsystem.md`.

## 4. Address-Phase Slave Decode

The active top-level decode is purely combinational from `HADDR`:

```verilog
HSEL_MEM  = (HADDR[31:16] == 16'h1000);
HSEL_VRAM = (HADDR[31:28] == 4'h2);
HSEL_APB  = (HADDR[31:28] == 4'h4);
```

Therefore the physical decode windows are:

| Select | RTL physical decode | Canonical architectural use |
|---|---|---|
| `HSEL_MEM` | `0x1000_0000 - 0x1000_FFFF` | DMEM only at `0x1000_0000 - 0x1000_7FFF` |
| `HSEL_VRAM` | `0x2000_0000 - 0x2FFF_FFFF` | Canonical VGA/VRAM windows defined by `memory_map.md` |
| `HSEL_APB` | `0x4000_0000 - 0x4FFF_FFFF` | Canonical APB slots `0x4000_xxxx - 0x4007_xxxx` |

The canonical software-visible address map is defined only by `memory_map.md`. Broad physical decode shall not be interpreted as allocating the entire physical decode window to software.

### 4.1 Decode Is Not Qualified by `HTRANS`

`HSEL_MEM`, `HSEL_VRAM`, and `HSEL_APB` depend only on address bits. They are not gated with `HTRANS` at the top level.

Consequently:

- the top-level select may indicate an address region even while `HTRANS=IDLE`,
- transfer validity is checked inside each slave or bridge,
- response data during an invalid/idle transfer is not architecturally meaningful.

Future cleanup may qualify selection with a valid transfer predicate, but the active baseline does not.

## 5. Address Phase to Data Phase Selection

AHB uses a pipelined address/data relationship. The top-level therefore stores the address-phase slave selection for use during the following data phase:

```text
Address phase                    Data phase
-------------                    ----------
HADDR -> HSEL_MEM  -----------+-> HSEL_MEM_d
HADDR -> HSEL_VRAM -----------+-> HSEL_VRAM_d
HADDR -> HSEL_APB  -----------+-> HSEL_APB_d
```

The active registers are:

```verilog
HSEL_MEM_d
HSEL_VRAM_d
HSEL_APB_d
```

They reset to zero and are updated only when the current system `HREADY` is high.

Conceptually:

```verilog
if (!HRESETn) begin
    HSEL_MEM_d  <= 0;
    HSEL_VRAM_d <= 0;
    HSEL_APB_d  <= 0;
end else if (HREADY) begin
    HSEL_MEM_d  <= HSEL_MEM;
    HSEL_VRAM_d <= HSEL_VRAM;
    HSEL_APB_d  <= HSEL_APB;
end
```

### 5.1 Wait-State Retention Requirement

When `HREADY=0`, the data-phase select registers shall retain their previous value.

This is required because the slave currently completing the data phase must remain selected for:

- `HRDATA`
- `HREADY`
- `HRESP`

until that transfer completes.

If the data-phase select were allowed to follow a newer address while the current transfer was stalled, response routing could switch to the wrong slave.

## 6. Data-Phase Response Multiplexing

The top-level response mux uses only the delayed data-phase selects.

### 6.1 Read Data

```text
if HSEL_MEM_d       -> HRDATA_MEM
else if HSEL_VRAM_d -> HRDATA_VRAM
else if HSEL_APB_d  -> HRDATA_APB
else                -> 0x0000_0000
```

### 6.2 Ready / Back-Pressure

```text
if HSEL_MEM_d       -> HREADY_MEM
else if HSEL_VRAM_d -> HREADY_VRAM
else if HSEL_APB_d  -> HREADY_APB
else                -> 1
```

### 6.3 Response

```text
if HSEL_MEM_d       -> HRESP_MEM
else if HSEL_VRAM_d -> HRESP_VRAM
else if HSEL_APB_d  -> HRESP_APB
else                -> 2'b00
```

The mux priority is physically `MEM > VRAM > APB`, but the three top-level address regions are mutually exclusive under the current decode, so priority is not an intended arbitration mechanism.

## 7. Slave Response Characteristics

### 7.1 DMEM

`AHB_MEMORY_SLAVE` currently provides:

```text
HREADY_MEM = 1
HRESP_MEM  = 2'b00
```

The synchronous BRAM is integrated so that no additional AHB wait state is inserted.

### 7.2 VGA / VRAM

`AHB_VRAM_DUAL_BUFFER` currently provides:

```text
HREADY_VRAM = 1
HRESP_VRAM  = 2'b00
```

The VGA subsystem is therefore a zero-wait AHB-side target from the CPU bus perspective, even though it contains a separate VGA pixel-clock domain internally.

### 7.3 AHB-to-APB Bridge

The APB path may deassert `HREADY_APB`.

The bridge states are:

```text
IDLE -> SETUP -> ACCESS
```

At the AHB side:

- `IDLE`: `HREADY_APB = 1`
- `SETUP`: `HREADY_APB = 0`
- `ACCESS`: `HREADY_APB = PREADY`

Therefore an APB transaction introduces bridge-controlled back-pressure even when the selected APB peripheral itself keeps `PREADY=1`.

The CPU observes the resulting top-level `HREADY=0` as `bus_stall_req=1` and freezes the complete pipeline as defined in `cpu_interface.md`.

Detailed APB timing is owned by `apb_subsystem.md`.

## 8. Back-Pressure Propagation

The baseline back-pressure chain is:

```text
selected slave / APB bridge
        |
        v
     HREADY_x
        |
        v
 top-level HREADY mux
        |
        v
 AHB_Master_Interface
        |
 bus_stall_req = ~HREADY
        |
        v
    HazardUnit
        |
        v
freeze IF/ID, ID/EX, EX/MEM, MEM/WB
```

There is no transaction retry buffer or independent bus queue. Correctness during a wait state depends on freezing the CPU pipeline and preserving the data-phase slave selection until `HREADY` returns high.

## 9. Unmapped Access Behavior

If none of the delayed selects is active, the current top-level returns:

```text
HRDATA = 0x0000_0000
HREADY = 1
HRESP  = 2'b00
```

Thus an access that reaches no recognized top-level slave completes silently rather than reporting a bus error.

Architectural consequences:

- unmapped reads may appear to return zero,
- unmapped writes are effectively discarded,
- the active CPU cannot distinguish this from a successful transaction,
- software shall not use this behavior as a feature.

Frozen A2 requires explicit default-slave/error behavior before strict access-fault semantics can be claimed; current RTL does not yet implement it.

## 10. `HRESP` Limitation

All three active top-level AHB-side targets currently return `2'b00` (`OKAY`). In addition, the active `AHB_Master_Interface` does not consume `HRESP` at all.

Therefore the baseline provides **no CPU-visible bus-error path**.

This is an implementation limitation, not the approved cleanup target. Frozen A2 makes data-bus faults synchronous CPU load/store access-fault exceptions; future AXI replacement remains a separate architecture stage.

## 11. `HSIZE` Limitation

The top-level distributes `HSIZE` to the DMEM slave, but the active CPU master currently declares `HSIZE` without driving it.

Current functionality survives because:

- DMEM store byte lanes are controlled through `CUSTOM_WRITE_MASK_OUT`,
- DMEM load extraction is performed inside the CPU,
- the APB bridge does not consume `HSIZE`,
- the VGA slave does not consume `HSIZE`.

Consequently, no baseline slave behavior shall depend on `HSIZE`.

Before the interconnect is treated as a clean standard AHB-Lite implementation, `HSIZE` generation shall be repaired and verified for byte, halfword, and word accesses.

## 12. Physical Decode Aliases

The active fabric contains broad decode that creates physical aliases beyond the canonical map.

### 12.1 DMEM Alias

Top-level decode selects 64 KiB at `0x1000_xxxx`, while the physical DMEM contains only 32 KiB and indexes `HADDR[14:2]`.

Therefore the upper half of the physical decode can alias the lower 32 KiB.

Only `0x1000_0000 - 0x1000_7FFF` is architectural.

### 12.2 VGA / VRAM Alias

The top-level selects the entire `0x2xxx_xxxx` region, while the VGA subsystem decodes only lower address bits for its framebuffer and control/status windows.

Repeated/mirrored behavior outside the canonical VGA windows is not architectural.

### 12.3 APB Alias

The top-level selects the entire `0x4xxx_xxxx` region. The AHB-to-APB bridge then chooses one of eight peripherals primarily from `addr[19:16]`, so the canonical APB slot pattern may repeat for addresses that differ in ignored upper-middle bits.

Only the canonical `0x4000_xxxx - 0x4007_xxxx` slots are supported software addresses.

## 13. Arbitration

There is no AHB arbitration logic in the baseline because there is only one master.

```text
Number of system data masters = 1
Arbiter required               = no
```

This shall change when a DMA engine or another bus master is introduced. The roadmap's future AXI fabric must define arbitration independently rather than retrofitting multi-master arbitration into this baseline AHB fabric without a specification update.

## 14. Reset Behavior

On `HRESETn=0`:

- `HSEL_MEM_d` is cleared,
- `HSEL_VRAM_d` is cleared,
- `HSEL_APB_d` is cleared,
- individual slaves/bridge receive the same active-low system reset according to their integration.

After reset release and before a valid transfer completes its address phase, the default top-level response path is therefore selected:

```text
HRDATA = 0
HREADY = 1
HRESP  = OKAY
```

Clock/reset generation and CDC requirements are owned by `reset_clock.md`.

## 15. Baseline Protocol Scope

The active fabric supports the following implemented subset:

```text
Master count       : 1
Address width       : 32 bits
Data width          : 32 bits
Transfer type       : IDLE / NONSEQ from active CPU master
Burst mode          : single transfer only
Back-pressure       : HREADY
Response routing    : delayed HSEL-based mux
Error propagation   : not CPU-visible
Byte write control  : project-specific DMEM sideband
```

Because of the undriven `HSIZE`, ignored `HRESP`, custom DMEM sideband, and broad non-canonical decode, this document intentionally uses the terms **AHB-style** and **AHB-Lite-derived** rather than claiming full protocol compliance.

## 16. Baseline Cleanup Targets Before Major Feature Integration

The following issues are intentionally recorded for a dedicated baseline-cleanup pass after specification reconstruction and before PLIC/AXI implementation begins:

1. tighten DMEM decode to the canonical 32 KiB range,
2. tighten VGA/VRAM decode to canonical windows,
3. tighten APB top-level and bridge decode to canonical slots,
4. generate valid `HSIZE` values,
5. define and consume an explicit bus-error/default-slave response,
6. decide whether the top-level `HSEL` decode should be qualified by transfer validity,
7. clean legacy signal naming/width inconsistencies documented in `cpu_interface.md`,
8. add directed verification for unmapped, boundary, back-to-back, and wait-state accesses.

These are **cleanup requirements**, not descriptions of behavior already implemented.

## 17. Required Verification Properties

At minimum, verification of the reconstructed baseline fabric shall check:

- each canonical region selects the intended top-level slave,
- no two top-level slaves are selected for the same canonical address,
- data-phase response routing uses the previous accepted address-phase selection,
- `HSEL_*_d` remains stable while `HREADY=0`,
- APB bridge stalls propagate into full CPU pipeline stall,
- DMEM and VGA zero-wait responses do not introduce extra bus stalls,
- consecutive transfers to different slaves return data from the correct data-phase slave,
- pre-cleanup unmapped zero/ready/OKAY behavior is historical; Phase 4A-3A tests require two-cycle ERROR,
- physical alias behavior is not used by canonical firmware tests,
- future cleanup tests detect any remaining dependence on undefined `HSIZE`.

## 18. Related Sources

Active implementation sources:

- `rtl/soc/AMBA_SoC_TOP.v`
- `rtl/bus/AHB_MASTER.v`
- `rtl/bus/AHB_MEMORY_SLAVE.v`
- `rtl/bus/AHB_APB_bridge.v`
- `rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v`

Related specifications:

- `soc_architecture.md`
- `memory_map.md`
- `memory_subsystem.md`
- `cpu_interface.md`
- `apb_subsystem.md`
- `reset_clock.md`

Legacy PLIC snapshots under `verification/legacy/` are not authoritative for the active fabric.

## 19. Baseline Fabric Invariants

Unless a later approved specification explicitly changes them, the reconstructed baseline contract is:

1. The CPU is the only active system data-bus master.
2. The active fabric has three top-level targets: DMEM, VGA/VRAM, and AHB-to-APB.
3. Address-phase slave selection is derived from `HADDR` and retained into the data phase.
4. Data-phase select state advances only when `HREADY=1`.
5. `HRDATA`, `HREADY`, and `HRESP` are multiplexed using delayed slave selects.
6. DMEM and VGA/VRAM are zero-wait AHB-side slaves.
7. APB transactions may stall the CPU through the bridge.
8. Unmapped accesses currently complete with zero data, ready high, and OKAY response.
9. No CPU-visible bus-error mechanism exists in the baseline.
10. Broad physical decode aliases are implementation artifacts, not architectural address allocations.
11. `HSIZE` is not currently a reliable signal and shall not be required by baseline slave behavior.
12. No AHB arbiter, DMA master, PLIC slave, cache, or external memory master is part of this baseline fabric.

## Phase 4A-2 Approved Decode/Error Contract (active Phase 4A-3A bus scope)

A2 makes all noncanonical data transactions explicit errors: unmapped addresses, DMEM upper aliases, VGA gaps/aliases or unsupported read/subword/misaligned access, APB aliases, reserved slots, invalid register offsets, and unsupported sizes. Project HRESP remains 2 bits (`00` OKAY, `01` ERROR); the ERROR response is two-cycle (`HREADY=0`, then `HREADY=1`) with ERROR asserted in both cycles. Invalid stores must not commit a slave side effect. A3 permits only naturally aligned 32-bit framebuffer writes; VRAM_STATUS/CONTROL keep their separate semantics. Earlier broad-decode and silent-OKAY descriptions are historical pre-cleanup observations.

**Phase 4A-3A implementation:** top-level address selection is qualified by `HTRANS[1]`, DMEM is limited to `0x1000_0000..0x1000_7FFF`, and default errors cancel the following address phase. The global data-phase select and subordinate address captures hold across APB waits. Directed MEM/APB/VGA/invalid transitions verify response routing and error cancellation; earlier baseline descriptions in this document are historical, not the active cleaned bus behavior.
