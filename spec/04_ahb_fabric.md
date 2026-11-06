# Baseline SoC AHB Fabric Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `ahb_fabric.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`.

> **Current / historical reading rule:** The active structure implements the existing frozen Phase 4A-3A decode/error contract. Former broad decode, silent unmapped OKAY and undriven `HSIZE` are historical pre-cleanup observations. C1a changes only CPU/master combinational structure; no address, latency or exception policy changes here.

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

The three functional targets also have a top-level default ERROR responder for invalid/unmapped transfers. It is not a new software-addressable peripheral.

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

The integrated top-level computes:

```verilog
error_response_final = HREADY && (HRESP == 2'b01);
transfer_valid = HTRANS[1] && !error_response_final;
HSEL_MEM = transfer_valid && size_supported && size_aligned &&
           (HADDR[31:15] == 17'h02000);
HSEL_VRAM = transfer_valid && (HADDR[31:17] == 15'h1000);
HSEL_APB = transfer_valid && (HADDR[31:20] == 12'h400);
HSEL_ERROR = transfer_valid && !(HSEL_MEM || HSEL_VRAM || HSEL_APB);
```

`size_supported` accepts `HSIZE=000/001/010`; `size_aligned` accepts any byte address, an even halfword address, or a word address with low two bits zero, respectively.

| Select | Routing window | Acceptance boundary |
|---|---|---|
| `HSEL_MEM` | `0x1000_0000 - 0x1000_7FFF` | Supported size and alignment; no upper alias |
| `HSEL_VRAM` | `0x2000_0000 - 0x2001_FFFF` | VGA-local full address/size/direction/readiness checks |
| `HSEL_APB` | `0x4000_0000 - 0x400F_FFFF` | Bridge canonical offset/slot/aligned-word checks; slots 10..15 reserved |
| `HSEL_ERROR` | Remaining valid address/size combinations | Two-cycle ERROR, no slave side effect |

A routing aperture does not allocate all bytes to software. Accepted windows/register semantics remain in the [memory map](01_memory_map.md), [VGA](08_vga.md) and [APB](05_apb_subsystem.md) contracts.

### 4.1 Transfer Qualification and Cancellation

Top-level selects include `transfer_valid`; `HTRANS=IDLE` does not select a new owner. Final ERROR cancels the following address at every slave. CPU pre-bus misalignment causes 4/6 remain separate from fabric rejection. C1a predecode and EX eligibility are described in [CPU interface](03_cpu_interface.md#64-integrated-c1a-request-and-alignment-structure).

## 5. Address Phase to Data Phase Selection

`HSEL_MEM_d`, `HSEL_VRAM_d`, `HSEL_APB_d` and `HSEL_ERROR_d` retain the accepted address-phase owner for response routing. Reset clears all four. They capture next selection on `HREADY=1`, except final ERROR clears them and cancels the next address. On `HREADY=0` these owner registers hold.

```text
qualified address selection -> HSEL_{MEM,VRAM,APB,ERROR}_d -> response mux
HSEL_ERROR_d + default_error_final -----------------------> ERROR phase
```

`default_error_final` is separate response-progress state: reset clears it; `HSEL_ERROR_d && !default_error_final` sets it on the next edge even while `HREADY=0`; otherwise `HREADY=1` clears it. This progresses first ERROR to final ERROR. The HREADY-only owner-update rule shall not be generalized to all fabric state.

### 5.1 Wait-State Retention Requirement

While `HREADY=0`, owner selects retain their previous value so `HRDATA`, `HREADY` and `HRESP` remain routed from the completing transaction. They must not follow a newer address during the hold.

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
else if HSEL_ERROR_d -> default_error_final
else                -> 1
```

### 6.3 Response

```text
if HSEL_MEM_d       -> HRESP_MEM
else if HSEL_VRAM_d -> HRESP_VRAM
else if HSEL_APB_d  -> HRESP_APB
else if HSEL_ERROR_d -> 2'b01
else                -> 2'b00
```

The mux priority is physically `MEM > VRAM > APB > ERROR`, but the three top-level address regions are mutually exclusive under the current decode, so priority is not an intended arbitration mechanism.

## 7. Slave Response Characteristics

### 7.1 DMEM

`AHB_MEMORY_SLAVE` currently provides:

```text
HREADY_MEM = 1
HRESP_MEM  = 2'b00
```

The synchronous BRAM is integrated so that no additional AHB wait state is inserted.

### 7.2 VGA / VRAM

Successful supported VGA transfers add no AHB wait (`HREADY_VRAM=1`, `HRESP_VRAM=00`). Rejected access/domain/busy/commit-time conditions instead produce first ERROR (`HREADY_VRAM=0`, `HRESP_VRAM=01`) and final ERROR (`HREADY_VRAM=1`, `HRESP_VRAM=01`).

Address acceptance alone does not authorize a framebuffer write. The slave revalidates the captured owner at commit, suppresses rejected side effects and uses global completion to prevent duplicate writes during holds. [VGA](08_vga.md) owns framebuffer/status/control semantics. This is not CDC or board signoff.

### 7.3 AHB-to-APB Bridge

The bridge has `IDLE`, `SETUP`, `ACCESS` and `ERROR_FINAL` states. SETUP holds ready low even for an always-ready peripheral. A valid successful ACCESS completes with PREADY; otherwise the wait continues. Invalid size/alignment/canonical offset is rejected before real peripheral PSEL. Completed PSLVERR also becomes AHB ERROR.

First ERROR occurs in ACCESS (`HRESP_APB=01`, `HREADY_APB=0`); ERROR_FINAL returns `HRESP_APB=01`, `HREADY_APB=1` and accepts no next address. Successful completion may capture the next address and proceed to SETUP. Matching MEM store data is captured, and APB controls remain stable through waits.

Aligned word accesses use existing canonical offsets in slots 0..9; slots 10..15 are reserved. This adds no APB byte strobes or blanket RO/WO direction-error policy. [APB](05_apb_subsystem.md) owns detailed timing/offset/side-effect semantics.

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

Final ERROR is a completion edge: the CPU consumes the matching MEM fault and cancels younger requests. HRESP/HREADY also connect directly to CPU fault logic outside the master; see [CPU control](21_cpu_core.md#14-pipeline-stall-and-flush-semantics).

There is no transaction retry buffer or independent bus queue. Correctness during a wait state depends on freezing the CPU pipeline and preserving the data-phase slave selection until `HREADY` returns high.

## 9. Unmapped Access Behavior

A transfer owned by `HSEL_ERROR_d` returns `HRDATA=0`, `HRESP=01` in both response cycles, with `HREADY=0` then `HREADY=1`. Final ERROR cancels the next address and no functional slave may commit a side effect for the rejected transfer.

With no data-phase owner, idle mux defaults are instead `HRDATA=0`, `HREADY=1`, `HRESP=00`. These idle values do not acknowledge an unmapped transaction. Historical pre-cleanup unmapped zero/OKAY completion is superseded by the frozen final contract below.

## 10. `HRESP` Limitation

The former CPU-visible error limitation is resolved for the existing load/store fault contract. The combinational `AHB_Master_Interface` still has no `HRESP` input; the SoC connects fabric HRESP/HREADY directly to CPU `HRESP_FROM_AHB`/`HREADY_FROM_AHB`.

Final ERROR belongs to the matching valid MEM load/store owner and generates cause 5/7 with precise faulting PC. Failed effects/retirement and younger requests are suppressed; older successful WB ownership is preserved. Existing pre-bus causes 4/6 retain priority. See [CPU fault boundary](03_cpu_interface.md#15-bus-response--error-visibility). No instruction-fetch fault or new exception policy is defined.

## 11. `HSIZE` Limitation

HSIZE is driven for byte `000`, halfword `001` and word `010`; the master retains invalid `111` and inactive default `010`. C1a independently predecodes load/store size and forwarded-effective-address alignment before request selection, preserving read priority and the existing truth table.

Fabric size/alignment qualifies DMEM selection; APB and VGA validate aligned word accesses. DMEM byte enables still come from CUSTOM_WRITE_MASK_OUT and CPU LoadExtender interprets returned loads. Defined HSIZE and the DMEM-local mask coexist; neither implies generic AHB/AXI strobes or complete AMBA compliance. The former undriven size is historical.

## 12. Physical Decode Aliases

Historical pre-cleanup decode covered 64 KiB DMEM and the entire `0x2xxx_xxxx`/`0x4xxx_xxxx` regions, exposing aliases. Section 4 routing and local validation supersede those observations.

### 12.1 DMEM Alias

`0x1000_8000..0x1000_FFFF` reaches default ERROR, not a second mapping of RAM. Canonical DMEM remains `0x1000_0000..0x1000_7FFF`.

### 12.2 VGA / VRAM Alias

The VGA aperture is locally validated for aligned word framebuffer writes at `0x2000_0000..0x2000_95FF`, status at `0x2001_0000`, and write control at `0x2001_0004`, with existing readiness/direction semantics. Other offsets/sizes or rejected operations produce local ERROR. The aperture is not a mirrored framebuffer allocation.

### 12.3 APB Alias

Only `0x4000_0000..0x400F_FFFF` routes to the bridge, which validates full offset and implemented slot before peripheral selection. Slots 0..9 retain existing register contracts; 10..15 are reserved/error. Higher aliases do not select the bridge. No address allocation or wrong-direction policy changes.

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
- `HSEL_APB_d`, `HSEL_ERROR_d` and `default_error_final` are cleared,
- individual slaves/bridge receive the same active-low system reset according to their integration.

After reset release and before a valid transfer completes its address phase, the idle top-level response path (no valid owner) is therefore selected:

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
Error propagation   : two-cycle ERROR, direct CPU load/store fault path
Byte write control  : project-specific DMEM sideband
```

Defined HSIZE, explicit errors and local validation coexist with the custom DMEM sideband and pipeline coupling. The terms **AHB-style** and **AHB-Lite-derived** remain; full protocol compliance is not claimed.

## 16. Baseline Cleanup Targets Before Major Feature Integration

The following list records historical cleanup requirements, not a claim that the integrated implementation still lacks every mechanism:

1. tighten DMEM decode to the canonical 32 KiB range,
2. tighten VGA/VRAM decode to canonical windows,
3. tighten APB top-level and bridge decode to canonical slots,
4. generate valid `HSIZE` values,
5. define and consume an explicit bus-error/default-slave response,
6. decide whether the top-level `HSEL` decode should be qualified by transfer validity,
7. clean legacy signal naming/width inconsistencies documented in `cpu_interface.md`,
8. add directed verification for unmapped, boundary, back-to-back, and wait-state accesses.

Current mechanisms are described above; [baseline cleanup](baseline_cleanup.md) owns requirement status. This list neither promotes tracker status nor closes naming, physical or other unrelated debt.

## 17. Required Verification Properties

At minimum, verification of the reconstructed baseline fabric shall check:

- each canonical region selects the intended top-level slave,
- no two top-level slaves are selected for the same canonical address,
- data-phase response routing uses the previous accepted address-phase selection,
- `HSEL_*_d` remains stable while `HREADY=0`,
- APB bridge stalls propagate into full CPU pipeline stall,
- DMEM and successful supported VGA transfers add no wait, while rejected VGA transfers use the required ERROR phases,
- consecutive transfers to different slaves return data from the correct data-phase slave,
- pre-cleanup unmapped zero/ready/OKAY behavior is historical; Phase 4A-3A tests require two-cycle ERROR,
- physical alias behavior is not used by canonical firmware tests,
- defined HSIZE/invalid size, alignment, first/final ERROR, physical side-effect suppression and next-address cancellation agree with the owning contracts.

Source-bound composite review supports exercised CPU/SoC/negative cases and finite master decode/alignment checks. This is not universal equivalence, whole-SoC SCC absence, vendor BRAM collision, fitted timing, CDC or board acceptance. Separate targeted compiler-provenance evidence supplements rather than rewrites historical records. See [CPU bounded status](03_cpu_interface.md#72-a2-acceptance-and-bounded-verification-status) and [memory limits](02_memory_subsystem.md#74-bounded-implementation-observations-and-limits). Public derivative packaging remains pending.

## 18. Related Sources

Active implementation sources:

- [Top-level decode/owner/mux](../rtl/soc/AMBA_SoC_TOP.v), [master predecode](../rtl/bus/AHB_MASTER.v), [DMEM edge](../rtl/bus/AHB_MEMORY_SLAVE.v), [APB validation/error](../rtl/bus/AHB_APB_bridge.v), [VGA acceptance/commit](../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v).

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

The active invariants preserve the existing frozen decode/error contract:

1. The CPU is the only active system data-bus master.
2. The three functional targets are DMEM, VGA/VRAM and AHB-to-APB, plus a default ERROR responder.
3. Selection includes transfer validity/final-error cancellation; routing apertures are not software allocations.
4. Owner selects hold on HREADY=0, advance on HREADY=1 and clear on final ERROR. Separate default_error_final progresses first ERROR while ready is low.
5. HRDATA/HREADY/HRESP route from the captured owner, including default ERROR.
6. DMEM and successful supported VGA transfers add no wait; rejected VGA transfers use two-cycle ERROR.
7. APB transactions may stall the CPU through the bridge.
8. Invalid/unmapped transactions produce two-cycle ERROR; ownerless IDLE defaults are not transaction success.
9. Final load/store ERROR reaches the CPU for its matching MEM owner with existing precise cause/PC/failed-effect rules.
10. Historical broad aliases are not supported architectural allocations.
11. Defined HSIZE participates in validation; DMEM byte enables remain the nonstandard matching MEM mask, not write permission.
12. No AHB arbiter, DMA master, PLIC slave, cache or external memory master is introduced.

## Phase 4A-2 Approved Decode/Error Contract (active Phase 4A-3A bus scope)

A2 makes all noncanonical data transactions explicit errors: unmapped addresses, DMEM upper aliases, VGA gaps/aliases or unsupported read/subword/misaligned access, APB aliases, reserved slots, invalid register offsets, and unsupported sizes. Project HRESP remains 2 bits (`00` OKAY, `01` ERROR); the ERROR response is two-cycle (`HREADY=0`, then `HREADY=1`) with ERROR asserted in both cycles. Invalid stores must not commit a slave side effect. A3 permits only naturally aligned 32-bit framebuffer writes; VRAM_STATUS/CONTROL keep their separate semantics. Earlier broad-decode and silent-OKAY descriptions are historical pre-cleanup observations.

**Phase 4A-3A implementation:** top-level address selection is qualified by `HTRANS[1]`, DMEM is limited to `0x1000_0000..0x1000_7FFF`, and default errors cancel the following address phase. The global data-phase select and subordinate address captures hold across APB waits. Directed MEM/APB/VGA/invalid transitions verify response routing and error cancellation; earlier baseline descriptions in this document are historical, not the active cleaned bus behavior.
