# Baseline SoC Interrupt and Trap Architecture Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and updated with approved CPU cleanup policies.
>
> **Canonical language:** English. If this file and `interrupt_architecture.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `cpu_interface.md`, `ahb_fabric.md`, `apb_subsystem.md`, `reset_clock.md`.
>
> **Detailed CPU microarchitecture:** `cpu_core.md`.

> **Phase 4A-3A reading rule:** Earlier missing-bus-fault descriptions are pre-cleanup observations; the final fault/IRQ boundary section records the now-verified data-bus access-fault sub-scope. Illegal-instruction, branch-alignment, and PLIC work remain open.

## 1. Purpose

This document defines the interrupt/trap architecture of the active FPGA baseline and the approved synchronous-trap cleanup direction before PLIC integration. It separates:

- synchronous CPU exceptions/trap-like control events implemented today,
- approved cleanup behavior for those synchronous events,
- asynchronous interrupts that are **not** implemented in the active baseline,
- current and cleanup-target CSR policy relevant to trap handling,
- trap entry and return behavior,
- peripheral polling behavior,
- legacy PLIC reference material,
- the explicit boundary between baseline cleanup and the future PLIC stage.

The active baseline shall not be described as complete RISC-V privileged-architecture compliance.

## 2. Terminology

For this project:

- **Exception**: a synchronous event caused by the instruction currently executing or by its architectural effects.
- **Interrupt**: an asynchronous request originating from a peripheral or external source.
- **Trap**: the generic control transfer used to handle an exception or interrupt.

The active baseline implements only the synchronous side of this model.

## 3. Baseline Summary

The active FPGA baseline has:

```text
CPU synchronous exception detection
        |
        v
ExceptionDetector
        |
        v
TrapController
        |
        +--> mepc / mcause / mtvec CSR accesses
        +--> pipeline stall / flush control
        +--> trap_target
```

The active baseline does **not** have:

- external interrupt request input to the active CPU,
- PLIC in the active SoC address map,
- `mie`,
- `mip`,
- functional `mstatus.MIE/MPIE` interrupt-enable state,
- peripheral IRQ routing into the CPU,
- interrupt claim/complete behavior,
- CPU-visible bus-error-to-access-fault propagation.

Therefore the active baseline is **synchronous-trap capable, interrupt-incomplete**.

## 4. Active Exception Detector

The active `ExceptionDetector` evaluates candidate synchronous events in ID, EX, and MEM stages.

Its combinational priority is:

```text
MEM-stage exception
    > EX-stage exception
        > ID-stage exception
```

The selected result is registered into:

```text
trapped
trap_status[2:0]
```

before being consumed by the trap-control path.

The exact pipeline precision of `mepc` ownership under simultaneous bus/CSR/load-use/control-flow stalls remains a cleanup verification requirement and is further detailed by `cpu_core.md`.

## 5. Implemented Trap/Event Codes

`rtl/core/vh/trap.vh` currently defines:

| Internal code | Name | Active baseline meaning |
|---|---|---|
| `3'b000` | `TRAP_NONE` | No active trap |
| `3'b001` | `TRAP_EBREAK` | EBREAK event |
| `3'b010` | `TRAP_ECALL` | ECALL event |
| `3'b011` | `TRAP_MISALIGNED_INSTRUCTION` | Instruction-address misalignment |
| `3'b100` | `TRAP_MRET` | MRET control event |
| `3'b101` | `TRAP_FENCEI` | Symbol exists, but no active detector path was found |
| `3'b110` | `TRAP_MISALIGNED_STORE` | Store-address misalignment |
| `3'b111` | `TRAP_MISALIGNED_LOAD` | Load-address misalignment |

`TRAP_MRET` is a return-control event, not an exception cause.

`TRAP_FENCEI` shall not be treated as an active architectural trap merely because the symbolic value exists. The approved cleanup policy for FENCE/FENCE.I is defined in §12.2.

## 6. Implemented Synchronous Exceptions

### 6.1 ECALL

The detector recognizes an environment instruction with `funct3 == 0` and zero immediate as ECALL.

The trap controller records:

```text
mcause = 11
```

and vectors through `mtvec` after its ECALL-specific standby/drain sequence.

### 6.2 EBREAK — active baseline

EBREAK is recognized as an environment instruction and records:

```text
mcause = 3
```

The active trap controller does **not** vector EBREAK through `mtvec` in the same way as ordinary exceptions. It instead enables a project-local `debug_mode` state and exits the pre-trap handler.

This is baseline behavior only and is not a complete RISC-V Debug Specification implementation.

### 6.3 Misaligned Load

The detector generates load-address-misaligned behavior for:

- `LH` / `LHU` when address bit 0 is set,
- `LW` when address bits `[1:0] != 2'b00`.

The trap controller records:

```text
mcause = 4
```

### 6.4 Misaligned Store

The detector generates store-address-misaligned behavior for:

- `SH` when address bit 0 is set,
- `SW` when address bits `[1:0] != 2'b00`.

The trap controller records:

```text
mcause = 6
```

### 6.5 Instruction-Address Misalignment

The active detector checks JAL/JALR targets for 4-byte alignment and produces:

```text
mcause = 0
```

for a detected misaligned instruction target.

The historical branch-target misalignment check exists only as commented-out detector code. Therefore branch-target misalignment detection is incomplete in the active baseline.

The detailed JALR bit-0 issue is owned by `cpu_core.md`: cleanup shall clear JALR target bit 0 before final IALIGN=32 checking.

## 7. Exceptions Not Implemented as Active Baseline Contracts

The active baseline does not provide a complete implementation of the standard machine-mode exception set.

Notably absent or incomplete are:

- illegal instruction exception (`mcause=2`),
- instruction access fault,
- load access fault,
- store/AMO access fault,
- normal breakpoint-to-`mtvec` behavior,
- complete branch-target instruction-misalignment handling,
- bus-error-to-exception propagation,
- deterministic illegal CSR-access behavior.

`TRAP_ILLEGAL_INSTRUCTION` is commented out in the active trap encoding header, and the detector does not currently generate an illegal-instruction trap.

These are cleanup defects/omissions, not approved long-term behavior.

## 8. CSR Baseline and Cleanup Policy

### 8.1 Trap-relevant active baseline CSRs

The active `CSRFile` exposes the following relevant machine CSRs:

| CSR | Address | Active baseline behavior |
|---|---:|---|
| `mstatus` | `0x300` | Read-only constant `0x0000_1800` |
| `misa` | `0x301` | Read-only RV32I identity value |
| `mtvec` | `0x305` | Read/write |
| `mepc` | `0x341` | Read/write |
| `mcause` | `0x342` | Read/write |

The reset value of `mtvec` is:

```text
0x0000_6D60
```

The active baseline does **not** implement:

```text
mie  (0x304)
mip  (0x344)
```

and `mstatus` does not provide functional interrupt-enable state transitions.

Therefore machine-mode interrupt masking/enabling semantics are absent from the current active CPU.

### 8.2 Approved machine-identification CSR values for cleanup

The active CPU currently carries inherited ASCII-like fixed machine-identification values. The cleanup target is frozen as:

| CSR | Address | Approved cleanup value |
|---|---:|---:|
| `mvendorid` | `0xF11` | `0x0000_0000` |
| `marchid` | `0xF12` | `0x0000_0000` |
| `mimpid` | `0xF13` | `0x0001_0000` |
| `mhartid` | `0xF14` | `0x0000_0000` |

Policy meaning:

- `mvendorid=0`: the project does not claim a separately assigned JEDEC vendor ID,
- `marchid=0`: the project does not claim a globally allocated nonzero architecture ID,
- `mimpid=0x0001_0000`: project-owned cleanup CPU implementation revision 1.0.0,
- `mhartid=0`: the current SoC is single-hart and uses hart ID 0.

These values become active only after RTL cleanup and verification.

### 8.3 Approved machine-counter policy for cleanup

`mcycle/mcycleh/minstret/minstreth` remain a **read-only project subset for this cleanup milestone**. Writable machine-counter semantics are deferred.

Writes to these recognized counter CSRs use the approved **write-ignore** policy:

```text
read   -> return current counter value
write  -> complete without changing the counter value
trap   -> no trap solely because the target is one of these project-RO counter CSRs
```

This exception is limited to these supported project-RO counters. Unsupported CSR addresses and other rejected CSR encodings remain subject to the cleanup illegal-instruction policy.

## 9. Trap Entry Sequence

For ordinary synchronous exceptions, the trap controller conceptually performs:

```text
1. capture/write mepc
2. write mcause
3. read mtvec
4. present trap_target = mtvec
5. flush affected pipeline state
6. continue from trap vector
```

The active implementation uses `trap_done`, `standby_mode`, and flush outputs to coordinate with the hazard unit.

While trap handling is incomplete:

- the pipeline may be stalled,
- selected stages may be held or flushed,
- normal branch/jump progression shall not override the trap-control sequence.

Exact cycle counts are implementation details unless promoted into a verification requirement.

## 10. ECALL-Specific Drain Behavior

ECALL uses:

```text
MEM_STANDBY
  -> WB_STANDBY
      -> RTRE_STANDBY
          -> ECALL_MEPC_WRITE
```

This sequence is intended to allow older instructions to progress before writing the ECALL PC and redirecting to `mtvec`.

Cleanup shall explicitly verify precise `mepc` capture across bus stalls, APB waits, CSR stalls, load-use hazards, and simultaneous control-flow events.

## 11. MRET

### 11.1 Active baseline

The active trap controller generates:

```text
trap_target = {mepc[31:2], 2'b00} + 4
```

This does not match the intended architectural return target.

### 11.2 Approved cleanup target

Baseline cleanup shall return to the address held in `mepc` rather than unconditionally adding 4.

The cleanup milestone does **not** attempt to implement the future external-interrupt state machine. Functional `mstatus.MIE/MPIE` save/restore belongs to the dedicated PLIC/CPU-interrupt stage unless explicitly promoted by a later specification update.

### 11.3 Phase 4A-3B3R frozen `mepc` / IALIGN32 policy

This RV32I baseline does not support the compressed extension, so IALIGN is fixed at 32 bits and architectural instruction PCs are 4-byte aligned. The architectural `mepc[1:0]` value is always `2'b00`. Both normal CSR writes and trap-service writes to `mepc` store `write_data & 32'hFFFF_FFFC`; CSR reads return that canonical stored value. For example, writing `0x0000_0012` stores and reads back `0x0000_0010`.

MRET redirects to the **exact architecturally stored/canonicalized `mepc`** value, without adding 4 or applying a second target mask. It does not independently raise an instruction-address-misaligned exception due to attempted low-bit `mepc` writes; no nested MRET-alignment trap is defined in this baseline. Cause 0 remains applicable to taken branch, JAL, and post-bit-0-cleared JALR target misalignment under IALIGN32. This storage policy does not change precise fault-PC ownership or future interrupt-state restoration scope.

**Phase 4A-3B3R implementation status:** Canonical storage/readback and exact MRET redirect/one-shot retirement passed the directed CPU/storage suites; the user-run Quartus fit and internal multicorner STA passed. The older `mepc+4` and project-local EBREAK descriptions above are retained as historical baseline observations, not current active behavior. Phase 4A-3B-CLOSE subsequently verified representative bus/APB/load-use/CSR stall and competing fault/redirect interactions; `TRAP-002` is VERIFIED without claiming exhaustive Cartesian proof.

## 12. EBREAK and FENCE Cleanup Policy

### 12.1 EBREAK — approved cleanup target

The project-local `debug_mode` shortcut is not retained as the architectural cleanup behavior.

Until a real RISC-V Debug architecture is separately specified, EBREAK shall behave as an ordinary breakpoint exception:

```text
EBREAK
 -> precise mepc
 -> mcause = 3
 -> mtvec redirect
```

SYSTEM decode shall use exact legal instruction classification rather than the active immediate-bit shortcut.

### 12.2 FENCE / FENCE.I — approved cleanup target

The current CPU has:

- no data cache,
- no instruction cache,
- runtime-immutable instruction memory in the active SoC.

Therefore the cleanup contract is:

```text
FENCE   = legal no-op
FENCE.I = legal no-op
```

Both shall retire normally and shall not be routed through `TRAP_FENCEI` merely because no cache-maintenance hardware exists.

`TRAP_FENCEI`, `ic_clean`, and related dormant logic may be removed or clearly marked legacy/inactive if they are no longer needed after cleanup.

**Phase 4A-3B3R active status:** EBREAK takes the precise cause-3 trap/`mtvec` path, exact SYSTEM legality is checked, and FENCE/FENCE.I retire as no-ops. `TRAP_FENCEI` is an unused legacy macro; the legacy `Trap_Controller.v` containing `debug_mode`/`ic_clean` is uninstantiated in the active CPU.

This policy shall be revisited when cache/coherency, writable instruction memory, DMA-visible ordering, or a stronger memory-ordering architecture is introduced.

## 13. Peripheral Interrupt Status

Active baseline peripherals do not feed IRQs into the CPU.

### 13.1 Timer

The active APB timer exposes a software-visible `READY` status bit but has no active `irq` output port. Software therefore uses polling/clearing behavior.

### 13.2 Other APB Peripherals

UART, GPIO, G-sensor, AES-GCM, ADC joystick, and HEX are likewise polling/control MMIO blocks in the active baseline. No active top-level IRQ aggregation path exists.

Approved board-I/O target work may create local `gpio_irq` and `sw_irq` wires, but those wires remain disconnected from CPU interrupt acceptance until the future PLIC stage.

## 14. Bus Error Relationship

The active AHB-style fabric may return default zero/OKAY for unmapped accesses, and the active CPU master does not consume `HRESP`.

Consequently:

```text
unmapped / bus error
    X
CPU access-fault trap
```

Baseline cleanup shall implement frozen A2 default/error response policy and connect relevant data-bus errors to the approved CPU access-fault exception path. This work is part of the baseline cleanup gate and is independent of PLIC.

## 15. No Active PLIC

The active FPGA baseline contains no PLIC instance and allocates no canonical PLIC MMIO region.

Frozen reference material exists under:

```text
verification/legacy/plic_snapshot/
```

with review entry point:

```text
docs/review/plic_handoff.md
```

These files are reference evidence only. In particular, the minimal legacy testbench decode at `0x5000_0000` is **not** an approved architectural address.

## 16. PLIC Integration Contract to Be Defined Later

Before PLIC RTL is integrated into the active SoC, a dedicated approved PLIC specification shall define at minimum:

1. canonical PLIC base address and aperture,
2. interrupt source list and source IDs,
3. source polarity and level/edge policy,
4. pending-bit behavior,
5. per-source enable behavior,
6. priority encoding,
7. threshold behavior,
8. claim/complete semantics,
9. CPU external-interrupt input contract,
10. functional `mstatus.MIE/MPIE`, `mie`, and `mip` behavior,
11. `mcause` interrupt encoding,
12. precise interrupt-entry point / pipeline drain policy,
13. interrupt-vs-synchronous-exception priority,
14. interrupt acceptance while AHB/APB is stalled,
15. full MRET interrupt-state restoration,
16. reset behavior,
17. firmware ISR contract,
18. directed verification and FPGA acceptance tests.

The frozen legacy PLIC implementation may inform these decisions but shall not define them by precedent.

## 17. Baseline Cleanup Targets and PLIC Boundary

### 17.1 Baseline-cleanup gate

The following are baseline-cleanup work:

1. **MRET target correction** — remove active `mepc + 4`; return to `mepc`.
2. **Precise synchronous trap entry** — verify/fix which PC is captured for each exception under stalls.
3. **Instruction legality** — implement deterministic illegal-instruction behavior for invalid opcode/funct3/funct7/shift/SYSTEM/CSR encodings.
4. **Control-flow alignment** — implement JALR bit-0 clearing and taken-branch alignment checking.
5. **Bus access faults** — connect approved error response behavior to load/store access-fault exceptions.
6. **EBREAK normalization** — precise `mepc`, `mcause=3`, `mtvec` redirect.
7. **FENCE/FENCE.I normalization** — legal no-op behavior; remove/retire ambiguous `TRAP_FENCEI`/`ic_clean` usage.
8. **Retirement validity** — introduce explicit valid/commit semantics so real NOPs are counted and bubbles are not.
9. **Machine identification** — implement the approved values in §8.2.
10. **Machine counter policy** — preserve the read-only counter subset and implement/verify the §8.3 legal no-effect/write-ignore behavior.
11. **Trap sequencing under stalls** — APB waits, bus stalls, CSR stalls, load-use stalls, and simultaneous redirects.

### 17.2 Deferred to dedicated PLIC stage

The following are **not** baseline-cleanup requirements:

- functional `mstatus.MIE/MPIE`,
- `mie`,
- `mip`,
- external IRQ acceptance,
- interrupt `mcause`,
- exception-vs-interrupt priority,
- PLIC MMIO/source/priority/threshold/claim-complete,
- full MRET interrupt-state restoration.

This separation prevents the cleanup milestone from silently turning into the PLIC implementation stage.

## 18. Baseline Invariants

Until cleanup implementation is verified, the following describe the **active FPGA baseline**:

1. No asynchronous CPU interrupt path is active.
2. No PLIC address is canonical.
3. `mie` and `mip` are absent from the active baseline.
4. `mstatus` is not a functional interrupt-enable state register.
5. Timer service is polling-based.
6. Synchronous trap handling uses `mtvec`, `mepc`, and `mcause`.
7. ECALL records cause 11.
8. Misaligned load/store causes are 4/6.
9. Instruction-address misalignment records cause 0 when detected.
10. EBREAK still uses project-local debug-mode behavior in active RTL.
11. MRET still redirects to aligned `mepc + 4` in active RTL.
12. FENCE-family behavior is inert and not yet verified against the approved legal-no-op target.
13. Machine-identification CSRs still use inherited values in active RTL.
14. Legacy PLIC source/tests remain reference-only.

## 19. Approved Cleanup Policy Summary

```text
GPR reset              : x1..x31 unspecified after system reset
mvendorid              : 0x0000_0000
marchid                : 0x0000_0000
mimpid                 : 0x0001_0000
mhartid                : 0x0000_0000
FENCE                   : legal no-op
FENCE.I                 : legal no-op
EBREAK                  : precise breakpoint exception -> mtvec
MRET cleanup target     : PC <- mepc
mcycle/minstret family  : read-only; writes are legal no-effect/write-ignore and do not trap solely for project-RO status
```

The detailed CPU-local contract remains `cpu_core.md`.

## 20. Related Specifications

This document shall remain consistent with:

- `soc_architecture.md`
- `memory_subsystem.md`
- `cpu_interface.md`
- `ahb_fabric.md`
- `apb_subsystem.md`
- `reset_clock.md`
- `firmware_contract.md`
- `cpu_core.md`
- `baseline_cleanup.md`
- future approved PLIC-specific specification

## Phase 4A-2 Approved Fault/IRQ Boundary (data-bus fault active Phase 4A-3A)

A2 data-bus ERROR is a synchronous exception, not an external interrupt: load/store access faults use `mcause=5/7`, faulting-instruction `mepc`, no failed-load writeback, no failed-store side effect, and no successful retirement. Misalignment causes 4/6 remain distinct and precede bus fault handling. A1 exposes local `gpio_irq` at the SoC boundary, but it is not connected to the CPU before the separate PLIC phase. No PLIC source ID or CPU interrupt routing is defined by this freeze.

**Phase 4A-3A status:** directed CPU and SoC tests verify the data-bus access-fault sub-scope. This does not close `TRAP-003`: illegal-instruction and taken-branch alignment cases remain open, and PLIC/IRQ routing is unchanged.
