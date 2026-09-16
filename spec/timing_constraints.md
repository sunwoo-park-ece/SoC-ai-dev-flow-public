# Timing Constraints and STA Policy

> **Status:** Baseline timing contract for the current DE10-Lite public candidate. English is canonical; `kor/timing_constraints.ko.md` is a synchronized companion. This is a policy, not a claim of full board timing sign-off. Clock/reset architecture is in [06_reset_clock.md](06_reset_clock.md); engineering milestone history and raw fitted evidence remain outside this public specification.

## 1. Scope

This specification governs clocks, timed relationships, setup/hold acceptance, exceptions, evidence and rebuild decisions for the **current 50 MHz baseline**. It separates internal STA from external I/O timing, CDC correctness and board characterization. It does not authorize a timing exception, SDC/QSF edit, new build or target-SoC frequency increase.

## 2. Baseline Timing Objective

The DE10-Lite board reference `clk` directly drives the 50 MHz CPU/AHB system clock; APB `PCLK` is the same clock. Its period is **20.000 ns**. For every required, correctly modeled internal relationship at the relevant corners: setup WNS ≥ 0 ns, TimeQuest endpoint TNS = 0 ns, and required hold slack ≥ 0 ns. These are acceptance conditions, not measured margins. The present +0.253 ns Slow 85°C WNS is an observation, **not** a new specification threshold.

## 3. Clock Definitions

The active public `fpga/quartus/constraints/de10_lite.sdc` creates `clk` at 20.000 ns and calls `derive_pll_clocks` and `derive_clock_uncertainty`. The approved fitted baseline reports four active clock objects: system `clk` 50 MHz; VGA pixel PLL 25 MHz; and ADC/Qsys PLL outputs 25 MHz and 10 MHz. They are derived implementation clocks, not separate software-visible performance guarantees. The G-sensor FSM/sample registers now run on PCLK; its ~2 MHz registered SCLK is an **external SPI output**, not an internal generated clock. Historical/private `spi_pll` files do not make it active.

Do not assume that a clock is active merely because an IP file or historical description exists. Verify the fitted clock inventory after any architecture/binding change. `system_pll` is not the active CPU clock in this baseline.

## 4. Generated Clock Policy

Every active PLL-generated internal clock shall have valid modeled frequency, phase and relationship in TimeQuest, via reviewed derivation or explicit constraints. A generated clock shall not be ignored merely to make WNS positive. It may disappear from the clock inventory only when its internal clock domain is **structurally removed**, as with the single-PCLK G-sensor implementation. Such removal requires RTL/binding, fitted-clock-list and CDC review; deleting a constraint alone is not closure.

## 5. Timing Corners

At minimum review setup at the currently reported **Slow 1200 mV 0°C** and **Slow 1200 mV 85°C** MAX 10 models. Review all hold corners reported for the selected device/profile, including the currently reported **Fast 1200 mV 0°C** model. Inspect recovery, removal and minimum-pulse-width checks where applicable. A future device/tool profile may change the corner inventory and requires a new review; do not invent unsupported corners.

## 6. Setup Acceptance

For each required timed transfer, setup slack shall be nonnegative in every required corner; record WNS by corner and the actual worst path. A positive system-clock row is not proof that all generated-clock transfers or external ports are closed. The 3B2A historical generated-SPI-clock→system-clock failure illustrates why the actual launch/capture relationship matters.

## 7. Hold Acceptance

Every required hold path shall have nonnegative slack at all reported hold corners. Record the worst multicorner value and path family; do not infer hold PASS from setup PASS or Fmax. Reset recovery/removal is separately reviewed.

## 8. TNS Acceptance

Required setup and hold endpoint TNS shall be **0**. TimeQuest's violating endpoint TNS is displayed as a **negative signed number**; a negative result is a failure, and its absolute value is the violation magnitude. Do not describe negative TNS as a pass because the compile exited 0.

## 9. Clock-Uncertainty Policy

Retain reviewed clock uncertainty for active clocks. The public SDC currently uses `derive_clock_uncertainty`; confirm the generated clocks and applied uncertainty in the fitted TimeQuest output. Missing-clock or uncertainty warnings must be triaged under `STA-001`, not dismissed by headline Fmax. Never relax uncertainty solely to obtain positive slack.

## 10. False-Path Policy

No false path may be added solely to silence a failure. A proposed false path requires an architectural non-transfer or verified CDC/reset mechanism, exact source/destination scope, owner/reviewer, and functional/CDC evidence. Review tool/vendor-provided exceptions too; public SDC text alone does not prove the entire compiled constraint set contains none. A functionally required synchronous transfer shall remain timed.

## 11. Multicycle-Path Policy

Do not create a multicycle exception to hide a deep combinational path. A valid multicycle path requires an explicit launch/capture protocol and enable behavior, exact endpoints, setup **and hold** semantics, verification evidence and reviewer approval. Its value shall be derived from that architecture, not the slack deficit. The baseline 3B2A G-sensor crossing was not excused this way.

## 12. Clock-Domain / CDC Timing Policy

STA and CDC correctness are distinct: a timed cross-clock path does not prove coherent/safe transfer, and a CDC exception is legitimate only when paired with an intentional synchronizer, handshake, FIFO or verified dual-clock memory boundary. Conversely, an asynchronous relationship shall not be declared until the CDC architecture is established. Clock/reset domains and unresolved crossings are cataloged in `06_reset_clock.md` and tracked under `CDC-*`/`RST-*`/`STA-001`. The single-PCLK G-sensor change removed one internal crossing but did not close ADC/VGA CDC or software-visible XYZ snapshot semantics.

## 13. External I/O Constraint Policy

Board-facing ports must be classified as synchronous, source-synchronous, asynchronous, static or analog. Apply input/output delays only from documented board, peer-device and interface timing assumptions. For a port where such a delay is inapplicable, record a justified **N/A**, not a fabricated zero or arbitrary number. Review pin voltage/I/O standard, drive strength/load, ADC/VGA proximity and G-sensor SPI peer timing against board/device evidence. `STA-002` owns this separate gate; positive internal 50 MHz slack does not sign off external timing or ADC analog performance.

## 14. Unconstrained Path Policy

“Zero unconstrained clocks” does **not** mean “fully constrained design.” Every closure review shall inspect unconstrained clocks, input/output ports and paths, and external delay coverage. The approved 3B3 fitted evidence has zero unconstrained clocks but **16 unconstrained input ports/44 input paths** and **71 unconstrained output ports/2,114 output paths**. These are a known open scope, not a permission to call the board fully timing-signed-off. Do not invent delay values to reduce the count.

## 15. Timing Exception Governance

Before any false-path, multicycle, clock-group or other timing exception is accepted, record: architectural reason; exact `-from`/`-to` and affected clock relationship; owner and independent reviewer; functional/CDC evidence; setup/hold consequences; and a before/after TimeQuest exception/path audit. No exception may be added solely to silence a failing path. If a synchronous required path fails, investigate/optimize architecture or fit rather than masking it. This document approves **no new exception**.

## 16. Quartus / TimeQuest Evidence Requirements

An acceptance record shall include tool/version, device, timing model/profile, run ID, source-list and private-binding identity without public vendor payload, SDC/QSF identity, clock inventory/periods, per-corner WNS/TNS, worst hold, supplemental Fmax, worst-path start/end and clock relationship, logic levels, data/cell/routing delay when available, warnings and unconstrained-path summary. Record missing detailed fields as `UNKNOWN / NOT REPORTED`, not guesses. Use path-level analysis on a **copy** of an existing fitted DB when a default summary lacks detail, preserving the canonical build evidence.

Fmax is supplemental and same-clock scoped. The historical 3B2A fit had Fmax above 50 MHz but negative WNS on a generated-clock→`clk` path. Closure priority is required-path WNS/TNS/hold **before** headline Fmax.

## 17. Timing Closure Workflow

Freeze approved spec/RTL/clock/constraint/binding identity → pass open regressions → user-operated vendor full build under a new run ID → verify exit code, source/constraint identity and report integrity → inspect clock/corner setup/hold and warnings → extract detailed critical paths if needed → disposition internal/external/CDC gaps → User/Chat review gate. A successful compile or bitstream is not by itself timing closure or firmware/board acceptance. Do not overwrite prior run evidence.

## 18. Evidence Reuse / Rebuild Rules

A fitted timing result may be reused only if synthesizable RTL, SDC, timing-relevant QSF, source list/profile, private IP implementation and bindings, device, and implementation-relevant tool/version/profile remain identical and identity is recorded. TB/script/report-only changes do not invalidate a fit. Phase 4A-3B-CLOSE is such a verification-only reuse of the approved 3B3 fit, **not** a new timing datapoint. A change to synth RTL, timing constraints, clock architecture, timing-relevant QSF, private IP implementation, device or implementation flow requires a new build and timing review.

## 19. Board Characterization vs STA Sign-Off

STA is a modeled worst-case timing judgment across stated PVT/constraints. Running one board above 50 MHz under particular conditions is empirical characterization, not a substitute for sign-off and not a guarantee for all boards/corners. Record hardware, environment, firmware/workload, duration and error criteria if an overclock test is later performed. Do not state a 60–70 MHz maximum or guarantee without corresponding evidence and STA.

## 20. Known Open Timing Scope

The P05C fitted reset/clock checkpoint is **PASS within current internal constraints**: multicorner worst setup `+0.558 ns`, hold `+0.111 ns`, recovery `+11.334 ns`, removal `+0.478 ns`, and design-wide TNS `0`. All intended internal clocks are constrained and no G-sensor internal generated clock is present. `STA-001` remains IN_PROGRESS until the final P14 frozen-source multicorner, exception/CDC, and multi-seed/stability review. External I/O timing/electrical and ADC/VGA board impact are **NOT CLOSED** (`STA-002` BLOCKED); the P05C design still has 32 unconstrained input ports/55 paths and 87 unconstrained output ports/2,146 paths. These are separate from reset-row closure and release approval. Detailed changing margins belong in the local STA status history, not here.

## 21. Future Target-SoC Timing Re-Closure

PLIC, AXI, DMA, SDRAM or a higher frequency target requires a new architecture/CDC/constraint assessment, source and binding freeze, open regressions, vendor fits, path and external-I/O analysis, and independent review. Current 3B3 baseline WNS/Fmax shall not be inherited by that expanded design. Potential earlier decode, registered EX/MEM control, reduced MEM re-decode, shallower forwarding or lower exception fanout are **investigation ideas only**, not prescribed edits or timing exceptions.
