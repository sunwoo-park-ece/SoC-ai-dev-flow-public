# Specifications

Feature and architecture specifications live here.

Primary owner: **Developer + ChatGPT Chat (Project Leader / Tech Lead / Architect / Spec Owner / Final Reviewer)**.

## Layout and Reading Order

Canonical numbered English specifications stay directly under `spec/` and use a two-digit numeric prefix to make the intended reading/dependency order visible.

Korean companion translations live under `spec/kor/` and use the same numeric prefix as their canonical English source.

The unnumbered `baseline_cleanup.md` is the active cross-spec cleanup execution tracker rather than another architectural specification in the numbered reading order.

The unnumbered [timing_constraints.md](timing_constraints.md) is the canonical cross-cutting STA policy; [timing_constraints.ko.md](kor/timing_constraints.ko.md) is its Korean companion. Clock/reset architecture remains in `06_reset_clock.md`.

```text
spec/
├─ README.md
├─ 00_soc_architecture.md
├─ 01_memory_map.md
├─ 02_memory_subsystem.md
├─ 03_cpu_interface.md
├─ 04_ahb_fabric.md
├─ 05_apb_subsystem.md
├─ 06_reset_clock.md
├─ 07_interrupt_architecture.md
├─ 08_vga.md
├─ 09_uart.md
├─ 10_timer.md
├─ 11_gpio.md
├─ 12_gsensor.md
├─ 13_spi.md
├─ 14_aes_gcm.md
├─ 15_adc_joystick.md
├─ 16_hex_display.md
├─ 17_sw.md                      # target contract; not active baseline RTL yet
├─ 18_led.md                     # target contract; not active baseline RTL yet
├─ 19_firmware_contract.md       # current + approved target software contract
├─ 20_board_io_architecture.md   # target cross-cutting architecture
├─ 21_cpu_core.md                # detailed supplemental baseline CPU microarchitecture
├─ timing_constraints.md         # canonical cross-cutting STA policy
├─ baseline_cleanup.md           # active consolidated cleanup tracker
└─ kor/
   ├─ 00_soc_architecture.ko.md
   ├─ 01_memory_map.ko.md
   ├─ 02_memory_subsystem.ko.md
   ├─ 03_cpu_interface.ko.md
   ├─ 04_ahb_fabric.ko.md
   ├─ 05_apb_subsystem.ko.md
   ├─ 06_reset_clock.ko.md
   ├─ 07_interrupt_architecture.ko.md
   ├─ 08_vga.ko.md
   ├─ 09_uart.ko.md
   ├─ 10_timer.ko.md
   ├─ 11_gpio.ko.md
   ├─ 12_gsensor.ko.md
   ├─ 13_spi.ko.md
   ├─ 14_aes_gcm.ko.md
   ├─ 15_adc_joystick.ko.md
   ├─ 16_hex_display.ko.md
   ├─ 17_sw.ko.md
   ├─ 18_led.ko.md
   ├─ 19_firmware_contract.ko.md
   ├─ 20_board_io_architecture.ko.md
   ├─ 21_cpu_core.ko.md
   ├─ timing_constraints.ko.md
   └─ baseline_cleanup.ko.md
```

The original numbered baseline/target specification set through `20_board_io_architecture.md` was structurally complete for cleanup planning. `21_cpu_core.md` was subsequently added as a detailed supplemental reconstruction of CPU microarchitecture discovered to be necessary before CPU/trap cleanup and PLIC integration. Its numeric location avoids disruptive renumbering; logically it refines the CPU internals underlying `03_cpu_interface.md` and `07_interrupt_architecture.md`.

`baseline_cleanup.md` remains the active project-wide tracker: it collects and deduplicates cleanup findings, separates baseline-cleanup gates from PLIC/AXI/optional future work, records dependencies and blocking decisions, and defines the verification/evidence exit gate.

The next project stage is **baseline cleanup decision closure and implementation**, not additional feature integration. PLIC and AXI work remain downstream of the cleanup gate.

The numeric prefix is a **navigation and authoring-order aid**, not part of the architectural meaning of the document. Explicit dependencies and ownership stated inside each specification remain authoritative.

When new specifications are inserted later, renumbering is allowed if it improves the canonical reading order, provided all repository links and companion filenames are updated in the same change.

## Implemented Baseline vs Target Contracts

Most documents through `16_hex_display.md` reconstruct and document the currently implemented FPGA baseline. In particular, `16_hex_display.md` has been fully cleaned up and verified across RTL (CTRL RAZ/WI, exact offset decode), firmware (Shadow sync), multi-tier simulation, Quartus build, and physical board acceptance (P10-HEX S0..S6). The GPIO/SW/LED and APB topology described below were implemented and verified during Phase 4A-P04; older target-only wording inside individual documents remains historical context until the full specification refresh.

`17_sw.md`, `18_led.md`, and `20_board_io_architecture.md` define the contract implemented by Phase 4A-P04. Their requirements are active only where implementation and verification evidence exist; they shall not be used to imply completion of unrelated board, firmware, PLIC, or final timing acceptance.

`19_firmware_contract.md` intentionally contains both layers: current firmware rules that apply to the active baseline and approved target firmware rules that become active only with the corresponding cleanup implementation/evidence.

`21_cpu_core.md` reconstructs the active CPU microarchitecture in detail and records CPU-local cleanup findings plus approved spec-owner policy decisions. Its GPR-reset, machine-identification, FENCE/FENCE.I, EBREAK, and machine-counter cleanup policies are now resolved; target behavior shall still not be cited as active RTL behavior until implementation and verification evidence exists.

`baseline_cleanup.md` does not supersede these contracts. It coordinates implementation order, status, severity, dependencies, verification, FPGA acceptance, and evidence. If a tracker item requires behavior different from a canonical specification, the specification shall be updated first.

The current implemented board-I/O baseline is:

```text
Phase 4A-P04 baseline:
  PSEL[15:0]

  PSEL[1]  APB_GPIO -> true bidirectional GPIO + gpio_irq
  PSEL[8]  APB_SW   <- SW[9:0] + sw_irq
  PSEL[9]  APB_LED  -> LEDR[9:0]

  PSEL[10:15] reserved
```

The system-level ownership, slot allocation, migration order, and IRQ-boundary decisions are defined by `20_board_io_architecture.md`. Detailed GPIO/SW/LED local register semantics are owned by `11_gpio.md`, `17_sw.md`, and `18_led.md` respectively.

PLIC source IDs are intentionally not allocated by the board-I/O specification; they remain for the future approved PLIC specification.

## Baseline Cleanup Gate

The cleanup tracker classifies work so the baseline milestone does not expand indefinitely:

```text
BC    = baseline-cleanup gate
PLIC  = deferred to dedicated PLIC stage
AXI   = deferred to AXI/DMA/external-memory stage
OPT   = optional / non-gating
```

A code edit alone does not close a cleanup item. `BC` work requires the implementation and verification evidence specified by `baseline_cleanup.md`, followed by Quartus/TimeQuest review and the required FPGA board acceptance before the cleanup milestone is closed.

## Logical Specification Identifiers

To keep prose references stable across future renumbering, an unprefixed basename written inside a specification may be used as a **logical specification identifier** rather than a literal filesystem path.

Examples:

```text
soc_architecture.md      -> spec/00_soc_architecture.md
memory_map.md            -> spec/01_memory_map.md
cpu_interface.md         -> spec/03_cpu_interface.md
vga.md                   -> spec/08_vga.md
uart.md                  -> spec/09_uart.md
timer.md                 -> spec/10_timer.md
gpio.md                  -> spec/11_gpio.md
gsensor.md               -> spec/12_gsensor.md
spi.md                    -> spec/13_spi.md
aes_gcm.md               -> spec/14_aes_gcm.md
adc_joystick.md          -> spec/15_adc_joystick.md
hex_display.md           -> spec/16_hex_display.md
sw.md                    -> spec/17_sw.md
led.md                   -> spec/18_led.md
firmware_contract.md     -> spec/19_firmware_contract.md
board_io_architecture.md -> spec/20_board_io_architecture.md
cpu_core.md              -> spec/21_cpu_core.md
baseline_cleanup.md      -> spec/baseline_cleanup.md

soc_architecture.ko.md      -> spec/kor/00_soc_architecture.ko.md
memory_map.ko.md            -> spec/kor/01_memory_map.ko.md
vga.ko.md                   -> spec/kor/08_vga.ko.md
uart.ko.md                  -> spec/kor/09_uart.ko.md
timer.ko.md                 -> spec/kor/10_timer.ko.md
gpio.ko.md                  -> spec/kor/11_gpio.ko.md
gsensor.ko.md               -> spec/kor/12_gsensor.ko.md
spi.ko.md                    -> spec/kor/13_spi.ko.md
aes_gcm.ko.md               -> spec/kor/14_aes_gcm.ko.md
adc_joystick.ko.md          -> spec/kor/15_adc_joystick.ko.md
hex_display.ko.md           -> spec/kor/16_hex_display.ko.md
sw.ko.md                    -> spec/kor/17_sw.ko.md
led.ko.md                   -> spec/kor/18_led.ko.md
firmware_contract.ko.md     -> spec/kor/19_firmware_contract.ko.md
board_io_architecture.ko.md -> spec/kor/20_board_io_architecture.ko.md
cpu_core.ko.md              -> spec/kor/21_cpu_core.ko.md
baseline_cleanup.ko.md      -> spec/kor/baseline_cleanup.ko.md
```

Actual Markdown hyperlinks and repository/tool paths shall use the indexed physical path where applicable. This distinction lets dependency prose remain readable while preserving deterministic file ordering.

## Language Policy for Specifications

```text
spec/NN_name.md                 = canonical / authoritative English specification
spec/kor/NN_name.ko.md          = Korean companion for human readability
spec/baseline_cleanup.md        = canonical / authoritative cleanup tracker
spec/kor/baseline_cleanup.ko.md = Korean cleanup-tracker companion
```

If an English canonical specification/tracker and its Korean companion conflict, the English file is authoritative.

Agents performing architecture, RTL, firmware, verification, integration, or reporting work shall use the canonical English files under `spec/` as the contract. Korean companions are explanatory mirrors and shall not independently introduce requirements.

## Authoritative Contract

The finalized documents under `spec/` are the **authoritative contract** for implementation, verification, build, and integration.

Detailed decisions owned here include:
- architecture trade-offs
- interface definition
- AXI topology
- arbitration policy
- address map
- register semantics
- interrupt policy
- DMA architecture
- cache/coherency policy
- reset policy
- clock-domain policy
- error-response policy
- module-level requirements
- required verification behavior

```text
                 Developer + Chat
                  SPEC OWNER
                      |
                      v
                     SPEC
               /       |        \
              /        |         \
             v         v          v
     RTL + Firmware   UVM/DV   Build/Integration
       WSL Codex    Antigravity      Work
             \         |          /
              \        |         /
               +-------+--------+
                       v
                    Evidence
```

Implementation, firmware, verification, and build/report activities should all be derived from the specification rather than from one another.

## Decision Ownership

ChatGPT Work may inspect vendor documentation, existing project material, or FPGA/simulator output to support analysis, but it does not own architecture decisions.

If a tool result exposes a specification ambiguity, route it back to Developer + ChatGPT Chat and update `spec/` first.
