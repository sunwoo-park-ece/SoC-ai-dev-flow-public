# Baseline SoC CPU Interface Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `cpu_interface.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`.

> **Phase 4A-3A reading rule:** Earlier “current baseline” descriptions of undriven `HSIZE` and unconsumed `HRESP` are pre-cleanup observations. The final Phase 4A-3A data-bus fault contract states the implemented scope; unrelated CPU cleanup remains open.

> **Store payload/mask contract status:** Section 7.1 remains the approved A2 contract. The integrated CPU implements its response-independent MEM payload/mask path; Section 7.2 records bounded structural/simulation support and remaining limits. Historical observations do not override newer frozen fault contracts. C1a's actual combinational changes are described in Section 6.4 and [CPU structure](21_cpu_core.md#203-integrated-c1a-structure-and-preserved-ownership).

## 1. Purpose

This document defines the architectural boundary between the active RV32I 5-stage CPU and the SoC data interconnect. It specifies how CPU pipeline state maps onto the implemented AHB-style bus signals, how load/store data is transferred, how bus back-pressure freezes the pipeline, and which project-specific sideband signals are required by the baseline implementation.

This document describes the **implemented baseline contract**, not a claim of full AMBA AHB-Lite compliance. The active interface is AHB-Lite-derived/AHB-style and omits or repurposes parts of a complete standard interface. System slave decode and response muxing are defined in `ahb_fabric.md`; memory-internal behavior is defined in `memory_subsystem.md`.

## 2. Active Boundary

The data-side CPU/bus boundary is formed by:

```text
RV32I46F5SPMMIO
        |
        | EX-stage address/control
        | MEM-stage store data / byte mask
        | load data / bus stall return
        v
AHB_Master_Interface
        |
        v
SoC AHB-style fabric
```

The active `AHB_Master_Interface` is combinational pipeline-to-bus mapping logic. The older FSM-style `AHB_MASTER` source remains commented out in `rtl/bus/AHB_MASTER.v` and is **not** part of the active architecture.

There is no request queue, transaction buffer, outstanding-transaction table, reorder logic, or separate CPU-side ready/valid protocol in the baseline.

## 3. Pipeline-to-Bus Phase Mapping

The baseline deliberately aligns the CPU pipeline with the pipelined AHB address/data relationship.

```text
CPU stage       Bus role
---------       -----------------------------------------
EX              Address/control phase
MEM             Data phase / load result consumption
```

For a load/store instruction:

```text
Cycle N / EX
    alu_result       -> HADDR
    memory_read/write-> HTRANS / HWRITE

Clock edge
    instruction advances EX -> MEM when not stalled

Cycle N+1 / MEM
    store-aligned data -> HWDATA
    load HRDATA        -> LoadExtender
```

The CPU pipeline register between EX and MEM therefore supplies the one-cycle phase relationship needed by the bus. The active master interface does not insert an additional address/data pipeline register.

## 4. CPU-to-Master Signals

The active CPU exposes the following data-side signals to `AHB_Master_Interface`.

| CPU signal | Logical width | Producer stage | Purpose |
|---|---:|---|---|
| `EX_memory_read_AHB` | 1 | EX | Read transaction request |
| `EX_memory_write_AHB` | 1 | EX | Write transaction request |
| `EX_alu_result_AHB` | 32 | EX | Byte address for `HADDR` |
| `EX_funct3_AHB` | 3 effective bits | EX | Access-type metadata; intended transfer-size input |
| `MEM_store_data_AHB` | 32 | MEM | Aligned store write data presented to the master as `MEM_read_data2` |
| `CUSTOM_WRITE_MASK` | 4 | MEM | Store byte-lane enable from `StoreAligner` |
| `oBRAM_HAZARD` | 1 | EX/MEM relation | Same-word store-to-load BRAM RAW hazard indication |

### 4.1 Store-Data Naming

`MEM_store_data_AHB` is not load read data in the active implementation. The CPU assigns it from `data_memory_write_data`, and the top connects it to the master's `MEM_read_data2` input, which becomes `HWDATA`.

P14 renamed the imported baseline `data_memory_read_data_AHB` to `MEM_store_data_AHB`. This is a naming cleanup; EX-address/MEM-data ownership, pipeline behavior and the master's `MEM_read_data2` input are unchanged.

### 4.2 `EX_funct3_AHB` Width Quirk

Before Phase 4A-3A, the CPU module declared `EX_funct3_AHB` as a 32-bit output even though it was assigned from the 3-bit `EX_funct3`. The SoC top and master used 3 bits. Phase 4A-3A normalized the CPU port to 3 bits.

The architectural information width is **3 bits**; the former 32-bit declaration was a source-level width mismatch, not part of the intended interface contract.

## 5. Implemented Bus Signals

The active master presents the following SoC-side signals.

| Signal | Width | Baseline behavior |
|---|---:|---|
| `HADDR` | 32 | Directly driven by EX-stage ALU result |
| `HWRITE` | 1 | `1` for EX-stage store, `0` otherwise |
| `HTRANS` | 2 | `NONSEQ (2'b10)` for valid aligned load/store bus transfers; `IDLE (2'b00)` otherwise, including pre-bus misalignment |
| `HSIZE` | 3 | Pre-cleanup: undriven. Phase 4A-3A: deterministic byte/halfword/word size. |
| `HBURST` | 3 | Constant `3'b000` — single transfer |
| `HWDATA` | 32 | MEM-stage aligned store data |
| `HRDATA` | 32 | Fabric read data returned directly to CPU load path |
| `HREADY` | 1 | Fabric completion/back-pressure input |
| `HRESP` | 2 | Phase 4A-3A CPU consumes final ERROR for load/store access faults. |

The baseline generates no burst sequence and no `BUSY` or `SEQ` transfer type. Each CPU load/store is represented as an independent single `NONSEQ` transfer.

## 6. Address Phase Contract

### 6.1 Read

For an EX-stage load:

```text
EX_memory_read_AHB  = 1
EX_memory_write_AHB = 0
HADDR               = EX effective byte address
HWRITE              = 0
HTRANS               = NONSEQ
HBURST               = SINGLE
```

### 6.2 Write

For an EX-stage store:

```text
EX_memory_read_AHB  = 0
EX_memory_write_AHB = 1
HADDR               = EX effective byte address
HWRITE              = 1
HTRANS               = NONSEQ
HBURST               = SINGLE
```

### 6.3 No Memory Operation

When neither load nor store is in EX:

```text
HTRANS = IDLE
```

`HADDR` may still reflect the current EX ALU result. Slaves/fabric shall qualify address interpretation with a valid transfer indication rather than treating every `HADDR` value as a transaction.

### 6.4 Integrated C1a request and alignment structure

The CPU top forms each exported request as:

```text
EX_memory_{read,write}_AHB = EX_valid && EX_memory_{read,write}
                            && !EX_exc_valid && !EX_fault_raw && !mem_fault_now
ex_fault_now = EX_valid && !EX_exc_valid && EX_fault_raw && !mem_fault_now
mem_fault_now = bus_fault_final
```

Before C1a the request used `!ex_fault_now` instead of `!EX_fault_raw`. Under the existing outer valid/exception/final-fault guards these expressions are logically equivalent for Boolean inputs. The intermediate response-qualified predicate is removed from request eligibility, not from exception sequencing. `!mem_fault_now` still cancels younger EX requests on final MEM ERROR. This Boolean explanation does not assert all possible X-state equivalence.

The master independently predecodes funct3 into `load_size`/`store_size` and `load_aligned`/`store_aligned` from the **existing** effective address, including low-bit carry. Previously request selection generated `HSIZE`, which fed `ex_address_aligned` before `HTRANS`. The integrated structure selects the appropriate predecoded alignment last; no new address adder, queue, pipeline register or latency is added.

| Selection | `HSIZE` | Alignment condition for `HTRANS=NONSEQ` |
|---|---|---|
| Read funct3 `000/100` | `000` | any byte offset |
| Read funct3 `001/101` | `001` | address[0]=0 |
| Read funct3 `010` | `010` | address[1:0]=00 |
| Write funct3 `000` | `000` | any byte offset |
| Write funct3 `001` | `001` | address[0]=0 |
| Write funct3 `010` | `010` | address[1:0]=00 |
| Selected unsupported funct3 | `111` | master alignment predicate is true; invalid size is retained for rejection, not converted to a legal word |
| Neither request | `010` | `HTRANS=IDLE` |

Read has priority for size/alignment selection if both request inputs are asserted; `HWRITE` remains the write input directly. This preserves the master's defined input truth table, not permission for the CPU to issue a dual request. CPU legality/exception qualification is separate from the standalone master's invalid-encoding behavior. Valid misaligned halfword/word accesses are suppressed before a bus transfer and retain causes 4/6.

Source: [CPU request qualification](../rtl/core/v/top/RV32I46F_5SP_MMIO.v), [active master](../rtl/bus/AHB_MASTER.v). EX address/control ownership and matching MEM payload ownership are unchanged; the detailed before/after ownership matrix is in [CPU core Section 20.3](21_cpu_core.md#203-integrated-c1a-structure-and-preserved-ownership).

## 7. Store Data Phase

Store data is formed in the CPU MEM stage by `StoreAligner`, using:

- `MEM_memory_write`,
- `MEM_funct3`,
- forwarded `MEM_read_data2`,
- `MEM_alu_result[1:0]`.

The aligned 32-bit result is exported from the CPU and directly mapped to `HWDATA` by `AHB_Master_Interface`.

The byte-lane mask is exported separately as `CUSTOM_WRITE_MASK` and passed through the master as `CUSTOM_WRITE_MASK_OUT`.

Therefore a baseline store has two parallel information paths:

```text
Standard-style bus path:
    HADDR / HWRITE / HTRANS / HWDATA

Project-specific lane path:
    CUSTOM_WRITE_MASK[3:0]
```

The custom mask is consumed by the DMEM BRAM wrapper. It is **not** an AMBA AHB signal and shall not be treated as portable bus semantics.

Detailed SB/SH/SW lane formation is defined in `memory_subsystem.md`.

### 7.1 Approved A2 Payload/Mask Contract

EX owns the bus address/control phase; the matching MEM stage owns both HWDATA and the 4-bit byte-lane intent. StoreAligner eligibility shall be `Q = MEM_valid && MEM_memory_write && !MEM_exc_valid`. Its aligned data shall feed HWDATA and its mask shall feed `CUSTOM_WRITE_MASK` directly. **Both outputs shall be independent of final HRESP/mem_fault_now; no `& !mem_fault_now` mask qualification is permitted.** MEM funct3, forwarded source data and address offset shall all belong to that same store. While the transaction is stalled, its owned payload and lane intent shall remain stable.

`CUSTOM_WRITE_MASK` is a DMEM-local, nonstandard lane sideband passed unchanged by the master. It is not universal AHB/AXI write permission or acceptance, and APB/VRAM do not consume it. A nonzero payload/mask shall never independently cause a physical write. DMEM commits using the accepted data-phase owner's captured address and registered `write_en_reg`, together with that owner's matching MEM data and byte enables at the BRAM edge; see [memory ownership](02_memory_subsystem.md#61-accepted-store-ownership-at-the-bram-edge). Current EX HADDR can already belong to a following transaction and shall not be paired with the current MEM mask.

CPU final-ERROR exception processing and younger-request cancellation remain response-qualified. Final ERROR does not require HWDATA or the mask to become zero. Slaves shall reject invalid transactions before side effects commit; response-independent data formation does not relax failed-store-zero-side-effect requirements. Preserve DMEM zero-wait/OKAY, fabric/default ERROR, slave acceptance, all lane encodings, partial writes and registered RAW bypass; this contract adds no APB latency, global-HREADY write gate or generic bus compliance claim.

### 7.2 A2 Acceptance and Bounded Verification Status

Acceptance requires checking response independence of both outputs in the actual elaborated/optimized design with explicit sequential and blackbox boundaries; physical DMEM write-edge address/data/lane pairing; and stable payload/lanes during waits. Back-to-back stores and DMEM↔APB/VRAM/default transitions shall produce exactly one correctly addressed/lane-qualified write per accepted successful store and none for an unaccepted, cancelled or rejected store. Include first/final ERROR, partial-store RAW merge and recovery.

**Implementation observation:** CPU `store_aligner.memory_write` is exactly `Q`; data and mask connect directly to `MEM_store_data_AHB` and `CUSTOM_WRITE_MASK`, and the master passes both through. This path already existed before C1a. The load path remains final-fault-qualified; payload independence does not apply to all CPU controls.

| Obligation | Existing integrated-source evidence / limit |
|---|---|
| Response-to-data/mask and SCC | Saved unoptimized/optimized graphs: no SCC and six response-to-output reachability checks negative, with seven explicit blackboxes. Isolated response-data/mask mutants are rejected. Not whole-SoC or vendor-netlist proof. |
| Ownership / lanes / waits / faults | Before/after 22,000-cycle directed traces match after distinct source-role validation; per-transaction checker covers 22 physical stores, 18 bus errors, partial RAW and cross-slave activity. Isolated lane/address/owner mutants reject the intended defect. Hold checks cover 2169 pairs. Counts alone are not the oracle. |
| Master decode / alignment | Separate actual compiler-execution records bind before/after/isolated-mutant roles; 4096 vectors each yield 0/0/512 oracle failures, with mutant checker/guard/parent rejecting. This is a finite standalone-master domain, not whole-CPU formal equivalence. |
| Reset / integration | Natural reset/recovery and precise fault cause/PC checks, plus real AES-core integration, support exercised cases. Behavioral memory models do not prove vendor BRAM collision behavior or board reset safety. |

These source-bound observations have bounded composite review support; public derivative packaging remains pending. They replace the blanket “all checks pending” description only for this sub-scope. They do not promote tracker requirements, close broader trap/ISA debt, establish universal SCC absence, fitted timing or external I/O/CDC/board acceptance. Run-specific records remain immutable outside this specification; a documentation change does not retroactively alter their source binding.

### 7.3 Future Shared-Buffer Interface (Non-Normative)

Future CPU/DMA sharing would need master-specific request ownership, arbitration and captured address/data/strobes, including pairing independently accepted address/data channels and WSTRB or equivalent lane intent. CPU `mem_fault_now` is useful for its own exception/request cancellation; it must not gate shared BRAM WEN/byte strobes or another master's accepted write. Permissions, same-address ordering, collision/bypass, visibility and completion require a separately reviewed interface; see [future memory considerations](02_memory_subsystem.md#18-future-shared-dmem-buffer-considerations-non-normative). No AXI/DMA implementation, address allocation, fence/coherency change or frozen future design is authorized by this note.

## 8. Load Return Path

Fabric `HRDATA` is passed through `AHB_Master_Interface` without transformation:

```text
HRDATA -> HRDATA_to_CPU -> HRDATA_FROM_AHB -> LoadExtender
```

The CPU `LoadExtender` uses MEM-stage instruction metadata (`MEM_memory_read`, `MEM_funct3`, `MEM_alu_result[1:0]`) to select and sign/zero-extend the byte, halfword, or word returned by the bus.

Consequently:

- the bus/fabric returns a 32-bit word container,
- subword extraction is a CPU function,
- DMEM byte writes are controlled by the custom write mask,
- peripheral MMIO subword semantics are **not** implied by CPU LB/LH/SB/SH capability.

Peripheral MMIO access policy is defined by `memory_map.md` and `firmware_contract.md`.

## 9. Transfer Size (`HSIZE`) Status

### 9.1 Pre-cleanup observation and Phase 4A-3A implementation

`AHB_Master_Interface` declares:

```text
input  EX_funct3[2:0]
output HSIZE[2:0]
```

The pre-cleanup module had no assignment or sequential driver for `HSIZE`. Phase 4A-3A now drives it deterministically from the load/store funct3.

Thus `HSIZE` is a defined project bus signal for the verified load/store operations below. Unsupported encodings do not become successful word transfers.

### 9.2 Preserved DMEM sideband behavior

The DMEM data path still uses its project sidebands even though `HSIZE` is now driven:

- DMEM receives a separate 4-bit byte-enable mask from the CPU.
- `AHB_MEMORY_SLAVE` does not derive its byte enables from `HSIZE`.
- the AHB-to-APB bridge validates `HSIZE` and permits aligned word MMIO only; it does not generate APB byte strobes.
- load extraction occurs inside the CPU from a returned 32-bit word.

These sidebands remain local to the baseline DMEM and are not a generic AHB/AXI contract.

### 9.3 Active Phase 4A-3A mapping

Phase 4A-3A adopts the following mapping; this does not claim protocol-complete AHB-Lite behavior.

| ISA access | Project `HSIZE` |
|---|---|
| byte (`LB/LBU/SB`) | `3'b000` |
| halfword (`LH/LHU/SH`) | `3'b001` |
| word (`LW/SW`) | `3'b010` |

The focused HSIZE directed test verifies all eight listed load/store encodings.

## 10. Bus Back-Pressure and Pipeline Stall

The master derives:

```text
bus_stall_req = ~HREADY
```

and returns this signal to the CPU `HazardUnit`.

When `bus_stall_req == 1`, the active hazard logic applies highest-priority full-pipeline freeze:

```text
IF_ID_stall  = 1
ID_EX_stall  = 1
EX_MEM_stall = 1
MEM_WB_stall = 1

IF_ID_flush  = 0
ID_EX_flush  = 0
EX_MEM_flush = 0
MEM_WB_flush = 0
```

This override occurs after the other hazard/trap/flush decisions in the combinational hazard logic. Therefore bus back-pressure has higher effective priority than branch/trap flush progression and load-use handling while `HREADY` remains low.

### 10.1 Stability Requirement During Stall

Because the CPU pipeline itself holds the transaction state, a slave/fabric that deasserts `HREADY` relies on the full-pipeline freeze to keep the relevant address/control/data state stable until the transfer can complete.

The baseline has no independent master-side skid buffer or request register that could preserve a transaction while allowing the CPU pipeline to continue.

### 10.2 `HREADY` Contract

The fabric shall not deassert global `HREADY` spuriously. Any low value freezes the complete CPU pipeline, even though the master computes `bus_stall_req` without additionally qualifying it by `HTRANS`.

System-level `HREADY` generation is defined in `ahb_fabric.md`.

## 11. Back-to-Back Transfers

### 11.1 Zero-Wait Slave

For a zero-wait slave such as baseline DMEM, the pipeline may naturally issue a new address phase every cycle:

```text
Cycle N     EX: access A address/control
            MEM: previous instruction data phase

Cycle N+1   EX: access B address/control
            MEM: access A data phase
```

This is the intended high-throughput use of the EX/MEM pipeline mapping.

### 11.2 Wait-State Slave

If the selected path drives `HREADY=0`, the hazard unit freezes all pipeline stages. The EX-stage address/control and MEM-stage data-phase information therefore remain held until the fabric releases the stall.

This behavior is especially important for transfers converted by the AHB-to-APB bridge, where the APB setup/access sequence may extend beyond a single HCLK cycle.

## 12. Load-Use Hazard Interaction

The CPU has a separate one-cycle load-use interlock for a consumer immediately following a load.

When no bus stall is active, a detected load-use hazard performs:

```text
IF_ID_stall = 1
ID_EX_flush = 1
```

while allowing the older load to advance toward WB. The consumer later receives the load result through WB-stage forwarding rather than a same-cycle MEM-load combinational forwarding path.

If `bus_stall_req` is simultaneously asserted, the bus-stall override freezes every stage and suppresses the load-use flush until the bus completes.

This separation is intentional:

- **load-use stall** resolves register-data availability,
- **bus stall** resolves interconnect transfer completion.

## 13. Store-to-Load BRAM Hazard Sideband

The CPU additionally generates:

```text
oBRAM_HAZARD =
    EX_memory_read &&
    MEM_memory_write &&
    (EX effective address[31:2] == MEM address[31:2])
```

This detects a load in EX immediately behind a store in MEM targeting the same 32-bit word.

`oBRAM_HAZARD` is routed directly to the DMEM slave, which performs byte-wise merge/bypass using the store data and byte mask. This signal is **memory-implementation-specific** and is not part of the generic bus protocol.

The architectural data result of this bypass is defined in `memory_subsystem.md`.

## 14. Alignment and Exception Boundary

The CPU computes the effective byte address before it is exported to the bus. Misaligned halfword/word accesses are detected by the CPU exception path.

Baseline alignment requirements:

- byte load/store: any byte address,
- halfword load/store: address bit `[0] == 0`,
- word load/store: address bits `[1:0] == 00`.

The bus interface does not split a misaligned access into multiple transfers and does not silently realign it.

For stores, `StoreAligner` also produces a zero mask for unsupported misaligned SH/SW lane combinations; this is defensive behavior, not the architectural exception mechanism.

## 15. Bus Response / Error Visibility

The pre-cleanup `AHB_Master_Interface` had no `HRESP` input and the CPU received no bus-error indication. Phase 4A-3A connects the selected fabric `HRESP` directly to the CPU for final load/store ERROR handling.

The pre-cleanup CPU could not distinguish OKAY from ERROR; the Phase 4A-3A CPU does so for data-bus load/store faults.

Canonical unmapped-access behavior is specified in `memory_map.md`/`ahb_fabric.md` and verified in the Phase 4A-3A directed bus suite.

Other precise-trap cases (`TRAP-002/003`) retain their existing requirement status in `baseline_cleanup.md`; this C1a description neither reopens previously reviewed scope nor closes unrelated obligations.

## 16. Reset Behavior

The CPU and pipeline are reset from the SoC system reset. At the interface level, reset shall leave the pipeline with no architecturally valid load/store request until normal execution resumes.

The active master itself is predominantly combinational and contains no active transaction state to reset. Transaction preservation during wait states is provided by pipeline stall, not by master-local state.

Memory contents and firmware-image reset semantics are defined in `memory_subsystem.md`.

## 17. Baseline Interface Invariants

The following are baseline contract invariants:

1. The CPU is the only active data-bus master.
2. EX stage owns load/store address and request control.
3. MEM stage owns store data and load-result interpretation.
4. A load/store produces a single `NONSEQ` transfer; bursts are not generated.
5. `HWDATA` is the CPU's MEM-stage aligned store data.
6. `HRDATA` is returned as a 32-bit word and is interpreted by `LoadExtender`.
7. DMEM subword writes depend on the 4-bit custom write-mask sideband.
8. Same-word store-to-load BRAM collision handling depends on the dedicated `oBRAM_HAZARD` sideband.
9. `HREADY=0` freezes all pipeline stages and suppresses pipeline flush progression until the stall clears.
10. The CPU consumes final ERROR `HRESP=01` with `HREADY=1` for its matching MEM owner; the combinational master itself has no `HRESP` input.
11. Pre-cleanup `HSIZE` was undriven; Phase 4A-3A drives it deterministically for load/store bus transfers.
12. The active interface contains no master-local buffering or multiple-outstanding transaction support.

## 18. Known Implementation Quirks / Open Clarifications

### 18.1 Former Undriven `HSIZE` — resolved for load/store in Phase 4A-3A

The pre-cleanup master declared `HSIZE` but did not drive it. Phase 4A-3A now drives byte/halfword/word sizes and rejects unsupported encodings as successful bus transfers. This is not a full AMBA compliance claim.

### 18.2 Former CPU `EX_funct3_AHB` Width Mismatch — resolved

The pre-cleanup CPU declared a 32-bit output for 3 bits of metadata. Phase 4A-3A normalized it to a 3-bit port; P14 also applies the store-data rename described in §18.3. Tracker acceptance remains separate.

### 18.3 Store-Data Signal Name

`MEM_store_data_AHB` carries aligned MEM-stage store write data. P14 replaced the historical misleading `data_memory_read_data_AHB` name while preserving its `HWDATA` meaning and the separate load read path.

### 18.4 Non-Standard Byte-Mask Sideband

`CUSTOM_WRITE_MASK` bypasses standard bus transfer-size/strobe semantics. It is valid for this baseline DMEM integration but is not a portable interconnect contract and should not be propagated unchanged into the planned AXI architecture.

### 18.5 DMEM-Specific RAW Hazard Sideband

`oBRAM_HAZARD` couples CPU pipeline state to the physical DMEM collision workaround. Future cache/external-memory/AXI designs should replace or contain this dependency rather than treating it as a generic bus signal.

### 18.6 No CPU Bus-Error Input

Before Phase 4A-3A, `HRESP` was not visible to the CPU. The data-bus access-fault portion is now implemented; full trap/retirement cleanup remains open.

## 19. Verification Requirements

Independent CPU/bus verification should cover at least:

- isolated load and store transfers,
- back-to-back load/load, store/store, load/store, and store/load sequences,
- SB/SH/SW byte-mask behavior,
- LB/LBU/LH/LHU/LW extraction and extension,
- aligned vs misaligned memory operations,
- store-to-load same-word byte-wise bypass,
- one-cycle load-use interlock,
- `HREADY` wait-state insertion at address/data boundaries,
- full pipeline stability while `HREADY=0`,
- simultaneous bus stall with branch/trap/load-use conditions,
- APB-bridge wait-state transfer preservation,
- deterministic `HSIZE` and invalid-size rejection, including standalone-master versus CPU legality qualification,
- final `HRESP` consumption, precise cause/PC and failed-effect suppression.

Any future fix to `HSIZE`, bus-error handling, or replacement of the custom sidebands shall update this specification before RTL implementation.

## 20. Source Anchors

Primary active implementation sources for this specification:

- `rtl/core/v/top/RV32I46F_5SP_MMIO.v`
- `rtl/core/v/hazard_forward/Hazard_Unit.v`
- `rtl/core/v/mem_stage/StoreAligner.v`
- `rtl/core/v/mem_stage/LoadExtender.v`
- `rtl/core/v/mem_stage/Exception_Detector.v`
- `rtl/bus/AHB_MASTER.v`
- `rtl/bus/AHB_MEMORY_SLAVE.v`
- `rtl/soc/AMBA_SoC_TOP.v`

Related specifications:

- `soc_architecture.md`
- `memory_map.md`
- `memory_subsystem.md`
- `ahb_fabric.md`
- `firmware_contract.md`

## Phase 4A-2 Approved Data-Bus Fault Contract (active Phase 4A-3A bus-access scope)

The project retains a 2-bit HRESP: `2'b00` OKAY and `2'b01` ERROR, not the full AMBA response set. A2 requires ERROR for invalid canonical data accesses with a first cycle `HRESP=ERROR, HREADY=0` and a final cycle `HRESP=ERROR, HREADY=1`. On final load/store ERROR completion the CPU traps with `mcause=5`/`mcause=7` and `mepc` equal to the faulting instruction PC. A failed load writes no GPR, a failed store causes no side effect, and a failed instruction does not retire successfully. Existing misalignment traps (causes 4/6) remain distinct and take precedence. Instruction fetch is not on this AHB data path; no instruction-fetch AHB fault is specified here.

**Implementation evidence:** Phase 4A-3A CPU harness and SoC integration tests verify final-cycle error sampling, cause/PC, failed-load writeback suppression, younger-instruction flush, failed-store side-effect suppression, and misalignment priority. The CPU master now drives byte/halfword/word `HSIZE`; this is a project AHB-like data-bus contract, not full AMBA AHB compliance. Other trap/retirement cleanup remains open in `baseline_cleanup.md`.
