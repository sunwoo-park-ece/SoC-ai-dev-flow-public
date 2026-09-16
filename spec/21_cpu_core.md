# RV32I CPU Core Microarchitecture Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline RTL and updated with approved cleanup-policy decisions.
>
> **Canonical language:** English. If this file and `cpu_core.ko.md` conflict, this file is authoritative.
>
> **Logical position:** This is a supplemental detailed CPU microarchitecture specification. Although numbered `21` to avoid renumbering the established spec set, it logically refines and precedes the CPU-facing portions of `cpu_interface.md` and `interrupt_architecture.md`.
>
> **Related specifications:** `memory_subsystem.md`, `cpu_interface.md`, `ahb_fabric.md`, `interrupt_architecture.md`, `firmware_contract.md`, `baseline_cleanup.md`.

> **Phase 4A-3A reading rule:** Earlier missing-access-fault descriptions reconstruct the pre-cleanup CPU. The final access-fault section records the verified load/store bus-fault sub-scope; it does not close general precise retirement or other `TRAP-003` dependencies.

## 1. Purpose and Scope

This document defines the implemented microarchitecture of the active `RV32I46F5SPMMIO` CPU used by the validated FPGA baseline and separates that baseline from approved cleanup behavior.

It owns the CPU-internal contract for:

- the five pipeline stages,
- instruction decode and immediate generation,
- ALU and control-flow execution,
- register-file behavior,
- forwarding and data-hazard handling,
- load-use interlocking,
- pipeline stall/flush priority,
- CSR execution and counters,
- synchronous exception detection,
- trap-controller sequencing,
- retirement/debug outputs,
- reset-visible CPU state,
- CPU-specific cleanup requirements.

It does **not** redefine:

- the external AHB-style bus protocol (`cpu_interface.md`),
- IMEM/DMEM physical BRAM behavior (`memory_subsystem.md`),
- system slave decode (`ahb_fabric.md`),
- the future external-interrupt/PLIC architecture (`interrupt_architecture.md` and future PLIC spec).

This specification describes the current locally modified CPU, not an unmodified upstream core and not a claim of complete RISC-V privileged-architecture compliance.

---

## 2. Provenance and Local Ownership

The CPU source is based on the MIT-licensed `RV32I46F_5SP` CPU from `RISC-KC/basic_rv32s`.

Repository provenance records identify project-local work including:

- SoC/MMIO integration,
- AHB-facing load/store adaptation,
- pipeline/hazard behavior tuning,
- FPGA synchronous-BRAM timing integration,
- project-specific store-mask and BRAM RAW handling,
- SoC integration and architectural cleanup.

The exact historical upstream import commit has not been reconstructed. The upstream commit referenced by the license audit is an audit reference only and shall not be described as the exact import revision.

Portfolio and technical-report wording shall distinguish:

```text
upstream-derived CPU basis
        +
project-local integration / modification / optimization
```

rather than claiming that every line of the CPU was authored locally.

---

## 3. Architectural Summary

Current core properties:

```text
ISA data width        : RV32 / XLEN=32
Pipeline              : 5 stages
Stages                : IF -> ID -> EX -> MEM -> WB
Issue width            : single issue
Retirement width       : at most one instruction/cycle
Branch prediction      : inactive in current top
Instruction memory     : CPU-local synchronous IMEM
Data memory / MMIO     : external AHB-style interface
Caches                 : none
MMU                    : none
External interrupt     : none in active baseline
Privilege model        : partial machine-mode CSR/trap support
```

Conceptually:

```text
                  +---------------------------+
PC / IMEM ------->| IF                        |
                  +-------------+-------------+
                                |
                           IF/ID register
                                |
                                v
                  +---------------------------+
                  | ID                        |
                  | decode / RF / immediate   |
                  | CSR read request          |
                  +-------------+-------------+
                                |
                           ID/EX register
                                |
                                v
                  +---------------------------+
                  | EX                        |
                  | ALU / branch / JAL/JALR   |
                  | forwarding                |
                  | effective address         |
                  +-------------+-------------+
                                |
                           EX/MEM register
                                |
                                v
                  +---------------------------+
                  | MEM                       |
                  | load extension            |
                  | store alignment/mask      |
                  +-------------+-------------+
                                |
                           MEM/WB register
                                |
                                v
                  +---------------------------+
                  | WB                        |
                  | register writeback        |
                  | CSR write commit          |
                  +---------------------------+
```

There is no explicit per-stage architectural `valid` bit. Pipeline bubbles are represented primarily by a NOP instruction (`ADDI x0,x0,0`) plus zeroed control fields.

---

## 4. Pipeline Stage Ownership

| Stage | Principal responsibilities |
|---|---|
| IF | PC state, next-PC selection, synchronous IMEM address generation |
| ID | instruction field decode, register-file reads, immediate construction, control decode, CSR read address |
| EX | ALU operation, branch comparison/target, JAL/JALR target, load/store effective address, operand forwarding |
| MEM | load extraction/sign-extension, store alignment/byte mask, data-phase metadata |
| WB | final register writeback, normal CSR write commit, instruction-retirement observation |

Representative flow:

```text
integer ALU: IF -> ID -> EX(result) -> MEM -> WB(register write)
load:        IF -> ID -> EX(address) -> MEM(HRDATA + extend) -> WB
store:       IF -> ID -> EX(address) -> MEM(store align/data phase)
branch:      IF -> ID -> EX(compare + target) -> younger-stage flush if taken
JAL/JALR:    IF -> ID -> EX(target) -> younger-stage flush -> WB writes PC+4
CSR:         IF -> ID(CSR read) -> EX(new CSR value) -> MEM -> WB
```

---

## 5. IF Stage and Program Counter

### 5.1 Program-counter state

`ProgramCounter` is a 32-bit register. On CPU reset:

```text
PC <- 0x0000_0000
```

When `clk_enable=1`, the PC loads `next_pc`. In the active SoC integration `clk_enable` is tied permanently high, so normal CPU pausing is performed through `pc_stall` and pipeline stall control rather than by disabling the CPU clock-enable input.

### 5.2 Next-PC priority

When `pc_stall=0`, `PCController` uses:

```text
1. trapped          -> trap_target
2. EX_jump          -> EX ALU result
3. branch_taken     -> branch_target_actual
4. otherwise        -> PC + 4
```

When `pc_stall=1`, `next_pc = current PC`.

The `trapped` signal is a registered exception indication. Trap-controller sequencing generally holds the PC through `trap_done/csr_ready` until a usable target is available. This broad `trapped`-as-redirect-select arrangement is baseline behavior and shall be covered by precise-trap cleanup verification.

### 5.3 No active branch prediction

A `BranchPredictor` source file exists, but its top-level instantiation is commented out. The active baseline resolves branches and jumps in EX without prediction. Therefore a taken branch or jump invalidates the two younger pipeline stages.

---

## 6. Instruction Fetch and IF/ID Preservation

The active IMEM instance is physically instantiated inside `IF_ID_Register`.

```text
IMEM address = IF_pc[13:2]
```

This provides a 4096-word / 16 KiB instruction image, consistent with `memory_subsystem.md`.

Because the FPGA ROM is synchronous, `IF_ID_Register` contains explicit instruction-hold logic. On the first IF/ID stall cycle it captures the current IMEM output into `IF_instruction_d`; subsequent stall cycles continue presenting that held instruction while `ID_pc` and `ID_pc_plus_4` remain unchanged.

A flush publishes:

```text
0x0000_0013 = ADDI x0, x0, 0
```

This stall-preservation behavior is required so ID never sees an instruction corresponding to a newer fetch address while the associated ID PC is held.

---

## 7. ID Stage: Decode, Immediate Generation, and Legality

### 7.1 Recognized opcode families

`InstructionDecoder` extracts standard fields for:

- LUI / AUIPC,
- JAL,
- JALR,
- BRANCH,
- LOAD,
- STORE,
- OP-IMM,
- OP,
- FENCE opcode family,
- SYSTEM / CSR opcode family.

Unknown opcodes receive zeroed decoded fields but retain their raw opcode value into the control path.

### 7.2 Immediate formats

| Instruction family | Immediate form |
|---|---|
| JALR / LOAD / OP-IMM / FENCE / SYSTEM | I-type sign extension |
| STORE | S-type sign extension |
| LUI / AUIPC | U-type, low 12 bits zero |
| BRANCH | B-type, low bit zero |
| JAL | J-type, low bit zero |

### 7.3 Current legality limitation

The active decoder/control path does not fully validate reserved/illegal encodings. Examples include:

- unsupported opcode encodings becoming inert controls instead of raising illegal-instruction,
- JALR not enforcing `funct3=000`,
- R-type legality not checked against complete `funct7`,
- shift-immediate legality not checked against all required upper immediate bits,
- unsupported LOAD/STORE `funct3` values still being able to request a bus transaction,
- unsupported CSR accesses not generating illegal-instruction.

This behavior is not an approved future ISA policy. Cleanup shall add deterministic legality checks and illegal-instruction handling.

---

## 8. Register File

The active register file is:

```text
32 registers x 32 bits
2 combinational read ports
1 synchronous write port
```

### 8.1 x0

- reads of x0 return zero,
- writes to x0 are suppressed.

### 8.2 Same-cycle WB-to-ID bypass

If WB writes the same register being read by ID in the same cycle, the combinational read port returns incoming `write_data` rather than the old array value.

### 8.3 GPR reset behavior — approved cleanup policy

The GPR array has no system-reset input. It is initialized to zero through a Verilog `initial` loop at simulation/FPGA configuration time, while a later CPU/system reset does not explicitly clear the register array.

**Approved cleanup policy:** retain architecturally unspecified GPR contents after system reset. Cleanup shall **not** add a reset fanout that clears x1..x31 merely for debug determinism. Startup software remains responsible for establishing required software state after reset.

Therefore neither baseline nor cleanup-target firmware may rely on `system reset -> all GPRs zero`.

### 8.4 Debug outputs

Selected register values are exposed for diagnostics only. `debug_X4` samples x15 into a separate debug register and shall not define architectural register-file behavior.

---

## 9. EX Stage ALU

The ALU supports:

```text
ADD  SUB
AND  OR  XOR
SLT  SLTU
SLL  SRL  SRA
CSR helper operations
NOP
```

### 9.1 Implemented integer operations

The datapath provides the ordinary RV32I integer ALU families including ADD/SUB, shifts, signed/unsigned set-less-than, logic operations, immediate variants, AUIPC, and load/store effective-address addition.

### 9.2 Register-shift amount defect

Immediate shifts supply only the low five shift-amount bits. Register-register shifts currently pass the complete 32-bit rs2 value to Verilog shift operators:

```text
src_A << src_B
src_A >> src_B
$signed(src_A) >>> src_B
```

RV32 semantics require register shift amount = `rs2[4:0]`. Cleanup shall mask register-based shift amount to five bits and test rs2 values 0, 31, 32, 33, 63, and larger values.

---

## 10. Branch and Jump Execution

### 10.1 Branches

`BranchLogic` implements BEQ/BNE/BLT/BGE/BLTU/BGEU with forwarded EX operands.

For a taken branch:

```text
branch_target = EX_pc + EX_imm
```

### 10.2 JAL

JAL computes `EX_pc + J-immediate` in EX and writes `EX_pc + 4` to rd at WB.

### 10.3 JALR baseline deviation and cleanup target

The active JALR target is the raw EX ALU result:

```text
rs1 + immediate
```

and the exception detector tests the raw low two bits for zero.

Cleanup shall implement architectural RV32I behavior:

```text
target = (rs1 + immediate) & ~1
```

before final instruction-alignment checking and redirection.

### 10.4 Branch-target alignment gap

Instruction-address misalignment detection exists for JAL/JALR, but the branch-target check is commented out. Cleanup shall detect taken-branch target misalignment for the active IALIGN=32 policy.

---

## 11. Forwarding Architecture

The CPU has separate paths for:

1. EX ALU operand forwarding,
2. store-data forwarding,
3. CSR value forwarding.

### 11.1 ALU forwarding

For each EX source register, MEM has priority over WB when the producer writes a nonzero destination register. A MEM-stage producer is directly forwardable only when it is not a load.

Forwardable MEM results include ALU result, LUI immediate, JAL/JALR PC+4, and the old CSR read value. WB forwarding additionally includes completed load data.

### 11.2 Why MEM loads are excluded

The active CPU intentionally does not forward MEM-stage load data directly into the following EX operation. This removes the former long combinational path:

```text
bus/BRAM read -> load extraction -> forwarding -> EX ALU/branch
```

An immediate load consumer receives one interlock cycle and subsequently forwards from WB.

### 11.3 Store-data forwarding

Stores use a separate forwarding path for rs2/store data because EX ALU source B is the address immediate. The dedicated store path selects the newest available MEM/WB producer and feeds the value carried into `StoreAligner`.

### 11.4 CSR forwarding

CSR dependency priority is:

```text
MEM pending CSR write
    > WB pending CSR write
    > CSRFile read data
```

---

## 12. Load-Use Interlock

The one-cycle load-use hazard is detected when:

```text
EX instruction is LOAD
and EX.rd != x0
and ID actually consumes EX.rd as rs1 and/or rs2
```

When detected and no higher-priority stall is active:

```text
IF/ID  = stall
ID/EX  = flush (insert bubble)
EX/MEM = advance
MEM/WB = advance
```

The dependent instruction then re-enters EX and receives the result through WB forwarding. This one-cycle policy is an intentional project-local timing optimization.

---

## 13. Store-to-Load BRAM RAW Sideband

The core detects:

```text
oBRAM_HAZARD =
    EX_memory_read &&
    MEM_memory_write &&
    (EX effective address[31:2] == MEM effective address[31:2])
```

This is a DMEM-specific sideband for vendor-BRAM read-during-write handling, not a generic pipeline dependency or future AXI semantic. Observable merge/bypass behavior is owned by `memory_subsystem.md`.

---

## 14. Pipeline Stall and Flush Semantics

Individual pipeline registers implement:

```text
reset > flush > normal capture when !stall
```

The system-level `HazardUnit` determines asserted stall/flush requests.

### 14.1 Control-flow flush

Taken branch/JAL/JALR flushes IF/ID and ID/EX once trap handling permits normal progression.

### 14.2 Trap completion flush

`pth_done_flush` requests flush of all four pipeline registers.

### 14.3 Trap standby / CSR stall

`standby_mode` stalls IF/ID and ID/EX while allowing older stages to drain. Outside standby, `!trap_done || !csr_ready` stalls all four stages.

### 14.4 Bus-stall override — highest effective priority

```text
if bus_stall_req:
    stall IF/ID, ID/EX, EX/MEM, MEM/WB
    clear every flush request
```

Therefore a bus wait freezes the complete pipeline and postpones branch/trap/load-use flush progression until the bus releases the stall.

### 14.5 Effective priority summary

```text
BUS STALL
  -> full freeze, suppress all flushes

otherwise:
  trap/CSR standby and trap-controller progress
  trap-completion flush
  branch/jump flush
  load-use bubble
  normal pipeline advance
```

Simultaneous-event behavior remains a mandatory directed-regression area.

---

## 15. WB and Register Writeback

| Writeback class | Value |
|---|---|
| LOAD | extended load result |
| ALU | `WB_alu_result` |
| LUI | `WB_imm` |
| JAL / JALR | `WB_pc_plus_4` |
| CSR | old CSR read value |

The register file suppresses writes to x0. Since Phase 4A-3B2B, normal GPR writes are qualified by the internal `gpr_commit = commit_valid && WB_register_write_enable && (WB_rd != 0)` event. The active design still has no complete external architectural commit interface containing PC/rd/value/valid/exception metadata.

---

## 16. Retirement and Performance Counters

### 16.1 `retire_instruction`

```text
retire_instruction = WB_instruction
```

This legacy debug output still has no associated external retirement-valid output. The internal `commit_valid` signal below is the canonical normal retirement event; consumers must not infer validity from `retire_instruction` alone.

### 16.2 Phase 4A-3B2B normal retirement

The pre-3B2B implementation used `WB_instruction != 0x0000_0013` to distinguish a bubble, so a real NOP was not counted. That instruction-pattern heuristic and its delayed `instruction_retired` pulse have been removed. The current normal WB consume event is:

```text
commit_valid = clk_enable && !reset && WB_valid && !WB_exc_valid
               && !wb_is_mret && !MEM_WB_stall && !MEM_WB_flush
               && !trap_service_hold
```

It is asserted only on the enabled edge that consumes a successful normal WB token. A valid `ADDI x0,x0,0` counts; an invalid bubble, held WB, fault token, flush or trap service does not. A younger MEM final ERROR does not suppress an older normal WB commit. Normal CSR writes are gated by this event plus serialized CSR ownership; trap-owned CSR writes are separate.

`CSRFile` increments its 64-bit `minstret` directly from `commit_valid` on the same edge, after older commits have drained before a younger serialized CSR read. The directed 3B2B scoreboard and user-run Quartus fit/STA evidence are recorded in the local Phase 4A-3B2B report. **Historical 3B2B snapshot:** the then-dedicated MRET service path did not yet assert `commit_valid`. Phase 4A-3B3 subsequently added one MRET commit/`minstret` increment on accepted redirect; `CPU-005` is VERIFIED, and Phase 4A-3B-CLOSE completed the remaining `TRAP-002` precision interaction verification.

### 16.3 `mcycle`

`mcycle` increments on every enabled CPU clock cycle. In the active SoC `clk_enable=1`, so bus-stall cycles are included.

---

## 17. CSR Execution Datapath

### 17.1 Supported CSR instruction forms

The active datapath implements arithmetic for:

- CSRRW,
- CSRRS,
- CSRRC,
- CSRRWI,
- CSRRSI,
- CSRRCI.

Register forms use rs1; immediate forms use the zero-extended rs1/zimm field. rd receives the previous CSR value.

### 17.2 CSR read latency / `csr_ready`

Recognized CSR access enters a small `csr_processing` sequence. The initial access drives `csr_ready` low and stalls the complete pipeline; the registered read value is then made available and readiness is released.

### 17.3 Current readable CSR set

| Address | CSR | Active baseline behavior |
|---:|---|---|
| `0xB00` | `mcycle` | low 32 bits, read |
| `0xB80` | `mcycleh` | high 32 bits, read |
| `0xB02` | `minstret` | low 32 bits, read |
| `0xB82` | `minstreth` | high 32 bits, read |
| `0xF11` | `mvendorid` | fixed inherited ASCII-like value |
| `0xF12` | `marchid` | fixed inherited ASCII-like value |
| `0xF13` | `mimpid` | fixed inherited ASCII-like value |
| `0xF14` | `mhartid` | fixed inherited ASCII-like value |
| `0x300` | `mstatus` | fixed `0x0000_1800` |
| `0x301` | `misa` | fixed RV32I identity |
| `0x305` | `mtvec` | read/write |
| `0x341` | `mepc` | read/write |
| `0x342` | `mcause` | read/write |

Only `mtvec`, `mepc`, and `mcause` are writable in the active implementation. Unsupported CSR addresses return zero and do not raise illegal-instruction.

### 17.4 Approved cleanup machine-identification CSR policy

The inherited/upstream-oriented fixed identification values shall be replaced by the following cleanup-target values:

| Address | CSR | Approved cleanup value | Policy meaning |
|---:|---|---:|---|
| `0xF11` | `mvendorid` | `0x0000_0000` | No assigned JEDEC vendor identity is claimed by this project. |
| `0xF12` | `marchid` | `0x0000_0000` | No globally allocated nonzero architecture ID is claimed. |
| `0xF13` | `mimpid` | `0x0001_0000` | Project-owned implementation revision, initially encoding cleanup CPU version 1.0.0. |
| `0xF14` | `mhartid` | `0x0000_0000` | The current SoC contains one hart and assigns it hart ID 0. |

These are cleanup-target values, not evidence that the active baseline RTL already returns them.

`mimpid` is the project-owned revision identifier. If the CPU implementation meaningfully changes after this cleanup milestone, its versioning policy shall be updated explicitly rather than silently reusing `0x0001_0000` forever.

### 17.5 Approved cleanup policy for machine counters

`mcycle/mcycleh/minstret/minstreth` shall remain a **read-only project subset for this cleanup milestone**. Writable machine-counter semantics are out of scope for this pass.

The approved write behavior is **write-ignore**:

```text
read counter CSR   -> return current counter value
write counter CSR  -> instruction completes without changing the counter
trap               -> no trap is generated solely because the write targeted one of these supported counter CSRs
```

This is an intentional project policy for the cleanup baseline rather than a claim of full privileged-architecture conformance. The counters continue to advance only through their normal hardware counting rules.

This write-ignore exception applies only to these **recognized, supported read-only project CSRs**. It does not make arbitrary CSR addresses legal. Unsupported CSR addresses and other rejected CSR encodings remain subject to the illegal-instruction policy defined by the cleanup legality contract.

### 17.6 Machine interrupt CSRs absent

The active baseline does not implement:

```text
mie
mip
functional mstatus.MIE/MPIE
```

Those features remain owned by the future CPU-interrupt/PLIC contract.

---

## 18. Synchronous Exception Detection

`ExceptionDetector` evaluates ID, EX, and MEM candidates with combinational priority:

```text
MEM > EX > ID
```

Implemented or partially implemented events include ECALL, EBREAK, MRET control, JAL/JALR instruction-address misalignment, and load/store address misalignment.

Current missing/incomplete coverage includes:

- illegal instructions,
- invalid CSR accesses / illegal CSR writes,
- taken-branch target misalignment,
- instruction/load/store access faults from bus errors.

For SYSTEM `funct3=000`, EBREAK is classified through an immediate-bit test rather than an exact canonical instruction match, allowing ambiguous noncanonical encodings. Cleanup shall replace this with exact legal instruction classification.

---

## 19. Trap Controller Baseline and Approved Cleanup Direction

The current trap controller is a multi-cycle pre-trap-handling FSM with states including:

```text
IDLE
WRITE_MEPC
WRITE_MCAUSE
READ_MTVEC
GOTO_MTVEC
READ_MEPC
RETURN_MRET
MEM_STANDBY
WB_STANDBY
RTRE_STANDBY
ECALL_MEPC_WRITE
```

### 19.1 Ordinary exception path

Conceptually:

```text
capture mepc
 -> write mcause
 -> read mtvec
 -> assert trap target / pipeline flush
 -> resume from handler
```

Non-ECALL ordinary exceptions use `MEM_pc` for the initial `mepc` write in the active FSM.

### 19.2 ECALL drain path

ECALL first enters standby states that hold younger pipeline state while older stages progress. The controller later writes `EX_pc` as ECALL `mepc`, writes cause 11, reads `mtvec`, and redirects. Precise PC ownership under simultaneous stalls remains mandatory verification.

### 19.3 Current cause values

| Event | `mcause` |
|---|---:|
| instruction-address misaligned | 0 |
| EBREAK | 3 |
| load-address misaligned | 4 |
| store-address misaligned | 6 |
| ECALL from M-mode | 11 |

### 19.4 EBREAK — approved cleanup target

Active baseline behavior is project-local: EBREAK sets `debug_mode` and does not follow ordinary `mtvec` redirection.

**Approved cleanup target:** remove this project-local special case from the architectural trap path. Until a real RISC-V Debug architecture is separately specified and implemented, EBREAK shall behave as an ordinary breakpoint exception:

```text
EBREAK
 -> precise mepc
 -> mcause = 3
 -> mtvec redirect
```

A future Debug Module, if added, shall be specified independently rather than reusing this legacy `debug_mode` shortcut.

### 19.5 MRET baseline deviation

Active baseline computes:

```text
trap_target = {mepc[31:2], 2'b00} + 4
```

Cleanup shall return to architectural `mepc` rather than unconditional `mepc+4`. Full MIE/MPIE restoration remains part of the future interrupt/PLIC stage unless separately promoted.

**Phase 4A-3B3R frozen policy:** This RV32I core has no compressed extension and fixed IALIGN=32. Architectural `mepc[1:0]` is always zero: normal CSR and trap-service writes store `write_data & 32'hFFFF_FFFC`, and CSR reads expose that canonical value. MRET returns to the exact stored/canonicalized `mepc`, without `+4` or an additional MRET target mask; attempted unaligned low-bit writes do not create an MRET nested trap. In particular, a write of `0x0000_0012` reads back and returns to `0x0000_0010`. Branch/JAL/JALR cause-0 target alignment rules remain separate and unchanged.

**Phase 4A-3B3R implementation evidence:** The active CSR storage boundary now enforces this policy, and the focused CPU/storage tests, predecessor regressions and user-run Quartus internal fit/STA pass. MRET retires once at its accepted redirect edge and increments `minstret` once. The preceding `mepc+4` description records the historical defect, not current implementation. **Phase 4A-3B-CLOSE** verified representative bus/APB/load-use/CSR stall and competing fault/redirect interactions, closing `TRAP-002` without claiming exhaustive Cartesian proof. External I/O, firmware and board acceptance remain separate.

### 19.6 FENCE / FENCE.I — approved cleanup target

Active FENCE-family behavior is effectively inert; `ic_clean` is inactive. The current CPU has no cache and runtime IMEM is not software-writable.

**Approved cleanup target:** both FENCE and FENCE.I are legal no-ops for this cacheless/runtime-immutable memory architecture. They shall retire normally and shall not raise illegal-instruction merely because no cache-maintenance hardware is present.

This policy must be revisited when caches, DMA-visible coherency, writable instruction memory, or a stronger memory-ordering contract is introduced.

**Phase 4A-3B3R active status:** FENCE and FENCE.I both retire as legal no-ops in the directed regression. `TRAP_FENCEI` is an unused legacy macro; `Trap_Controller.v` and its `ic_clean` output are uninstantiated in the active CPU. They do not create an architectural trap or cache-clean action.

---

## 20. AHB/MMIO Boundary Summary

Relevant CPU outputs include:

```text
EX_memory_read_AHB
EX_memory_write_AHB
EX_alu_result_AHB
EX_funct3_AHB
CUSTOM_WRITE_MASK
data_memory_read_data_AHB   // semantically HWDATA
oBRAM_HAZARD
```

Bus-interface quirks already owned by `cpu_interface.md` include:

- `EX_funct3_AHB` declared 32 bits despite three meaningful bits,
- active `HSIZE` not driven,
- CPU does not consume `HRESP`,
- project-specific custom store mask,
- bus backpressure converted directly into full-pipeline stall.

---

## 21. Current Supported / Incomplete ISA Contract

The datapath contains execution support for ordinary RV32I families, CSR read/modify/write forms, ECALL/EBREAK/MRET-related control behavior, and FENCE-family decode.

This is not a complete compliance claim because legality, traps, CSR rules, JALR, register shifts, privileged semantics, and bus access-fault handling remain incomplete in the active RTL.

The appropriate project description remains a locally modified RV32I-oriented five-stage CPU baseline.

---

## 22. Reset and Initial-State Contract

On CPU reset, the implementation establishes at least:

- PC = 0,
- pipeline registers = NOP / zero control state,
- exception detector = no trap,
- trap FSM = IDLE,
- mtvec = `0x0000_6D60`,
- mepc/mcause = 0,
- mcycle/minstret = 0,
- CSR processing state = idle.

The GPR array itself is not cleared by CPU/system reset and shall remain architecturally unspecified under the approved cleanup policy.

The active baseline has no external-interrupt state to reset.

---

## 23. Timing and Performance-Critical Behavior

The principal project-local timing decision is the one-cycle load-use interlock. The earlier same-cycle load forwarding path traversed memory/fabric return, load extraction, forwarding, and dependent EX/control-flow logic. The active core instead waits one cycle and forwards from WB.

Historical project measurements associated with this change improved reported Fmax approximately:

```text
43.06 MHz -> 51.35 MHz
```

The exact value is build dependent; the architectural contract is the synchronous-memory-friendly one-cycle load-use policy.

Other timing-sensitive structures include full-pipeline HREADY stall fanout, branch/jump EX redirect, trap/CSR control, forwarding muxes, and the CPU-to-DMEM BRAM RAW sideband.

---

## 24. Verification Requirements

Cleanup-grade CPU regression shall cover at minimum:

### Integer execution

- every implemented ALU operation,
- signed/unsigned comparisons,
- immediate shifts at 0/31,
- register shifts with rs2 = 0/31/32/33/63/large,
- LUI/AUIPC,
- JAL/JALR link and target,
- all six branch conditions.

### Pipeline dependencies

- MEM/WB forwarding for both operands,
- MEM-over-WB priority,
- store-data forwarding,
- same-cycle WB-to-ID bypass,
- one-cycle load-use for ALU/branch/JALR/store-data/relevant CSR consumers,
- no false load-use stall for unused fields.

### Bus interaction

- load/store address stage vs data stage,
- full-pipeline hold for APB wait states,
- bus stall coincident with branch/jump flush,
- bus stall coincident with trap completion,
- BRAM store-to-load RAW merge.

### Decode legality

- unsupported opcodes,
- reserved R-type funct7,
- invalid OP-IMM shift encodings,
- invalid LOAD/STORE funct3,
- invalid JALR funct3,
- noncanonical SYSTEM encodings,
- invalid CSR address/write attempts.

### Exceptions / traps

- ECALL precise mepc/mcause,
- EBREAK precise mepc + mcause=3 + mtvec redirect,
- MRET target,
- JAL/JALR/branch alignment,
- load/store misalignment,
- illegal instruction,
- access faults after HRESP integration,
- trap entry under load-use/CSR/bus stalls.

### FENCE policy

- FENCE retires as a legal no-op,
- FENCE.I retires as a legal no-op,
- neither creates a false cache-maintenance side effect in the current cacheless implementation.

### Retirement / counters

- mcycle during normal execution and bus stalls,
- minstret counts a real architectural NOP,
- flushed bubbles do not increment minstret,
- no double retirement while MEM/WB is held,
- mcycle/minstret family writes complete without changing the counter value,
- supported counter writes do not raise illegal-instruction solely because the target is read-only under the project policy.

### Reset / identification

- GPR contents are not assumed zero after system reset,
- `mvendorid = 0x0000_0000`,
- `marchid = 0x0000_0000`,
- `mimpid = 0x0001_0000`,
- `mhartid = 0x0000_0000`.

---

## 25. Baseline Cleanup Targets

| Area | Priority | Required direction |
|---|---|---|
| register shift amount | High | Mask register-based shift amount to `rs2[4:0]`. |
| instruction legality | High | Add deterministic legality checks and illegal-instruction exception. |
| JALR target | High | Clear target bit 0 before final alignment checking/redirection. |
| branch alignment | High | Detect taken branch target misalignment for active IALIGN. |
| retirement validity | High | Add explicit valid/commit semantics so real NOPs count and bubbles do not. |
| precise trap entry | High | Verify/fix mepc ownership under exceptions and stalls. |
| MRET | High | Remove unconditional `mepc + 4`. |
| EBREAK | High | Normalize to precise breakpoint exception with `mcause=3` and `mtvec` redirect. |
| bus access faults | High | Consume approved bus error and map to access faults. |
| CSR legality | Medium/High | Unsupported CSR addresses/illegal encodings trap; recognized project read-only CSRs may use explicitly specified write-ignore behavior. |
| counter write policy | Medium | Keep mcycle/minstret family read-only; writes are legal no-effect/write-ignore for this cleanup pass. |
| machine IDs | Medium | Set `mvendorid=0`, `marchid=0`, `mimpid=0x0001_0000`, `mhartid=0`. |
| FENCE/FENCE.I | Medium | Treat as legal no-ops for current cacheless/runtime-immutable architecture. |
| SYSTEM decode | Medium | Replace bit-based EBREAK classification with exact legal encoding checks. |
| GPR reset | Low/policy | Preserve unspecified x1..x31 contents after system reset; do not add reset clear. |
| unused hazard/debug state | Low | Remove or justify dead/legacy hazard, debug, and trap artifacts. |
| CPU interface naming/width | Medium | Normalize `EX_funct3_AHB` width and misleading HWDATA naming. |

`baseline_cleanup.md` owns implementation status and deduplication with existing BUS/TRAP entries.

---

## 26. Future PLIC Boundary

The active CPU has no external interrupt input in the baseline architecture.

Before PLIC integration, a dedicated specification shall define:

- external interrupt acceptance point,
- pipeline precision / drain behavior,
- `mstatus.MIE/MPIE`,
- `mie` / `mip`,
- interrupt `mcause`,
- exception-vs-interrupt priority,
- interrupt acceptance during bus stalls,
- MRET interrupt-state restoration.

The frozen legacy PLIC snapshot is reference-only and shall not override this CPU specification.

---

## 27. Baseline Invariants

Until cleanup implementation is verified, the following describe the **active baseline**, even where the approved target differs:

1. Single-issue five-stage RV32I-oriented pipeline.
2. Branch prediction inactive.
3. Branch/jump resolved in EX; taken redirects flush two younger stages.
4. MEM non-load results may forward directly to EX; MEM load data does not.
5. Immediate load consumer receives one interlock cycle and WB forwarding.
6. Bus stall freezes all pipeline stages and suppresses flush progression.
7. x0 is hardwired zero; same-cycle WB-to-ID bypass exists.
8. System reset does not explicitly clear GPR array.
9. Pipeline bubbles use architectural NOP encoding and there is no explicit valid bit.
10. Real `ADDI x0,x0,0` currently fails to increment minstret.
11. Register-register shifts currently do not explicitly mask rs2 to five bits.
12. Illegal-instruction handling is incomplete.
13. JALR currently redirects using raw sum without bit-0 clearing.
14. Taken-branch misalignment checking is inactive.
15. CSR support is a partial machine-mode subset.
16. Active EBREAK still uses project-local debug behavior.
17. Active MRET still redirects to aligned `mepc + 4`.
18. Active FENCE-family behavior is inert but not yet validated as the approved legal-no-op contract.
19. Active machine-identification CSRs still carry inherited ASCII-like values.
20. No asynchronous external-interrupt path is active.

---

## 28. Approved Cleanup Policy Decisions

The following policy choices are approved by the specification owner and supersede the previous open-clarification list.

| Decision | Approved target |
|---|---|
| `CPU-DECISION-01` GPR reset | Retain architecturally unspecified x1..x31 contents after system reset; startup software establishes required state. |
| `CPU-DECISION-02` machine identification | `mvendorid=0x0000_0000`, `marchid=0x0000_0000`, `mimpid=0x0001_0000`, `mhartid=0x0000_0000`. |
| `CPU-DECISION-03` FENCE / FENCE.I | Legal no-ops for the current cacheless/runtime-immutable instruction-memory architecture. |
| `CPU-DECISION-04` EBREAK | Ordinary breakpoint exception: precise `mepc`, `mcause=3`, redirect through `mtvec`; legacy custom `debug_mode` is not the cleanup architectural behavior. |
| `CPU-DECISION-05` machine counters | Keep `mcycle/mcycleh/minstret/minstreth` read-only for this cleanup milestone. Writes to these recognized counter CSRs are legal no-effect/write-ignore operations and do not trap solely because the CSR is read-only under this project policy. |

### 28.1 Machine-identification versioning rule

The exact cleanup values are now frozen. `mvendorid` and `marchid` intentionally do not claim external allocations; `mhartid=0` reflects the current single-hart SoC. `mimpid=0x0001_0000` is the project-owned implementation revision for this cleanup CPU baseline.

A later CPU revision may change `mimpid`, but any change shall be explicit in the canonical CPU specification and regression expectations.

## Phase 4A-2 Approved Load/Store Access-Fault Contract (active Phase 4A-3A bus-access scope)

On final project AHB ERROR completion (`HRESP=2'b01`, final `HREADY=1`), a load traps with `mcause=5` and a store/AMO with `mcause=7`; `mepc` is the faulting instruction PC. Failed loads never write a destination GPR, failed stores have no memory/peripheral side effect, and failed instructions do not retire successfully. Existing misaligned load/store causes 4/6 take precedence and remain distinct. Instruction fetch does not use the AHB data path, so this contract does not create an instruction-fetch AHB fault. Phase 4A-3A verifies load/store bus faults; AMO and broader CPU correctness are not thereby claimed.

**Phase 4A-3A status:** load/store bus access faults, exact faulting `mepc`, writeback/younger-stage suppression, and misalignment priority are verified in directed CPU and CPU+SoC tests. This does not verify AMO support, general precise retirement (`CPU-005`), illegal-instruction handling (`CPU-009`), or all of `TRAP-003`.
