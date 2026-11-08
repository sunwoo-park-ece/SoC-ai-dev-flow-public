# Specifications

Feature and architecture specifications live here.

Primary owner: **Developer + ChatGPT Chat (Project Leader / Tech Lead / Architect / Spec Owner / Final Reviewer)**.

## Current Legacy source and reuse boundary

The original reconciliation input is production source/tracker revision
`35e4633a53a080402526ef751d128df120f311a9`. The current linker additionally
repairs initial standard RV32 ILP32 stack alignment: `__stack_top=0x1000_8000`
is the empty downward-stack exclusive DMEM end, with a 16-byte link-time
alignment assertion. The [memory](02_memory_subsystem.md) and
[firmware](19_firmware_contract.md) contracts separate this ABI repair from
image-specific capacity and overflow assurance. This repair changes no memory
region geometry and is not new board/vendor qualification. The accepted P14 implementation is
`8bf26bdc05796b5be6a12410a0f04cf54837d8f9`; prior spec reconciliation is
`d738cf06db3439fd0a90cd85bf61424bb17fa263`. The terminal revision changes only
EN/KO tracker state, including Owner-accepted CPU-001 width/naming. It is not a
new simulation snapshot. Spec candidate review/acceptance is still separate.

The full production top and [selected-IP test composition](../verification/selected_ip/README.md)
have different apertures: production APB slots 0..9 versus selected slots
0,1,2,4,6. Neither omitted test peripherals nor future roadmap features alter
the production contract. P14 selected cleanup is complete; [Clean Baseline](baseline_cleanup.md)
remains NOT_RELEASED. AES D08 integrated natural overflow/late success is
NOT_PROVEN, and vendor memory, physical timing/CDC and board limits are not
automatically inherited by another platform.

Another owning repository must adopt a reviewed, pinned immutable Spec snapshot,
select clauses deliberately, and record adopted/modified/rejected/deferred
dispositions in its own specifications. Reading or copying all Legacy EN/KO
pairs is not automatic adoption. PLIC, ACLINT, AXI/DMA and dual-hart contracts
require new ownership and qualification; this Legacy refresh does not define
them. The affected numbered specifications now identify current contract,
historical reconstruction, bounded accepted evidence and unproven/deferred work.
The remaining Legacy peripherals and cross-cutting timing/physical documents
retain their existing authority and are deferred from this focused reconciliation.

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
├─ 17_sw.md                      # active P04; historical reconstruction retained
├─ 18_led.md                     # active P04; historical reconstruction retained
├─ 19_firmware_contract.md       # current + approved target software contract
├─ 20_board_io_architecture.md   # active P04 with separate physical gaps
├─ 21_cpu_core.md                # detailed supplemental baseline CPU microarchitecture
├─ 22_soc_health_firmware.md     # implemented Health contract + historical SYSFW ledger
├─ timing_constraints.md         # canonical cross-cutting STA policy
├─ physical_assurance_limitations.md # proposed / not accepted physical register
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
   ├─ 22_soc_health_firmware.ko.md
   ├─ timing_constraints.ko.md
   ├─ physical_assurance_limitations.ko.md
   └─ baseline_cleanup.ko.md
```

The original numbered baseline/target specification set through `20_board_io_architecture.md` was structurally complete for cleanup planning. `21_cpu_core.md` was subsequently added as a detailed supplemental reconstruction of CPU microarchitecture discovered to be necessary before CPU/trap cleanup and PLIC integration. Its numeric location avoids disruptive renumbering; logically it refines the CPU internals underlying `03_cpu_interface.md` and `07_interrupt_architecture.md`.

`baseline_cleanup.md` remains the active project-wide tracker: it collects and deduplicates cleanup findings, separates baseline-cleanup gates from PLIC/AXI/optional future work, records dependencies and blocking decisions, and defines the verification/evidence exit gate.

Legacy whole-baseline cleanup and release remain separately gated. P14 selected-IP cleanup is complete within its accepted envelope; selected reuse requires its own source adoption and requalification. PLIC and AXI are new-platform work, not existing Legacy functionality.

The numeric prefix is a **navigation and authoring-order aid**, not part of the architectural meaning of the document. Explicit dependencies and ownership stated inside each specification remain authoritative.

When new specifications are inserted later, renumbering is allowed if it improves the canonical reading order, provided all repository links and companion filenames are updated in the same change.

## Implemented Baseline vs Target Contracts

The 23 numbered EN/KO pairs, timing and physical-assurance pairs, and this index form a 51-file candidate. The two read-only cleanup trackers give a 53-document review universe. Current clauses govern current operation; explicitly historical migration/checkpoint statements do not reopen completed implementation or establish new evidence.

P04 GPIO/SW/LED, P06 Timer, P07 UART, P09B G-sensor, P10 HEX, P11 ADC, SYSFW-01 Health and P13/P14 selected digital behavior retain their individually accepted source/use boundaries. HEX S6 observations alone do not prove every HEX criterion. P11 ADC-specific CDC-003 acceptance does not close VGA CDC-001. The detailed per-IP contracts distinguish CPU bridge ERROR from local APB RAZ/WI or PSLVERR.

`19_firmware_contract.md` separates current APIs from explicitly historical and deferred behavior. [Health](22_soc_health_firmware.md) and its [Korean companion](kor/22_soc_health_firmware.ko.md) describe implemented `soc_health_main`, accepted SYSFW-01 host/provider/build scope, later P11 ADC scope and P12 G16 normal dashboard/restart scope. AES remains EXCLUDED_PENDING_CLEANUP in Health despite separate trusted AES v2 acceptance. Historical SYSFW stage labels are not Legacy Spec refresh stage approvals.

`21_cpu_core.md` describes the accepted CPU subset and limits. CPU-001 is VERIFIED only for width/naming; CPU-010 remains OPEN with x1..x31 unspecified after system reset. Existing GPR policy is not proof of a reset-cleared register file. FW-002/FW-003 remain OPEN. Timing/physical limits and Clean Baseline NOT_RELEASED are unchanged.

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
soc_health_firmware.md   -> spec/22_soc_health_firmware.md
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
soc_health_firmware.ko.md   -> spec/kor/22_soc_health_firmware.ko.md
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
