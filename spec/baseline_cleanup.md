# SoC Baseline Cleanup Plan and Tracker

> **Status:** ACTIVE DRAFT TRACKER — consolidated from the reconstructed baseline specifications and approved target contracts.
>
> **Canonical language:** English. If this file and `baseline_cleanup.ko.md` conflict, this file is authoritative.
>
> **Authority:** This file coordinates cleanup work. Detailed behavior remains owned by the corresponding canonical specification under `spec/`. If this tracker and a canonical specification disagree, update the specification first and then synchronize this tracker.

## 1. Purpose

This is the central implementation and verification tracker for the one-time **baseline cleanup pass** that shall occur after specification reconstruction and before major PLIC or AXI feature integration.

```text
reconstructed/approved specs
          |
          v
 baseline_cleanup.md
          |
          v
 RTL + firmware cleanup
          |
          v
 directed DV / CDC / STA
          |
          v
 Quartus FPGA integration
          |
          v
 board acceptance + evidence
          |
          +--> PLIC stage
          +--> AXI stage
```

A code edit or successful Quartus compile alone does not close an item. Completion requires the stated verification evidence and the global exit gate below.

## 2. Scope Control

### 2.1 Gate classes

| Gate | Meaning |
|---|---|
| `BC` | Baseline-cleanup gate. Must be resolved/verified before PLIC/AXI becomes the next stable stage. |
| `PLIC` | Deferred to the dedicated PLIC/interrupt stage. |
| `AXI` | Deferred to AXI/DMA/external-memory migration. |
| `OPT` | Non-gating hygiene or optional future enhancement. |

### 2.2 Severity

| Severity | Meaning |
|---|---|
| `Blocker` | Architecture/integration dependency that prevents cleanup closure. |
| `High` | Correctness, CDC, security, protocol, or software-contract issue that normally shall be fixed in cleanup. |
| `Medium` | Determinism, maintainability, interface-quality, or verification debt that should be resolved when the area is touched. |
| `Low` | Hygiene/refactoring/documentation issue that may be deferred if correctness is unaffected. |

### 2.3 Status

```text
OPEN        not started
BLOCKED     waiting on a named decision/dependency
IN_PROGRESS implementation or verification active
VERIFIED    implementation + required evidence reviewed
DEFERRED    intentionally moved to PLIC / AXI / optional future work
```

A `BC` item shall not be marked `DEFERRED` without an explicit specification-owner decision and documented rationale.

## 3. Cleanup Exit Gate

Cleanup closes only when:

1. every `BC` `Blocker`/`High` item is `VERIFIED`,
2. remaining `BC Medium` items are `VERIFIED` or explicitly accepted with rationale,
3. target board-I/O ownership is internally consistent,
4. the approved 16-slot APB map is active,
5. unsafe multi-bit CDC paths identified by the specs are removed or replaced with verified CDC structures,
6. reset release and generated-clock constraints are reviewed for every active domain,
7. directed RTL/firmware regressions pass,
8. Quartus/TimeQuest review has no unexplained cleanup-relevant critical warning,
9. the cleanup FPGA image passes the required board-acceptance matrix,
10. target text is promoted to active behavior only after implementation evidence exists,
11. source commit, firmware build, IMEM/DMEM images, SOF, timing, and board evidence are linked.

## 4. Recommended Implementation Order

```text
Phase A — architecture decisions APPROVED/FROZEN (implementation not verified)
  A1 GPIO width / expansion-header pins
  A2 bus default-slave / access-fault policy
  A3 VGA framebuffer read/subword policy
  A4 UART TX-busy write policy
  A5 timer start/restart semantics
  A6 private-SPI timing retention vs refactor

Phase B — cross-cutting infrastructure
  B1 CPU correctness / legality / retirement
  B2 AHB decode / HSIZE / bus error
  B3 APB 8 -> 16 slots
  B4 reset / CDC infrastructure
  B5 timing constraints

Phase C — board I/O
  true GPIO -> SW -> LED -> local IRQ wires

Phase D — peripheral correctness
  VGA / UART / Timer / G-sensor / SPI / AES-GCM / ADC / HEX

Phase E — firmware migration
Phase F — regression / Quartus / board acceptance / report
```

The CPU policy choices in `21_cpu_core.md` are no longer blocking architecture questions: GPR reset, machine-identification values, FENCE/FENCE.I, EBREAK, and machine-counter write semantics are approved. They now appear below as implementation/verification work.

---

# Part I — Cross-Cutting Bus, CPU, Reset, and Trap Cleanup

## 5. AHB / CPU / Memory Interface

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `BUS-001` | High | BC | DMEM top-level decode selects 64 KiB while canonical DMEM is 32 KiB. | Decode only `0x1000_0000..0x1000_7FFF`; remove upper alias. | `01_memory_map`, `02_memory_subsystem`, `04_ahb_fabric` | boundary/unmapped load/store tests | VERIFIED |
| `BUS-002` | High | BC | CPU master leaves `HSIZE` undriven. | Generate byte=`000`, half=`001`, word=`010` deterministically. | `03_cpu_interface`, `04_ahb_fabric`, `21_cpu_core` | LB/LBU/LH/LHU/LW/SB/SH/SW waveform tests | VERIFIED |
| `BUS-003` | Blocker | BC | Unmapped/default accesses silently complete zero/OKAY and CPU does not consume `HRESP`. | Implement frozen A2: 2-cycle `HRESP=01` ERROR, APB default error, and precise CPU load/store access faults. | `03_cpu_interface`, `04_ahb_fabric`, `05_apb_subsystem`, `07_interrupt_architecture`, `21_cpu_core` | invalid DMEM/VGA/APB/reserved access-fault tests | VERIFIED |
| `BUS-004` | Medium | BC | Top `HSEL_*` decode is address-only and can assert while `HTRANS=IDLE`. | Qualify with a valid-transfer predicate or prove equivalent safe behavior. | `03_cpu_interface`, `04_ahb_fabric` | IDLE-address/back-to-back/wait tests | VERIFIED |
| `CPU-001` | Medium | BC | `EX_funct3_AHB` width mismatch and misleading store-data naming. | Normalize width/naming without changing pipeline behavior. | `03_cpu_interface`, `21_cpu_core` | lint + memory regression | OPEN |
| `CPU-002` | Medium | AXI | `CUSTOM_WRITE_MASK` / `oBRAM_HAZARD` are CPU↔DMEM implementation sidebands. | Contain them in baseline DMEM; do not copy them as generic AXI semantics. | `02_memory_subsystem`, `03_cpu_interface`, `21_cpu_core` | RAW bypass regression; AXI-stage review | DEFERRED |
| `BUS-005` | High | BC | Stall/data-phase response routing lacks cleanup-grade directed evidence. | Prove delayed select retention and correct responses across waits and cross-slave transfers. | `03_cpu_interface`, `04_ahb_fabric`, `05_apb_subsystem`, `21_cpu_core` | MEM/APB/VGA cross-slave wait tests | VERIFIED |

### 5.1 CPU Core Correctness and Architectural Cleanup

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `CPU-003` | High | BC | Historical full-width rs2 shift count. | Mask register shift amount to `rs2[4:0]`. | `21_cpu_core` | rs2 = 0/31/32/33/63/0xFFFF_FFFF directed tests | VERIFIED |
| `CPU-004` | High | BC | Historical raw JALR target/alignment check. | Use `(rs1 + imm) & ~1` before final IALIGN=32 check and redirect. | `07_interrupt_architecture`, `21_cpu_core` | aligned/raw-...01/misaligned JALR tests | VERIFIED |
| `CPU-005` | High | BC | Historical defect: no explicit valid/commit state; real `ADDI x0,x0,0` omitted from `minstret`. | Add explicit pipeline valid/retire-valid or equivalent unambiguous commit semantics. | `21_cpu_core` | 3B2B normal scoreboard + 3B3R MRET one-shot commit/minstret/resume | VERIFIED |
| `CPU-006` | Medium | BC | Historical machine-identification CSR values were inherited ASCII-like values. | Set cleanup values: `mvendorid=0`, `marchid=0`, `mimpid=0x0001_0000`, `mhartid=0`. | `07_interrupt_architecture`, `21_cpu_core` | exact CSR readback in 3B3R | VERIFIED |
| `CPU-007` | Medium | BC | Historical FENCE-family behavior and dormant `TRAP_FENCEI/ic_clean` ambiguity. | Make FENCE and FENCE.I explicit legal no-ops; retire normally; remove/mark dormant trap/cache-clean artifacts. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R FENCE/FENCE.I retire; legacy symbols documented as uninstantiated/inactive | VERIFIED |
| `CPU-008` | Medium | BC | Historical counter-write response was unspecified. | Keep `mcycle/mcycleh/minstret/minstreth` read-only. Writes to these recognized counter CSRs are legal no-effect/write-ignore operations: counter value unchanged and no trap solely because the target is one of these project-RO counters. | `21_cpu_core` | 3B3R four-address write-ignore/value-stability/no-trap regression | VERIFIED |
| `CPU-009` | High | BC | Historical opcode/funct3/funct7/shift/SYSTEM/CSR legality gaps allowed invalid memory encodings toward bus control. | Add deterministic instruction legality, raise illegal-instruction for rejected encodings/unsupported CSR addresses, and suppress architectural/bus side effects from illegal instructions. Recognized project-RO counter writes remain the explicit `CPU-008` write-ignore exception. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R illegal opcode/funct3/funct7/shift/SYSTEM/CSR/no-bus + RO-counter exception | VERIFIED |
| `CPU-010` | Low | BC | GPR array is configuration-initialized but not system-reset-cleared. | Preserve approved policy: x1..x31 remain unspecified after system reset; do not add reset fanout solely for determinism. | `21_cpu_core`, `19_firmware_contract` | reset software does not depend on zero GPRs | OPEN |

## 6. APB Subsystem and Address Decode

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `APB-001` | Blocker | BC | Historical bridge/top used `PSEL[7:0]`; P04 completed the approved 16-slot migration. | Keep bridge/top/PRDATA/PREADY/tests at `PSEL[15:0]`; preserve slots 0..7. | `01_memory_map`, `05_apb_subsystem`, `20_board_io_architecture` | P04 one-hot slots 0..15 + cross-slot tests + post-fit review | VERIFIED |
| `APB-002` | High | BC | Ignored `PADDR[27:20]` creates repeated APB aliases. | Decode only canonical `0x4000_0000..0x400F_FFFF`. | `01_memory_map`, `04_ahb_fabric`, `05_apb_subsystem` | alias-negative tests | VERIFIED |
| `APB-003` | High | BC | New `PWDATA` is not guaranteed valid throughout APB SETUP. | Keep write address/control/data stable from SETUP through ACCESS. | `05_apb_subsystem` | SETUP/ACCESS assertions | VERIFIED |
| `APB-004` | High | BC | Reserved slots/invalid accesses can inherit silent zero/ready behavior. | Implement frozen A2 canonical full-offset validation, side-effect gating, default `PSLVERR`, and bridge ERROR propagation. | `05_apb_subsystem`, `20_board_io_architecture` | reserved slot/offset tests | VERIFIED |
| `APB-005` | Medium | BC | Low-bit peripheral decoders create register mirrors; P06B closes the Timer sub-scope and P07 closes the UART sub-scope only. | When a peripheral is touched, decode only canonical offsets and use approved reserved behavior elsewhere. | peripheral specs | Timer and both UARTs: full slot-offset decode/mirrors removed; UART architectural invalid requests produce bridge ERROR/no real PSEL/no side effect, and actual UART backpressure passes; remaining peripherals require noncanonical-offset tests | OPEN |
| `APB-006` | Medium | AXI | No `PSTRB`; generic partial-register writes are unsupported. | Preserve aligned 32-bit APB MMIO in cleanup; decide strobes later. | `05_apb_subsystem`, `19_firmware_contract` | no firmware dependency on partial APB writes | DEFERRED |

Phase 4A-3A evidence (local review archive `PHASE_4A_3A_BUS_CPU_APB_REPORT.md` and `verification_matrix_bus_cpu_apb.json`): the focused HSIZE, bridge, SoC decode, MEM/APB/VGA transition, CPU harness, and CPU+SoC fault tests pass, as do the existing open regression lanes and whole-SoC elaboration. At that checkpoint, `APB-001` and `TRAP-003` were still `IN_PROGRESS`: slot 8/9 integration and later ISA/trap coverage had not yet landed. Subsequent Phase 4A-3B/3B3R evidence closed `TRAP-003`; P04 open verification plus the user-run post-fit review closed `APB-001`. Both are now `VERIFIED`. This does not close the global cleanup exit gate.

## 7. Reset, CDC, and Timing

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `RST-001` | High | BC | Historical inconsistent assertion/release and nondeterministic cold-start risks are resolved by the P05 reset architecture. | Preserve asynchronous assertion where appropriate, HCLK/destination-synchronous release, deterministic LOW power-up, and the 1,000,000-cycle qualification. | `06_reset_clock` | P05 all-domain reset tests + fitted synchronizer/power-up + positive recovery/removal evidence | VERIFIED |
| `RST-002` | High | BC | Historical generated-domain release/PLL-ready gaps are resolved for the baseline VGA, ADC project logic, and PCLK-only G-sensor. | Preserve VGA `locked` qualification, pclk_25/adc_sys_clk local release synchronizers, vendor-managed ADC/Qsys reset, and no internal G-sensor SPI clock. | `06_reset_clock`, `08_vga`, `12_gsensor`, `13_spi`, `15_adc_joystick` | P05 lock/reset tests + fitted PLL/reset/clock inventory | VERIFIED |
| `CDC-001` | High | BC | Static CDC closure for the active VGA ownership crossing is not established. | Frame-safe CDC/ownership handshake with a defined commit boundary. | `06_reset_clock`, `08_vga` | static CDC sign-off NOT_RUN / unresolved | OPEN |
| `CDC-002` | Blocker | BC | Historical `spi_clk`→PCLK transfer was removed by A6; software still lacks an atomic X/Y/Z snapshot across two APB reads and VALID/SEQ. | Define a coherent software-visible PCLK XYZ snapshot + validity/sequence without reintroducing CDC. | `06_reset_clock`, `12_gsensor`, `19_firmware_contract` | first-sample validity, interleaved APB read/refresh and atomic XYZ tests | OPEN |
| `CDC-003` | Blocker | BC | ADC response valid/channel/data crosses `adc_sys_clk`→PCLK directly. | Coherent handshake/FIFO/snapshot + atomic XY publication. | `06_reset_clock`, `15_adc_joystick`, `19_firmware_contract` | async response/torn-sample tests | OPEN |
| `CDC-004` | Medium | BC | P05 completed the external asynchronous-input policy audit and corrected reset/AUX behavior while preserving approved synchronizers. | Preserve audited UART RX/AUX, G-sensor INT, reset-button, SW, and GPIO structures and their documented level/pulse limitations. | `06_reset_clock`, `09_uart`, `11_gpio`, `12_gsensor`, `17_sw` | P05 directed transitions/regressions + fitted 36-chain/minimum-2-register review | VERIFIED |
| `STA-001` | High | BC | Generated-clock/uncertainty constraints are incomplete. | Constrain remaining VGA/ADC generated clocks, relationships and uncertainty; remove active SPI PLL per A6; triage TimeQuest/CDC warnings. | `06_reset_clock` | TimeQuest clock/uncertainty/CDC reports after cleanup | IN_PROGRESS |
| `STA-002` | High | BC | External board-facing I/O timing/electrical requirements and ADC/VGA physical placement impact are not closed; positive internal slack is not board signoff. | Inventory every external port by sync/source-sync/async/static/analog class; justify applicable input/output delays or N/A; review IO standard, voltage, drive/load and unconstrained paths; quantify ADC/VGA impact and explicitly disposition residual critical warnings without invented SDC values. | `06_reset_clock`, `08_vga`, `09_uart`, `11_gpio`, `13_spi`, `15_adc_joystick`, `20_board_io_architecture` | TimeQuest I/O/unconstrained and QSF electrical/pin reports; ADXL345 SPI timing; ADC with VGA activity and board measurements/risk acceptance | BLOCKED |

## 8. Trap / Exception Architecture Before PLIC

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `TRAP-001` | High | BC | Historical MRET returned to `mepc + 4`. | Return to architectural canonical `mepc`; full interrupt-state restoration remains PLIC-stage work. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R ECALL/trap/MRET/resume and low-bit canonicalization | VERIFIED |
| `TRAP-002` | High | BC | Historical gap: precise `mepc`/trap sequencing under bus/APB/load-use/CSR stalls lacked interaction evidence. | Define and verify precise synchronous exception entry under simultaneous stalls/control-flow events. | `03_cpu_interface`, `07_interrupt_architecture`, `21_cpu_core` | 3B-CLOSE representative AHB/APB wait, load-use, CSR hold/drain, MEM/EX/ID priority and one-shot service matrix; no full Cartesian claim | VERIFIED |
| `TRAP-003` | High | BC | Historical illegal, branch-target misalignment and bus-access-fault coverage gaps. | Integrate `CPU-009` legality, taken-branch alignment, and `BUS-003` access faults into precise cause/PC handling. | `04_ahb_fabric`, `07_interrupt_architecture`, `21_cpu_core` | 3B3R illegal/target cause-PC + 3A/3B2A access-fault regression | VERIFIED |
| `TRAP-004` | High | BC | Historical EBREAK project-local debug and noncanonical SYSTEM decode. | EBREAK -> precise `mepc`, `mcause=3`, `mtvec`; use exact SYSTEM legality; remove architectural dependency on legacy `debug_mode`. | `07_interrupt_architecture`, `21_cpu_core` | 3B3R EBREAK/noncanonical SYSTEM; old debug controller uninstantiated | VERIFIED |
| `INT-001` | High | PLIC | Functional `mstatus.MIE/MPIE`, `mie`, `mip`, external IRQ acceptance are absent. | Define in the dedicated PLIC/CPU interrupt specification, not baseline cleanup. | `07_interrupt_architecture`, `21_cpu_core` | PLIC-stage regression | DEFERRED |
| `INT-002` | High | PLIC | PLIC address/source IDs/priority/claim-complete are undefined. | Define complete PLIC contract; legacy snapshot remains reference-only. | `07_interrupt_architecture`, future PLIC spec | PLIC-stage tests | DEFERRED |

Phase 4A-3B CPU architectural implementation and its scoped verification are **COMPLETE** after the Phase 4A-3B-CLOSE TRAP-002 precision-interaction matrix and predecessor regressions. The literal already-held CSR plus older EX event is unreachable at acquisition priority; reachable held-owner cancellation was tested with an older MEM final ERROR. This does not close whole baseline cleanup, external I/O, board, firmware, PLIC or AXI.

---

# Part II — Board I/O Cleanup

## 9. GPIO / SW / LED and 16-Slot APB Integration

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `BOARDIO-001` | Blocker | BC | Historical GPIO mixed SW/LED and lacked true pin direction. | Keep target slot-1 GPIO with DATA_IN/OUT/DIR, synchronized input, tri-state OE, finalized IRQ registers. | `11_gpio`, `20_board_io_architecture` | P04 direction/tri-state/IRQ/W1C + post-fit OE evidence | VERIFIED |
| `BOARDIO-002` | Blocker | BC | Historical width/pin/cabling decision is resolved; quantitative external timing/electrical closure remains in `STA-002`. | Keep `GPIO_WIDTH=16` bound 1:1 to JP1 `GPIO_[0:15]`/approved package pins with no UART/LoRa or user-wiring conflict. | `11_gpio`, `20_board_io_architecture` | P03A user confirmation + P04 16/16 post-fit pin/OE review | VERIFIED |
| `BOARDIO-003` | High | BC | Historical SW ownership in legacy GPIO was removed by P04. | Keep `APB_SW` at `PSEL[8]/0x4008_0000`, owning SW[9:0] with sync/change pending/W1C/sw_irq. | `17_sw`, `20_board_io_architecture` | P04 all 10 SW + warm-up/IRQ tests | VERIFIED |
| `BOARDIO-004` | High | BC | P04 implements sole APB_LED ownership, but the required physical LED board test is absent. | Keep `APB_LED` at `PSEL[9]/0x4009_0000`, owning all LEDR[9:0] with no reset hard-wire; complete acceptance. | `18_led`, `20_board_io_architecture` | walking/all-on/off board tests | OPEN |
| `BOARDIO-005` | High | BC | Historical active top lacked local `gpio_irq`/`sw_irq`; P04 implements and verifies the baseline-local wires. | Preserve local SoC IRQ wires and leave CPU disconnected until PLIC stage; fitter pruning while unconsumed is acceptable. | `11_gpio`, `17_sw`, `20_board_io_architecture` | P04 local IRQ instrumentation + final closure review | VERIFIED |
| `BOARDIO-006` | High | BC | Historical migration risk of duplicate board-signal ownership. | Keep exactly one final-top owner for SW, LED, and selected GPIO pins. | `20_board_io_architecture` | P04 lint/multiple-driver/connectivity + fit pin review | VERIFIED |

P04 and the later User/Chat closure decision verify `BOARDIO-001/002/003/006`. In particular, user wiring conflict is confirmed absent and the intended 16/16 pins fit with the expected bidirectional OE structure. `BOARDIO-002` closes pin binding/ownership/no-conflict and the reusable baseline electrical-use contract; peer-specific voltage/load/timing, I/O-delay derivation, drive-strength disposition and ADC/VGA coexistence remain owned by blocked `STA-002`. `BOARDIO-004/005`, `FW-005/007`, and `VER-005` retain their separate evidence gaps.

---

# Part III — Peripheral Cleanup

## 10. VGA / VRAM

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `VGA-001` | High | BC | Canonical framebuffer/status/control decode is the current contract. | Preserve canonical aperture and invalid-gap ERROR behavior. | `01_memory_map`, `04_ahb_fabric`, `08_vga` | boundary/gap and CPU fault-path DV | VERIFIED |
| `VGA-002` | Medium | BC | Framebuffer is aligned 32-bit write-only; reads/subword accesses ERROR. | Preserve write-only/error policy and removed byte helper. | `08_vga`, `19_firmware_contract` | negative DV, source review, firmware build | VERIFIED |
| `VGA-003` | High | BC | Busy/not-ready traffic gets two-cycle ERROR without rejected WE. | Preserve rejection, ownership, and no-side-effect behavior. | `08_vga`, `04_ahb_fabric` | contention and CPU cause-7 DV | VERIFIED |
| `VGA-004` | High | BC | Clear target is latched and only one cleaner operation is outstanding. | Preserve target latch and repeated-command behavior. | `08_vga` | clear-only/combined/overlap DV | VERIFIED |
| `VGA-005` | Medium | BC | Completion is sticky W1C; BUSY/READY are live. | Preserve deterministic ordering and acknowledgement semantics. | `08_vga`, `19_firmware_contract` | ordering/W1C/collision DV and firmware path | VERIFIED |
| `VGA-006` | High | BC | Exact-count RTL/DV and board-visible smoke evidence exist. | Preserve clear/swap behavior; complete CDC/STA work separately. | `08_vga` | exact 9,600-word RTL/DV; board photos | VERIFIED |
| `VGA-007` | Low | OPT | Dormant `APB_VGA_Top` can confuse active ownership. | Archive/remove/mark unmistakably dormant when safe. | `08_vga` | source review | OPEN |

Dependencies: `CDC-001`, `RST-002`, `STA-001`.

The `VGA-001` through `VGA-006` status is owner-accepted functional scope at the frozen P08B source. It does not close `CDC-001`, `STA-001`, `STA-002`, warning disposition, reset-window analysis, or programmer identity.

## 11. UART0 / UART1

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `UART-001` | High | BC | Historical extra idle baud interval after TX stop completion is removed in both production UARTs. | Preserve exact 8-N-1 start/data/stop timing, active-divisor bit duration, and `TX_READY` return at stop completion. | `09_uart` | P07B dual-UART serial waveform/cycle regression at divisors 217/434 | VERIFIED |
| `UART-002` | High | BC | Historical busy-write silent drop and pending-start READY hazard are removed. | Preserve busy DATA `PREADY` backpressure, exactly-once acceptance, and `TX_READY` acceptance semantics. | `09_uart`, `19_firmware_contract` | P07B held-ACCESS tests + actual AHB/APB integration `p07b_uart_03` PASS, 2167 sampled wait cycles, no loss/duplication | VERIFIED |
| `UART-003` | High | BC | Combined framing/overflow `RX_ERROR` now has deterministic sticky W1C semantics in both independent production UARTs. | Preserve invalid-frame rejection, drop-new/preserve-old overflow, push/pop/read retention, bit2 W1C/no-clear-on-zero, set-dominant collision, and reset clear. | `09_uart` | P07B supplement `p07b_uart_supplement_02`, wrapper exit 0, explicit `APB_UART_LORA` + `APB_UART` evidence; controlled collision is priority-logic, not end-to-end serial collision | VERIFIED |
| `UART-004` | Medium | BC | Empty DATA, CONTROL, BAUD-update, and local-decode policies are deterministic. | Preserve empty read zero/no-pop, CONTROL RAZ/WI, programmed/active divisor separation, valid 217..65535/invalid 0..216 ignore, and canonical offsets only. | `09_uart` | P07B focused boundary/mid-frame/local-decode and regression evidence | VERIFIED |
| `UART-005` | High | BC | Cleanup-grade open protocol regression exists, but source-identity-traceable physical PC/LoRa acceptance is absent. | Preserve automated TX/RX/FIFO/error/AUX coverage and complete PC UART, LoRa UART, and physical multi-byte board checks against an identifiable build/source snapshot. | `09_uart` | P07B open verification + pending PC/LoRa board evidence | OPEN |
| `UART-006` | Medium | OPT | UART0/UART1 duplicate most RTL. | Consider shared core after functional cleanup. | `09_uart` | regression if refactored | OPEN |
| `UART-IRQ` | Medium | PLIC | No UART IRQ contract. | Define during PLIC stage if selected. | `09_uart`, future PLIC | PLIC-stage | DEFERRED |

`APB-005` owns removal of UART register mirrors.

User/Chat approved P07B and its focused supplement for Open Verification on
2026-09-16. This closes `UART-001..004` only. It is not post-fit timing,
physical UART/LoRa, or external-I/O electrical acceptance; `UART-005` remains
OPEN, `UART-006` remains optional/OPEN, and `UART-IRQ` remains DEFERRED.

## 12. Timer

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `TIMER-001` | High | BC | Frozen A5 one-shot is implemented. | Preserve exact N active edges, N=0 immediate completion, explicit START/STOP/RELOAD, terminal COUNT=N, and fresh restart. | `10_timer`, `19_firmware_contract` | directed N=0/1/2/N, maximum near-terminal, terminal hold, repeated START | VERIFIED |
| `TIMER-002` | Medium | BC | STOP and running compare-update semantics are deterministic. | Preserve STOP priority over same-edge evaluation and programmed/active compare isolation. | `10_timer` | STOP at increment/terminal edges; running COMPARE affects next START only | VERIFIED |
| `TIMER-003` | High | BC | READY acknowledgement is race-safe. | Preserve sticky W1C READY, no W1C auto-restart, and terminal set-dominance. | `10_timer` | terminal+W1C collision and explicit re-arm tests | VERIFIED |
| `TIMER-004` | High | BC | Cleanup-grade Timer regression exists and passes. | Preserve boundary/re-arm/disable/update/reset/canonical-offset coverage. | `10_timer` | self-checking focused Timer plus open/bus/reset regressions PASS | VERIFIED |
| `TIMER-005` | Low | OPT | Dead `counter_debug` was removed. | Keep the unowned debug port absent unless a deliberate interface is specified. | `10_timer` | no references; whole-SoC lint/elaboration PASS | VERIFIED |
| `TIMER-IRQ` | Medium | PLIC | No timer IRQ contract. | Define during PLIC stage. | `10_timer`, future PLIC | PLIC-stage | DEFERRED |

## 13. G-Sensor / ADXL345

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `GS-001` | Blocker | BC | No coherent software sample/VALID/SEQ; first sample undefined. | Resolve through `CDC-002`: atomic XYZ PCLK snapshot + first-sample validity/sequence. | `12_gsensor`, `19_firmware_contract` | async atomic snapshot | OPEN |
| `GS-002` | High | BC | Historical X/Y/Z reconstruction, especially inserted-zero Z, was unproven; active A6 now uses full `completed_rx` bytes. | Preserve source-accurate full-byte extraction; revalidate after P09B changes without claiming physical orientation. | `12_gsensor`, `13_spi` | scoped digital X=1234,Y=5678,Z=9ABC | VERIFIED |
| `GS-003` | Medium | BC | ~8.192 ms polling vs nominal 50 Hz ODR, INT_ENABLE=0, pin naming ambiguity. | Freeze acquisition policy, correct timing docs/config, verify physical INT mapping. | `12_gsensor` | rate + interrupt/fallback tests | OPEN |
| `GS-004` | Medium | BC | A6 resets sample regs to zero, but zero is not a VALID indication; fixed hardware-config policy is implicit. | Gate visibility with VALID and explicitly retain/revise fixed initialization policy. | `12_gsensor`, `19_firmware_contract` | pre-first-sample test | OPEN |
| `GS-005` | High | BC | Cleanup-grade init/acquisition/coherency/axis evidence is missing. | Automated SPI/sensor regression + known-orientation board validation. | `12_gsensor`, `13_spi` | sim + board | IN_PROGRESS |
| `GS-IRQ` | Medium | PLIC | No CPU-visible G-sensor IRQ contract. | Define only if selected as a PLIC source. | `12_gsensor`, future PLIC | PLIC-stage | DEFERRED |

`GS-002` verification basis (Phase 3): the spec-driven `rtl/peripherals/gsensor/spi_ee_config.v` and `verification/directed/models/gsensor/tb_gsensor_replacements.sv` passed the 56-bit `X=1234, Y=5678, Z=9ABC` test; the local Phase 3 run log is recorded in the Phase 4A status reconciliation report. This closes axis reconstruction only, not `GS-001`, `CDC-002`, or `GS-005`.

## 14. Private SPI Engine

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `SPI-001` | High | BC | Exact 16/56-bit length, bit order, CS duration, and sample timing lack preserved regression evidence. | Add known-pattern transaction/waveform regression against ADXL345 timing. | `13_spi`, `12_gsensor` | command/data/clock/CS/sample tests | VERIFIED |
| `SPI-002` | High | BC | A6 removed the active two-phase SPI PLL and passed internal fit; physical ADXL345 pin timing remains unverified. | Keep one 50 MHz PCLK/clock-enable FSM and registered mode-3 SCLK; verify board-facing 2 MHz SPI peer timing. | `06_reset_clock`, `13_spi` | 16/56-bit waveform, reset and physical SPI timing | IN_PROGRESS |
| `SPI-003` | Medium | OPT | Current SPI is sensor-private, not a generic software-visible controller. | Do not claim generic SPI. A future generic peripheral requires a separate approved spec. | `13_spi` | spec review | DEFERRED |
| `SPI-004` | Medium | OPT | Sensor policy and transport are structurally intertwined. | Separate only if substantially refactored/reused. | `13_spi`, `12_gsensor` | regression after refactor | OPEN |

Phase 4A-GSENSOR evidence (private local evidence archive): the **G-sensor internal clock-domain sub-scope is VERIFIED** by PCLK-only RTL, focused/open tests and the user-run post-fit clock list/timing. The old G-sensor generated-clock→`clk` path is removed; 50 MHz setup/hold passes at Slow 0°C and 85°C. `SPI-002` remains IN_PROGRESS for physical ADXL345 pin timing/board evidence. `CDC-002` and `GS-001` remain OPEN because no software-visible VALID/SEQ or atomic snapshot across separate X/Y and Z APB reads exists. `GS-004` remains OPEN for the same validity contract despite deterministic reset values. `GS-005`, `STA-001` and `STA-002` are not closed here.

## 15. AES-GCM

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `AES-001` | Blocker | BC | Reference/APB models do not prove actual VHDL core correctness. | Run fresh actual-wrapper/core AES-128-GCM KATs using independent trusted vectors. | `14_aes_gcm` | encrypt/decrypt empty/partial/full KAT | VERIFIED |
| `AES-002` | High | BC | `LEN>16` is not safely rejected. | Deterministically reject values outside 0..16. | `14_aes_gcm`, `19_firmware_contract` | 0/1/15/16/17/65535 | OPEN |
| `AES-003` | High | BC | Byte/word ordering can silently break interoperability. | Freeze KEY/IV/AAD/payload/tag ordering with independent vectors. | `14_aes_gcm` | byte-array↔MMIO KAT | OPEN |
| `AES-004` | High | BC | Decrypt plaintext can exist before authentication succeeds. | Driver releases plaintext only after DONE && TAG_OK && !ERROR. | `14_aes_gcm`, `19_firmware_contract` | wrong-tag negative test | OPEN |
| `AES-005` | High | BC | Key remains readable/stored; no zeroize policy. | Define/implement explicit zeroization appropriate to this accelerator; never claim secure vault behavior. | `14_aes_gcm`, `19_firmware_contract` | zeroize/readback/reset tests | OPEN |
| `AES-006` | Medium | BC | Inputs can mutate while BUSY; CLR_STATUS also changes retained ENC_DEC. | Freeze BUSY-write policy and separate status clear from direction state. | `14_aes_gcm` | mutation/CTRL tests | OPEN |
| `AES-007` | Medium | BC | Register alias + unbounded completion helper. | Apply `APB-005` and firmware timeout hardening. | `14_aes_gcm`, `19_firmware_contract` | alias + timeout injection | OPEN |
| `AES-IRQ` | Medium | PLIC | No completion/error IRQ contract. | Define only if desired in PLIC stage. | future PLIC | PLIC-stage | DEFERRED |
| `AES-DMA` | Medium | AXI | Current accelerator is one 128-bit register window. | Define streaming/DMA independently in future AXI/DMA work. | future AXI/DMA | later | DEFERRED |

## 16. ADC / Joystick

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `ADC-001` | Blocker | BC | Actual top CH1/CH2 scanner and disconnected APB command generator duplicate ownership. | Establish one command owner and remove disconnected architecture. | `15_adc_joystick` | command waveform/channel sequence | OPEN |
| `ADC-002` | High | BC | ENABLE/X_CHANNEL/Y_CHANNEL do not control the real ADC stream. | Make them real controls or redefine as fixed/read-only configuration. | `15_adc_joystick` | enable/channel tests | OPEN |
| `ADC-003` | High | BC | No atomic XY/sequence/error publication. | Resolve through `CDC-003`; expose coherent sample and synchronous captured status. | `15_adc_joystick`, `19_firmware_contract` | async atomic XY tests | OPEN |
| `ADC-004` | High | BC | Physical X polarity and LEFT/RIGHT vs `a`/`d` mapping are unresolved. | Verify board polarity and intentionally align naming/FW mapping. | `15_adc_joystick`, `19_firmware_contract` | manual direction test | OPEN |
| `ADC-005` | Medium | BC | ADC acquisition and joystick policy are tightly combined; live async debug fields exist. | Separate reusable acquisition boundary where practical and expose captured synchronous status only. | `15_adc_joystick` | register/status regression | OPEN |
| `ADC-006` | High | BC | No cleanup-grade command/CDC/coherency regression. | Add asynchronous-clock verification + FPGA joystick acceptance. | `15_adc_joystick` | sim + board | OPEN |

## 17. HEX Display

| ID | Sev | Gate | Current issue | Required outcome | Dependent specs | Verification | Status |
|---|---|---|---|---|---|---|---|
| `HEX-001` | High | BC | QSF constrains stale `HEXx[7]` decimal-point pins while RTL exposes `[6:0]`. | Remove stale assignments unless a DP feature is newly specified. | `16_hex_display` | pin report + board HEX test | IN_PROGRESS |
| `HEX-002` | Medium | BC | Raw mode lacks directed proof. | If retained, verify all six fields, active-low polarity, packing, disable behavior. | `16_hex_display` | raw-mode TB | OPEN |
| `HEX-003` | Medium | BC | Reserved CTRL storage, reset 000000-vs-blank policy, and firmware shadow ownership need normalization. | Freeze reserved/read-zero, reset policy, and driver ownership/RMW behavior. | `16_hex_display`, `19_firmware_contract` | reset/CTRL/shadow tests | OPEN |
| `HEX-004` | Low | OPT | DP/PWM/blink/per-digit features are unspecified. | Do not implement without a separate specification. | `16_hex_display` | n/a | DEFERRED |

---

# Part IV — Firmware Cleanup

## 18. Firmware Work Items

| ID | Sev | Gate | Required work | Main dependencies | Verification | Status |
|---|---|---|---|---|---|---|
| `FW-001` | High | BC | P08B removes framebuffer byte-write API/use; broader partial-MMIO review awaits approval. | `APB-006`, `VGA-002` | source search, host test and affected RV32 builds PASS; review pending | IN_PROGRESS |
| `FW-002` | High | BC | UART/LoRa now use finite TX/AUX budgets, distinct timeout results, tested zero-budget semantics, and migrated material callers; other peripheral waits remain. | Complete bounded polling/timeout APIs across the remaining normal Timer/VGA/AES waits. | peripheral contracts | P07B UART/LoRa host timeout/order/W1C evidence plus remaining peripheral injected-timeout tests | OPEN |
| `FW-003` | Medium | BC | Normalize driver ownership and direct-MMIO rules. | `19_firmware_contract` | host driver tests + review | OPEN |
| `FW-004` | High | BC | Timer driver and active applications use the frozen A5 fresh one-shot sequence. | `TIMER-001..003` | host MMIO ordering PASS; `final_main`/`benchmark_main` RV32I builds PASS | VERIFIED |
| `FW-005` | High | BC | P04 split the GPIO/SW/LED drivers and host tests pass; required board evidence is absent. | Preserve the split drivers and complete board-I/O acceptance. | board-I/O work | host + board tests | OPEN |
| `FW-006` | High | BC | Historical SW/LED constants and 16-slot map migration gap. | Keep SW/LED constants and 16-slot map matched to RTL. | `APB-001`, `BOARDIO-003/004` | P04 address-map regression | VERIFIED |
| `FW-007` | High | BC | P04 implements and host-tests the true-GPIO/IRQ driver; resolved `BOARDIO-001/002` dependencies remove the old blocker, while the explicit GPIO board test remains. | Preserve finalized true-GPIO/IRQ driver and complete board acceptance. | `BOARDIO-001/002` | GPIO host + board tests | IN_PROGRESS |
| `FW-008` | High | BC | Add coherent G-sensor sample API after CDC cleanup. | `GS-001/002` | valid/seq/atomic tests | OPEN |
| `FW-009` | High | BC | Add coherent ADC/joystick API after cleanup. | `ADC-001..004` | atomic/direction tests | OPEN |
| `FW-010` | High | BC | Harden AES argument/busy/auth/timeout/zeroization handling. | `AES-001..007` | KAT/wrong-tag/timeout tests | OPEN |
| `FW-011` | Medium | BC | Historical `gpio_led_write()` and LEDR9 reset-ownership assumptions. | Keep stale board-I/O assumptions removed. | board-I/O migration | P04 code search + display smoke | VERIFIED |
| `FW-012` | High | BC | Expand host MMIO regressions and FPGA acceptance applications. | all cleanup blocks | logs + board results | IN_PROGRESS |

---

# Part V — Verification, Build, and Evidence Gate

## 19. Required Evidence

| ID | Sev | Gate | Required work | Acceptance evidence | Status |
|---|---|---|---|---|---|
| `VER-001` | Blocker | BC | Repository-wide lint/elaboration/basic RTL simulation on cleaned RTL. | clean/triaged Verilator or equivalent logs | IN_PROGRESS |
| `VER-002` | Blocker | BC | Directed bus/APB/peripheral regressions. | deterministic pass logs + test sources | IN_PROGRESS |
| `VER-003` | Blocker | BC | Async-clock/reset tests for VGA, G-sensor, ADC CDC fixes. | CDC assertions/TB pass | OPEN |
| `VER-004` | Blocker | BC | Fresh Quartus 19.1 build + generated-clock/uncertainty TimeQuest review. | compile/timing/warning-triage evidence | IN_PROGRESS |
| `VER-005` | Blocker | BC | FPGA board acceptance for cleaned board-facing blocks. | board checklist tied to SOF/source commit | OPEN |
| `VER-006` | High | BC | Preserve actual-core AES-GCM KAT evidence. | vectors/results tied to RTL commit | OPEN |
| `VER-007` | High | BC | Preserve source→ELF→IMEM/DMEM MIF→SOF artifact chain. | reproducible artifact mapping | OPEN |
| `VER-008` | Blocker | BC | Dedicated CPU-core regression for new `21_cpu_core` contract. | shift/JALR/legality/retire/trap/FENCE/CSR-ID/counter-write-ignore deterministic pass logs | VERIFIED |
| `DOC-001` | High | BC | After verification, promote target text to active behavior and update README/index. | reviewed spec diff | OPEN |
| `REPORT-001` | High | BC | Create cleanup milestone report: changes, measurements, regressions, remaining deferred risks. | report/evidence record | OPEN |

## 20. Minimum Board-Acceptance Matrix

| Area | Required board evidence |
|---|---|
| VGA | render, VSync/swap, HW clear after arbitration/CDC fix |
| UART1 | PC serial TX/RX |
| UART0 | LoRa or electrical UART peer TX/RX/AUX |
| HEX | decoded mode; raw mode if retained |
| SW | all ten switches + local `sw_irq` instrumentation |
| LED | all ten LEDs including LEDR9 under software control |
| GPIO | selected expansion-header inputs/outputs; IRQ if practical |
| G-sensor | plausible XYZ under known orientation/motion |
| ADC joystick | center, X/Y polarity, deadzone/directions |
| AES-GCM | actual accelerator board smoke; cryptographic correctness primarily from KAT |

CPU architectural cleanup is primarily proven by directed RTL/firmware regression (`VER-008`); board smoke shall additionally confirm that the cleaned CPU boots and runs the acceptance firmware without regression.

---

# Part VI — Explicitly Deferred Work

## 21. PLIC Stage

Not part of baseline-cleanup implementation:

- PLIC MMIO base/aperture,
- source ID table,
- priority/threshold,
- claim/complete,
- CPU external IRQ,
- functional `mstatus.MIE/MPIE`, `mie`, `mip`,
- interrupt `mcause`,
- interrupt-vs-exception priority,
- UART/Timer/AES/G-sensor IRQ contracts unless selected,
- ISR dispatch,
- full interrupt-state restoration on MRET.

Cleanup may expose approved local sources such as `gpio_irq` and `sw_irq`, but shall not copy the frozen legacy PLIC CPU integration wholesale.

## 22. AXI / DMA / External-Memory Stage

Remain downstream roadmap work:

- AXI interconnect,
- AXI-to-APB bridge,
- multi-channel DMA and arbitration,
- external SDRAM,
- DMA staging/buffers,
- D-cache,
- streaming AES/DMA,
- replacement of baseline CPU/DMEM-specific sidebands by clean AXI/cache contracts.

## 23. Optional Future Work

Non-gating unless promoted by a future spec:

- generic software-visible SPI,
- UART RTL de-duplication,
- HEX DP/PWM/blink,
- generalized ADC services,
- GPIO pinmux/pull-control,
- framebuffer readback if write-only VRAM remains the approved policy.

---

# Part VII — Dependency Summary

## 24. Critical Dependency Graph

```text
CPU-003 shift fix --------+
CPU-004 JALR fix ---------+
CPU-005 retire-valid -----+
CPU-006 machine IDs ------+
CPU-007 FENCE policy -----+----> VER-008 CPU regression
CPU-008 counter policy ---+
CPU-009 legality ---------+          |
       |                             v
       +-------> TRAP-003/004    VER-001..004
                    ^
                    |
BUS-003 error policy ------+

BOARDIO-002 GPIO pin/width [VERIFIED]
        |
        v
BOARDIO-001 true GPIO [VERIFIED] -----> FW-007 [IN_PROGRESS: board test remains]

BUS-003 error policy
   |           |
   v           v
APB-004     TRAP-003

APB-001/002/003
        |
        +----> BOARDIO-003 SW
        +----> BOARDIO-004 LED
        +----> FW-006

RST-002 + STA-001
    |       |       |
    v       v       v
 CDC-001  CDC-002  CDC-003
    |       |       |
    v       v       v
  VGA      GS       ADC

TIMER-001..003 -> FW-004
AES-001..007   -> FW-010
GS-001/002     -> FW-008
ADC-001..004   -> FW-009

all RTL/FW cleanup
        |
        v
VER-001..008
        |
        v
DOC-001 + REPORT-001
        |
        v
BASELINE CLEANUP GATE CLOSED
        |
        +--> PLIC
        +--> AXI
```

## 25. Frozen Phase 4A Architecture Decisions and Remaining Physical Dependencies

| Decision | Approved cleanup target | Implementation/physical status |
|---|---|---|
| A1 GPIO | `GPIO_WIDTH=16`, JP1 `GPIO_[0:15]` 1:1; UART/LoRa JP1 27/29/31/34/35 excluded. | P04 source/open/post-fit evidence and User/Chat approval verify `BOARDIO-001/002/003/005/006`. `FW-007` is IN_PROGRESS and still lacks its explicit board test; `VER-005` remains OPEN. Quantitative peer/electrical/timing closure remains `STA-002`. |
| A2 bus/APB fault | Canonical invalid accesses use two-cycle `HRESP=01` ERROR; APB default error/`PSLVERR` propagation; CPU load/store causes 5/7 with precise `mepc`, no failed side effect/retire. | Phase 4A-3A bus evidence plus later 3B3R trap/ISA regression verify `BUS-003`, `APB-004`, and whole `TRAP-003`. |
| A3 VGA | Framebuffer write-only, aligned 32-bit; read/subword/gap/alias ERROR. | Frozen P08B functional scope verifies `VGA-001..006`; `FW-001` remains IN_PROGRESS for broader partial-MMIO review. |
| A4 UART | Busy DATA write backpressured by `PREADY=0` until exactly one acceptance; programmed/per-direction-active divisor architecture. | P07B open verification and User/Chat approval verify `UART-001..004`; `UART-005` physical board evidence remains OPEN, UART IRQ remains DEFERRED, and P07B RTL awaits the later consolidated Quartus/P14 checkpoint. |
| A5 Timer | One-shot, exact N active edges, N=0 immediate, fresh START, STOP/RELOAD, sticky READY/set-dominant W1C. | `TIMER-001..005` and `FW-004` VERIFIED by P06B directed/open/firmware evidence; `APB-005` remains OPEN beyond its recorded Timer sub-scope, `FW-002` remains OPEN, and `TIMER-IRQ` remains DEFERRED. |
| A6 private SPI | One 50 MHz PCLK/clock-enable mode-3 FSM, registered ~2 MHz SCLK; old dual-phase SPI PLL inactive in cleanup target. | `SPI-002` IN_PROGRESS; `RST-002/STA-001` still require evidence. |
| STA-002 external I/O | Separate High/BC external timing/electrical/physical gate; no fabricated delays, ADC/VGA warning requires measurement/disposition. | Architecture frozen; `STA-002` BLOCKED on physical parameters and board evidence. |

CPU policy decisions are **closed**, not listed as blockers:

```text
GPR reset        -> x1..x31 unspecified after system reset
mvendorid        -> 0x0000_0000
marchid          -> 0x0000_0000
mimpid           -> 0x0001_0000
mhartid          -> 0x0000_0000
FENCE/FENCE.I    -> legal no-op
EBREAK           -> precise breakpoint exception through mtvec
machine counters -> read-only; writes are legal no-effect/write-ignore and do not trap solely for RO status
```

The A1–A6 and STA-002 architecture choices are **APPROVED/FROZEN**, based on the Phase 4A-1 local review decision package (local review archive; no private path recorded here). This is not RTL/FW verification. Other implementation contracts and physical parameters still require their own evidence before a `BC` item can become `VERIFIED`.

## 26. Tracker Maintenance Rule

For each cleanup implementation branch/commit:

1. cite the tracker ID in the commit/PR description,
2. update the owning canonical spec first if behavior changes,
3. implement RTL/firmware,
4. add/update required verification,
5. attach or reference evidence,
6. mark `VERIFIED` only after review.

A code-only fix remains `IN_PROGRESS`, not `VERIFIED`.

## P08B Implementation-Entry Note

User/Chat approved Gate 0 only for firmware trap-policy compatibility after
startup's `mtvec` write commits. The earlier Gate 0 STOP remains historical
evidence. The preceding interval is tracked as
`RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT` and remains an unverified
architectural risk. The accepted VGA functional scope changes `VGA-001..006` to
VERIFIED only; it does not close CDC/FW work, release Clean Baseline v1, or claim
full timing/board closure.

## P09B Stage 1 spec-review marker — historical at Stage 1 (no tracker closure)

At Stage 1, the proposed G-sensor contract in `12_gsensor.md` and `19_firmware_contract.md` addressed `GS-001`, `GS-003`, `GS-004`, `GS-005`, `CDC-002` and `FW-008` at the **specification** level only. At that time no P09B production RTL, firmware, testbench, runner, Fitter/TimeQuest or board validation had run, and the tracker states above were unchanged. The prior `SPI-001` verification covered the historical 11-write digital waveform, not the proposed sequence. `GS-IRQ` stayed DEFERRED: external ADXL345 INT1 is an acquisition input, not a CPU/PLIC interrupt source.

The Stage-1 reset correction was likewise **target only**: the pinned A6 source then had ~20 ms shared release qualification **plus** ~20.97152 ms G-sensor-local delay. The historical target proposed direct `PRESETn` and removal only of the local wrapper instance at a later approved RTL stage. AC-18/19 were planned negative/abort checks, **NOT_RUN** at Stage 1. Sensor power-rail readiness, startup, physical INT1, pin timing and board XYZ remained separate gates.

## P09B publication-ready tracker proposal (separate tracker approval required)

> **Current Public integration:** The source/documentation integration is current; this table remains a tracker proposal and does not mutate status or promote any row to `VERIFIED`.

> **Publication synchronization:** The paired source/documentation publication can describe implemented P09B scope, but cannot mutate tracker status or promote any row to `VERIFIED`.

This table is a local proposal for the later isolated candidate, not a change to
Public `main` or a tracker closure. It distinguishes current candidate evidence
from the historical Stage 1 marker above. Candidate RTL/FW and patch provenance
are recorded in the private P09B final-evidence draft. `VERIFIED` is not proposed here.

| Item | Current -> proposed | Evidence / AC disposition | Remaining risk |
|---|---|---|---|
| GS-001 | OPEN -> IN_PROGRESS | Stage 4/5 independent HOLD/VALID/SEQ, CPU and host checks; atomic capture/release observed in the candidate | reset/negative coverage and external behavior not closed |
| GS-002 | VERIFIED -> VERIFIED | existing asymmetric-byte reconstruction evidence retained | no physical orientation claim |
| GS-003/004 | OPEN/OPEN -> IN_PROGRESS | 12-write/INT1/watchdog source plus focused and CPU evidence | physical INT1 and complete reset-negative coverage incomplete |
| GS-005 | IN_PROGRESS -> IN_PROGRESS | simulation/CPU evidence; photo `SEQ=0x1450`; user separately observed later `SEQ≈0x7C00`, approximate ±255 XYZ, and manual desk-rest Z+/left-tilt X+/toward-user Y+ direction/sign changes | not a full board acceptance: no quantitative calibration, systematic orientation matrix, physical INT1 waveform, long-duration integrity or external SPI timing |
| CDC-002 | OPEN -> IN_PROGRESS | single-PCLK source and focused evidence | independent CDC/physical closure not claimed |
| FW-008 | OPEN -> IN_PROGRESS | isolated-candidate driver lifecycle plus independent host and CPU MMIO/fault checks | Public integration, full API-negative/reset coverage and physical behavior are not closed |
| STA-002 | BLOCKED -> BLOCKED | no fabricated I/O delays; fresh STA confirms expected internal paths only | external I/O/electrical and ADC/VGA critical warnings |
| VER-001/002/004/007 | IN_PROGRESS/IN_PROGRESS/IN_PROGRESS/OPEN -> IN_PROGRESS | Stage 5 regressions; fresh fit/STA; source->ELF->MIF->SOF chain | excluded negative branches and warning disposition remain open |
| VER-005 | OPEN -> IN_PROGRESS | photo `SEQ=0x1450` plus separate user manual-tilt/SEQ≈`0x7C00` observation | not full board acceptance; no approved quantitative procedure, calibration/orientation matrix, long-duration or external timing evidence |
