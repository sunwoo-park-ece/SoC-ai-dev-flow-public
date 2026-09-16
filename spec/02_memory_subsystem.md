# Baseline SoC Memory Subsystem Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `memory_subsystem.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`.

## 1. Purpose

This document defines the baseline SoC memory subsystem below the address-map level. It specifies the architectural behavior of the CPU-local instruction memory, AHB-side data memory, load/store lane handling, synchronous BRAM timing, read-after-write bypass behavior, firmware image initialization, and reset-visible memory semantics.

This document does **not** define the complete CPU pipeline or the complete AHB fabric. CPU-side bus timing and pipeline stall rules are refined in `cpu_interface.md`; slave selection and system-level response muxing are refined in `ahb_fabric.md`.

## 2. Baseline Memory Architecture

The baseline uses a Harvard-style split between instruction fetch and data access.

```text
                     RV32I 5-stage CPU
                    +------------------+
                    |                  |
        IF_pc ----->| Local IMEM       |
                    | 4096 x 32-bit    |
                    | 16 KiB ROM       |
                    |                  |
                    | Load / Store     |
                    +--------+---------+
                             |
                             v
                    AHB Master Interface
                             |
                             v
                      AHB-side DMEM
                    +------------------+
                    | AHB_MEMORY_SLAVE |
                    |                  |
                    |  write port      |
                    |       \          |
                    |   8192 x 32-bit  |
                    |   32 KiB BRAM    |
                    |       /          |
                    |  read port       |
                    |                  |
                    | byte-wise RAW    |
                    | bypass / merge   |
                    +------------------+
```

Baseline properties:

- IMEM is CPU-local and does not consume an AHB address-decoder slave slot.
- DMEM is accessed through the CPU data-side AHB path.
- IMEM and DMEM both use 32-bit words.
- The architectural byte ordering is little-endian.
- No cache, MMU, external SDRAM, coherency mechanism, or DMA master is part of this baseline memory subsystem.

## 3. Canonical Memory Regions

The address allocations are owned by `memory_map.md` and summarized here only for context.

| Memory | Canonical base | Canonical size | Word count | CPU path |
|---|---:|---:|---:|---|
| IMEM | `0x0000_0000` | 16 KiB | 4096 x 32-bit | CPU-local instruction fetch |
| DMEM | `0x1000_0000` | 32 KiB | 8192 x 32-bit | CPU data-side AHB |

Only these canonical capacities are architectural. Coarse RTL decode aliases outside the canonical DMEM range are implementation artifacts and are not part of this contract.

## 4. Instruction Memory (IMEM)

### 4.1 Organization

The active FPGA implementation uses a single-port ROM configuration with:

```text
Width        : 32 bits
Depth        : 4096 words
Capacity     : 16 KiB
Word address : 12 bits
Init image   : IMEM.mif
```

The CPU fetch path supplies:

```text
IMEM.address = IF_pc[13:2]
```

Therefore bits `[1:0]` are not part of the ROM word address and normal instruction fetch is 32-bit aligned.

### 4.2 Fetch Timing

The physical FPGA ROM registers the input address and exposes an unregistered output. Architecturally, instruction fetch is therefore treated as a **synchronous one-cycle memory path** aligned with the IF/ID pipeline behavior.

The current RTL instantiates the IMEM inside `IF_ID_Register`. That source-code placement is an implementation detail, not an architectural requirement. Future refactoring may relocate the ROM wrapper provided that the observable fetch timing and pipeline contract remain equivalent or the relevant specifications are updated first.

### 4.3 IF/ID Stall Preservation

Because the ROM is synchronous, the IF/ID logic preserves the fetched instruction when the pipeline is stalled. The active implementation captures `irom_q` into a holding register on entry to an IF/ID stall and continues presenting that held instruction while the stall remains asserted.

The memory subsystem contract therefore requires that a pipeline stall shall not cause the decode stage to observe an instruction from a newer PC than the held `ID_pc`.

### 4.4 IMEM Mutability

IMEM is read-only during normal processor execution in the baseline.

There is no architecturally defined CPU data-side write path to IMEM. Firmware updates are performed by rebuilding/selecting the FPGA memory initialization image rather than by runtime stores.

## 5. Data Memory (DMEM)

### 5.1 Organization

The active DMEM physical memory is configured as a dual-port 32-bit BRAM with logically separated write and read ports sharing `HCLK`.

```text
Width        : 32 bits
Depth        : 8192 words
Capacity     : 32 KiB
Word address : 13 bits
Byte lanes   : 4 x 8-bit
Init image   : DMEM.mif
```

The generated memory primitive is used as:

- Port A: write path with 4-bit byte enable.
- Port B: read path.
- Common clock: `HCLK`.

The generated primitive marks mixed-port read-during-write behavior as `DONT_CARE`; therefore software-visible correctness for the relevant CPU read-after-write case is provided by explicit bypass logic in `AHB_MEMORY_SLAVE`, not by relying on vendor primitive collision behavior.

### 5.2 Addressing

Canonical DMEM byte addresses are:

```text
0x1000_0000 - 0x1000_7FFF
```

The physical BRAM word index is derived from:

```text
HADDR[14:2]
```

for both read and write addressing, with the write address captured for the AHB data phase.

The active top-level selects a broader physical decode window than the canonical 32 KiB range. That alias behavior is documented in `memory_map.md` and shall not be used as a second memory region.

## 6. DMEM AHB-Side Timing

`AHB_MEMORY_SLAVE` is designed to add no explicit wait state:

```text
HREADY = 1
HRESP  = OKAY
```

The BRAM itself is synchronous. The intended timing model is:

```text
Cycle N address phase:
    CPU presents memory address/control

Clock edge N->N+1:
    BRAM read address/control is captured
    store address/control is captured for the write data phase

Cycle N+1 data phase:
    load data is available as HRDATA
    store data is committed with the captured write address and byte mask
```

Thus **0-wait-state** in this document means no extra AHB stall cycle is inserted beyond the normal pipelined address/data relationship. It does not mean combinational asynchronous BRAM read.

`HRESP` is always OKAY in the current DMEM slave. Address-error policy for unmapped regions is owned by `ahb_fabric.md` and `memory_map.md`.

## 7. Store Data Alignment and Byte Enables

The CPU `StoreAligner` generates both the 32-bit write data and the 4-bit write mask. The DMEM slave carries this write mask as a project-specific sideband to the BRAM byte-enable input.

The current memory slave does not derive byte enables from `HSIZE`; the custom write-mask path is therefore part of the baseline CPU-to-DMEM implementation contract and shall be accounted for in `cpu_interface.md`.

### 7.1 Byte-Lane Convention

| `write_mask` bit | BRAM byte lane | Word bits | Lowest byte-address offset |
|---:|---|---|---:|
| `[0]` | lane 0 | `[7:0]` | `+0` |
| `[1]` | lane 1 | `[15:8]` | `+1` |
| `[2]` | lane 2 | `[23:16]` | `+2` |
| `[3]` | lane 3 | `[31:24]` | `+3` |

This is consistent with the architectural little-endian convention.

### 7.2 Store Operations

| Instruction | Valid address offset | Write mask | Write-data formation |
|---|---|---|---|
| `SB` | `0`, `1`, `2`, `3` | one selected byte lane | source byte replicated across all four lanes |
| `SH` | `0` | `0011` | source halfword replicated twice |
| `SH` | `2` | `1100` | source halfword replicated twice |
| `SW` | `0` | `1111` | source word unchanged |

For misaligned `SH` or `SW`, the active StoreAligner produces a zero write mask. Architectural handling is nevertheless the synchronous misaligned-store trap defined by the CPU exception path; the zero mask is a defensive implementation behavior and not a substitute for the trap contract.

## 8. Load Extraction and Extension

The BRAM returns a complete 32-bit aligned word. The CPU `LoadExtender` selects the requested byte/halfword from that word and applies sign or zero extension.

### 8.1 Load Operations

| Instruction | Alignment requirement | Selected data | Extension |
|---|---|---|---|
| `LB` | none | byte selected by address `[1:0]` | sign extend |
| `LBU` | none | byte selected by address `[1:0]` | zero extend |
| `LH` | address `[0] = 0` | lower/upper half selected by address `[1]` | sign extend |
| `LHU` | address `[0] = 0` | lower/upper half selected by address `[1]` | zero extend |
| `LW` | address `[1:0] = 00` | full 32-bit word | none |

Misaligned halfword and word loads are synchronous CPU exceptions. They are not specified as split or multi-access memory operations.

## 9. Misaligned Access Contract

The baseline does not emulate misaligned halfword/word accesses in the memory subsystem.

Architectural requirements:

- `LB`, `LBU`, and `SB` may target any byte address.
- `LH`, `LHU`, and `SH` require 2-byte alignment.
- `LW` and `SW` require 4-byte alignment.
- Misaligned loads generate the CPU's misaligned-load trap.
- Misaligned stores generate the CPU's misaligned-store trap.

The physical BRAM word-address truncation shall never be used to justify wrap, split, or silently realigned software behavior.

## 10. Store-to-Load Read-After-Write Hazard

### 10.1 Hazard Condition

The active CPU detects the back-to-back case in which:

- the instruction in EX is a load,
- the instruction in MEM is a store, and
- both addresses refer to the same 32-bit word.

The implemented condition compares address bits `[31:2]`.

### 10.2 Why Bypass Is Required

The physical DMEM primitive declares mixed-port read-during-write data as unspecified (`DONT_CARE`). A load immediately following a store to the same word therefore cannot rely on the raw BRAM output to return either the old or new value deterministically.

The baseline resolves this with explicit byte-wise forwarding in `AHB_MEMORY_SLAVE`.

### 10.3 Byte-Wise Merge Semantics

When the hazard is detected, the memory slave captures:

- the store write data,
- the store byte-enable mask,
- the hazard indication.

For each returned byte lane independently:

```text
if hazard && store_byte_enable[lane] == 1:
    load_word[lane] = store_write_data[lane]
else:
    load_word[lane] = bram_read_data[lane]
```

Therefore a back-to-back `SB` or `SH` followed by a load of the same word observes the newly written bytes while preserving untouched bytes from the BRAM word. A back-to-back `SW` forwards all four bytes.

This merge behavior is an architectural baseline requirement because software-visible correctness shall not depend on the vendor BRAM collision mode.

## 11. CPU Load-Use Pipeline Interaction

The memory subsystem's synchronous load timing is paired with a **one-cycle load-use hazard policy** in the active CPU.

When an instruction immediately consumes a register being produced by a preceding load:

- IF/ID is stalled for one cycle.
- ID/EX is flushed to insert a bubble.
- the load advances to MEM/WB.
- the consumer subsequently receives the load result through WB-stage forwarding.

The CPU no longer relies on a long combinational `HRDATA -> forwarding -> ALU/branch/PC` path from the MEM-stage load result.

The exact pipeline-control priority and forwarding rules are owned by `cpu_interface.md`; this section records the memory timing assumption that those rules depend on.

## 12. Firmware Image and Initialization Contract

### 12.1 Build-Time Images

The current firmware build flow uses default depths matching the physical memories:

```text
IMEM depth = 4096 words
DMEM depth = 8192 words
```

The selected FPGA image provides:

```text
fpga/quartus/mem/IMEM.mif
fpga/quartus/mem/DMEM.mif
```

The generated FPGA memory wrappers consume those files as initialization images.

### 12.2 Linker Placement

The active linker contract is:

```text
IMEM : 0x0000_0000, 16 KiB
DMEM : 0x1000_0000, 32 KiB
```

Current section placement:

- `.start`, `.text`, `.init`, `.fini` -> IMEM.
- `.rodata`, `.srodata`, `.data`, `.sdata` -> initialized DMEM image.
- `.bss`, `.sbss`, `COMMON` -> DMEM, runtime-zeroed.
- stack top -> end of canonical DMEM minus 4 bytes.

### 12.3 Reset Does Not Clear DMEM Contents

System reset resets the CPU and memory-wrapper control state but does not architecturally erase the entire DMEM array.

The startup code establishes C runtime semantics by:

1. loading `sp` from `__stack_top`,
2. clearing the range `__bss_start` to `__bss_end` with word stores,
3. calling `main`.

Firmware shall therefore not assume that arbitrary DMEM locations are cleared merely because system reset was asserted.

## 13. Reset Behavior

### IMEM

- Memory contents are configuration-initialized from `IMEM.mif`.
- CPU reset clears/realigns fetch-control state.
- Reset does not rewrite the instruction image.

### DMEM

- Memory contents are configuration-initialized from `DMEM.mif`.
- Reset clears AHB memory-slave pipeline/bypass control registers.
- Reset does not perform a full 32 KiB RAM scrub.
- `.bss` zero initialization is a firmware startup responsibility.

Any future hardware memory-clear mechanism shall be specified explicitly before becoming a software-visible reset guarantee.

## 14. Baseline Implementation Quirks / Non-Portable Details

The following are observed implementation details and shall not be generalized beyond this baseline without specification review:

1. **DMEM coarse decode alias** — top-level selection is wider than the canonical 32 KiB range; only the canonical range in `memory_map.md` is supported.
2. **Custom DMEM write-mask sideband** — byte enables are supplied outside the standard AHB signal set rather than reconstructed solely from `HSIZE`/address.
3. **Vendor BRAM collision mode** — mixed-port read-during-write is `DONT_CARE`; deterministic same-word store-to-load behavior depends on explicit bypass logic.
4. **IMEM physical placement** — the ROM instance currently resides inside `IF_ID_Register`; this is not a required future hierarchy.
5. **Vendor-generated wrappers** — exact Intel/Altera generated source files are implementation artifacts. Future reproducible regeneration may replace them as long as this architectural contract is preserved.

## 15. Verification Requirements

A baseline-compatible memory implementation should verify at minimum:

- IMEM address width and 4096-word capacity.
- sequential instruction fetch across the full canonical IMEM range.
- IF/ID stall preservation of instruction/PC pairing.
- DMEM 8192-word capacity and canonical address boundaries.
- `SB` to all four byte lanes.
- aligned `SH` to lower and upper halfword lanes.
- aligned `SW` full-word writes.
- `LB/LBU/LH/LHU/LW` extraction and extension behavior.
- misaligned halfword/word load/store trap generation.
- same-word `SB -> load`, `SH -> load`, and `SW -> load` bypass cases.
- byte-wise merge correctness for untouched bytes during partial-store bypass.
- ordinary reads without a RAW hazard use BRAM data without false bypass.
- one-cycle load-use pipeline behavior for representative ALU, branch, JALR, and store consumers.
- firmware image depths and linker regions remain consistent with physical memory capacities.
- startup `.bss` zeroing does not overflow canonical DMEM.

## 16. Baseline Memory-Subsystem Invariants

The following are baseline architectural invariants:

1. IMEM is a 16 KiB CPU-local instruction memory at `0x0000_0000`.
2. IMEM contains 4096 x 32-bit words and is runtime read-only to the CPU baseline.
3. DMEM is a 32 KiB AHB-side data memory at `0x1000_0000`.
4. DMEM contains 8192 x 32-bit words with four byte write enables.
5. Architectural byte order is little-endian.
6. BRAM reads are synchronous; zero AHB wait states do not imply asynchronous RAM.
7. Partial stores use byte enables generated by the CPU StoreAligner.
8. Loads select and extend data in the CPU LoadExtender.
9. Misaligned halfword/word accesses trap rather than being split across words.
10. Immediate same-word store-to-load RAW behavior is deterministic through byte-wise bypass/merge logic.
11. Firmware images use `IMEM.mif` and `DMEM.mif` with depths matching the physical memories.
12. System reset does not guarantee a full DMEM clear; `.bss` is cleared by startup firmware.
13. No cache, external SDRAM, DMA, or coherency mechanism is part of the baseline memory subsystem.

## 17. Related Specifications

This document is refined by or interacts with:

- `memory_map.md` — canonical address allocation.
- `cpu_interface.md` — CPU/AHB signals, custom write mask, stalls, forwarding contract.
- `ahb_fabric.md` — DMEM selection and system response muxing.
- `reset_clock.md` — reset and clock-domain contract.
- `firmware_contract.md` — linker/startup/image generation contract.

If active RTL conflicts with this document while the document is DRAFT, the conflict shall be reviewed explicitly. After baseline approval, implementation changes shall be made against the approved specification rather than silently redefining memory behavior.