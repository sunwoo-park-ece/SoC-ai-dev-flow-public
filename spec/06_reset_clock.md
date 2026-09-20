# Baseline SoC Reset and Clock Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `reset_clock.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `ahb_fabric.md`, `apb_subsystem.md`.

> **Current G-sensor reset note:** A6 removed the internal `spi_pll` clocks, but the pinned wrapper still adds a 2^20-PCLK `reset_delay` after the common system reset. P09B proposes removing only that local delay at a later RTL stage; this Stage 1 document is not an implementation claim. Historical VGA/ADC passages retain their own checkpoint context.

## 1. Purpose

This document defines the clock and reset architecture of the active FPGA baseline. It specifies:

- the board reference clock and active system clock,
- APB clock/reset derivation,
- generated VGA/ADC clocks and the G-sensor registered external serial output,
- the ADC/Qsys-managed clock domain,
- external reset conditioning and distribution,
- local reset sequencing,
- known clock-domain crossings (CDC),
- current timing-constraint coverage,
- cleanup requirements that shall be completed before major PLIC/AXI integration.

This document describes the **implemented baseline**. It does not claim that all current CDC paths or timing constraints are production-quality. Where a path is known to work on the validated board image but lacks a complete CDC/timing proof, this document records that limitation explicitly.

## 2. Clock / Reset Overview

```text
DE10-Lite 50 MHz board clock: clk
              |
              +------------------------------+
              |                              |
              v                              v
        HCLK = clk                      adc_qsys
              |                              |
              |                              +--> adc_sys_clk
              |
              +--> PCLK = HCLK
              |      |
              |      +--> APB peripherals
              |      |
              |      +--> G-sensor reset delay (current only)
              |             |
              |             +--> PCLK-only controller
              |                    +--> registered external SCLK ~2 MHz
              |
              +--> VGA PLL
                     |
                     +--> pclk_25 = 25 MHz

KEY[0] (active-low)
      |
      v
2-FF synchronization
      |
      v
~20 ms release qualification
      |
      v
HRESETn / PRESETn
```

The active baseline therefore contains one main synchronous SoC domain and several generated/local domains.

## 3. Clock Domain Inventory

| Domain | Clock | Nominal frequency | Source | Primary consumers | Architectural status |
|---|---|---:|---|---|---|
| System | `HCLK` | 50 MHz | board `clk` directly | CPU, AHB fabric, DMEM, AHB-side VGA control/write path | Canonical baseline clock |
| APB | `PCLK` | 50 MHz | `HCLK` through AHB-APB bridge | APB peripherals | Same clock as HCLK; no CDC at AHB/APB boundary |
| VGA pixel | `pclk_25` | 25 MHz | `vga_pll`, 50 MHz / 2 | VGA timing, VRAM read port | Generated clock domain |
| G-sensor controller | `PCLK` | 50 MHz | AHB-APB bridge | ADXL345/SPI control and XYZ registers | Same domain as APB; external registered SCLK is not a clock domain |
| ADC/Qsys | `adc_sys_clk` | vendor/Qsys-managed | `adc_qsys` from board `clk` | ADC command-channel sequencer / ADC subsystem | Generated vendor-managed domain; exact rate is not a canonical software contract |

The current architecture has no independently clocked AHB or APB bus. `PCLK` and `HCLK` are the same 50 MHz source.

## 4. System Clock

The active top-level directly assigns:

```verilog
wire HCLK = clk;
```

The external board input `clk` is the active 50 MHz CPU/AHB clock.

A `system_pll` instantiation exists in the source as commented-out code, but it is **not active** in the current FPGA baseline. The presence of `system_pll` source/IP files shall not be interpreted as evidence that the CPU is currently PLL-clocked.

### 4.1 Architectural Contract

Unless a future specification changes the clock plan first:

```text
board clk = HCLK = 50 MHz
```

is the baseline system-clock contract.

A future Fmax experiment may operate the design differently, but measured Fmax capability and the board's active operating frequency are separate concepts.

## 5. APB Clock

The active AHB-to-APB bridge defines:

```text
PCLK    = HCLK
PRESETn = HRESETn
```

Therefore:

- CPU/AHB and APB register logic are synchronous to the same 50 MHz source.
- The AHB-to-APB bridge performs protocol conversion, not clock-domain conversion.
- No asynchronous FIFO or CDC synchronizer is required solely at the HCLK/PCLK boundary in this baseline.

If a future design lowers the APB frequency or moves APB to another clock source, that change shall require an explicit clock-conversion/CDC architecture before RTL implementation.

## 6. VGA Pixel Clock

The active `AHB_VRAM_DUAL_BUFFER` instantiates `vga_pll`:

```text
input  : CLOCK_50 = 50 MHz
output : pclk_25  = 25 MHz
```

The generated PLL configuration uses a divide-by-2 output from the 50 MHz reference.

`pclk_25` clocks:

- VGA horizontal/vertical timing generation,
- visible-pixel sequencing,
- VRAM front-buffer read ports,
- VGA-side prefetch address generation.

The AHB-side VRAM write/control logic remains in the 50 MHz HCLK domain.

### 6.1 VGA PLL Reset / Lock Behavior

The current VGA PLL wrapper does not expose or use a PLL `locked` indication, and its PLL asynchronous reset input is not used by the generated wrapper.

Therefore the baseline does not explicitly gate VGA logic on PLL lock.

This behavior is an implementation property, not a preferred future reset/clock policy.

## 7. G-Sensor SPI Clocks

`APB_GSENSOR_MB` and `spi_ee_config` use only 50 MHz `PCLK`; the controller drives a registered external mode-3 SCLK with 12/13-PCLK half-periods. The historical two-output `spi_pll` has no active G-sensor instance or Quartus binding. The local reset delay described in §12 remains active in pinned A6 but is **not** a PLL-lock wait.

## 8. ADC / Qsys Clock Domain

The active top instantiates `adc_qsys` with:

```text
clk_clk                      <- board clk
clock_bridge_sys_out_clk_clk -> adc_sys_clk
reset_reset_n                <- HRESETn
```

A small top-level channel sequencer runs on `adc_sys_clk` and alternates channels 1 and 2 when the ADC command interface reports ready.

The exact `adc_sys_clk` frequency is currently treated as vendor/Qsys-managed implementation detail. Software-visible ADC behavior shall not depend on a hard-coded `adc_sys_clk` rate unless a later ADC specification and timing review explicitly establish it.

## 9. External Reset Source

The board reset source is:

```text
KEY[0]
```

with active-low polarity.

The top-level names it:

```text
RESETN_BTN = KEY[0]
```

The active reset-conditioning path has two stages:

1. asynchronous assertion / two-flop synchronization of the external button level into HCLK,
2. approximately 20 ms high-level qualification before system reset release.

## 10. Reset Synchronization and Release Qualification

### 10.1 Input Synchronizer

The reset button drives two HCLK-domain registers:

```text
RESETN_BTN
    |
    v
rstn_meta
    |
    v
rstn_sync
```

When `RESETN_BTN` is low, both synchronizer registers are asynchronously forced low. When the button is released high, the high level propagates through the two HCLK flip-flops.

### 10.2 Release Qualification

After `rstn_sync` is observed high, a 20-bit counter qualifies the release:

```text
1,000,000 cycles @ 50 MHz = 20 ms
```

`PRESETN_SYS` remains low until the counter reaches `999_999`, after which it is asserted high.

The baseline system reset is then:

```text
HRESETn = PRESETN_SYS
```

The total button-release-to-system-release delay is therefore approximately 20 ms plus synchronizer/edge alignment latency.

### 10.3 Assertion Semantics Quirk

The source comment describes reset-low behavior as immediate, but `PRESETN_SYS` itself is updated only in a `posedge HCLK` block.

Therefore the external button asynchronously clears the two input synchronizer stages, but the actual distributed `HRESETn` becomes low on a subsequent HCLK edge rather than through a direct asynchronous combinational path.

This distinction shall be preserved in verification and reviewed during baseline cleanup.

## 11. System Reset Distribution

`HRESETn` is the primary active-low reset distributed through the active SoC.

Representative usage:

| Consumer | Reset form |
|---|---|
| CPU | `reset = !HRESETn` (active-high CPU reset input) |
| AHB fabric / slaves | `HRESETn` active-low |
| AHB-to-APB bridge | `HRESETn` active-low |
| APB peripherals | `PRESETn`, where bridge provides `PRESETn = HRESETn` |
| VGA / VRAM control | `HRESETn` active-low |
| ADC Qsys | `reset_reset_n = HRESETn` |
| G-sensor wrapper | `PRESETn`, then local delayed reset generation |

`LEDR[9]` is driven as `~HRESETn` and acts as a visible reset-state indicator in the current top-level.

## 12. G-Sensor Local Reset Delay

The G-sensor subsystem adds a second local reset delay after APB/system reset release.

Pinned `reset_delay.v` contains a 20-bit counter. Its active-high `dly_rst` remains asserted through the all-ones count and deasserts on the following PCLK edge.

At 50 MHz, the local delay is approximately:

```text
2^20 / 50 MHz = 20.97152 ms
```

The local sequence is therefore conceptually:

```text
system PRESETn releases
       |
       v
~20.97 ms local delay
       |
       +--> spi_ee_config iRSTN releases
```

This current local delay is not a general APB reset requirement or a G-sensor PLL lock requirement. Under the P09B target it is removed from the active wrapper; `reset_delay.v` itself remains untouched unless later separately authorized.

## 13. CDC Inventory

The baseline contains real clock-domain crossings despite HCLK and PCLK being identical.

### 13.1 VGA VSync: pclk25 -> HCLK

The VGA vertical-sync signal is transferred into HCLK through a three-register synchronization chain:

```text
vga_vsync_sig (pclk_25)
        |
        v
      vsync_d1
        |
        v
      vsync_d2
        |
        v
      vsync_d3
        |
        v
edge detection in HCLK
```

The resulting HCLK-domain edge indication sets the software-visible VSync flag.

This is the clearest explicit CDC synchronizer in the active VGA subsystem.

### 13.2 VRAM Data Path: HCLK <-> pclk25

The framebuffer memories use separate write and read clocks:

```text
write port : HCLK
read port  : pclk_25
```

The vendor dual-port memory primitive is used as the structural boundary between the CPU write domain and VGA read domain.

The memory primitive, rather than ordinary RTL register sampling, carries framebuffer data between the two domains.

### 13.3 Front-Buffer Select: HCLK -> pclk25 — Cleanup Required

`front_buffer_idx` is written in the HCLK domain when software requests a buffer swap.

The same signal directly controls:

- which VRAM receives the pclk25 read address,
- which VRAM output is selected as `vga_rdata`.

There is no explicit synchronizer or pclk25-domain handshake for this control bit in the active RTL.

Therefore current operation depends on software timing and physical implementation behavior; CDC-safe buffer ownership transfer is **not formally established**.

A future cleanup shall move buffer-swap commit into a defined pclk25/HCLK handshake or otherwise synchronize the ownership state at a safe frame boundary.

### 13.4 G-Sensor Sample Data: historical CDC removed; CPU snapshot pending

A6 updates `out_acc_x/y/z` together in 50 MHz PCLK, so the former `spi_clk`→PCLK multi-bit CDC is not active. The APB wrapper nevertheless exposes X/Y and Z in separate reads, allowing a later completed burst between them. P09B specifies LIVE/HOLD banks for a coherent software-visible generation; this remains unimplemented at Stage 1. The `CDC-002`/`GS-001` tracker scope is not closed merely by removing the historical clock crossing.

### 13.5 ADC Response Path: adc_sys_clk -> PCLK — Cleanup Required

The Qsys ADC response signals are connected directly to the PCLK-domain `APB_ADC_Joystick_Controller`:

```text
adc_response_valid
adc_response_channel
adc_response_data
adc_response_startofpacket
adc_response_endofpacket
```

The PCLK-domain controller samples these signals in an ordinary `posedge PCLK` process. No explicit user-RTL synchronizer or asynchronous FIFO is present at this boundary.

Unless the generated Qsys interface itself guarantees that these exported response signals are synchronous to PCLK—which is not established by the current project specification—this path shall be treated as an unresolved CDC boundary and audited before major feature integration.

### 13.6 Reset Release Into Generated Domains

`HRESETn` is generated synchronously to HCLK but is also consumed by logic clocked from `pclk_25`, `adc_sys_clk`, and local generated clocks.

Several generated-domain registers use asynchronous reset assertion but do not have an explicit per-domain synchronized reset release.

The baseline therefore does not yet provide a formally defined **asynchronous assert / synchronous deassert per clock domain** reset architecture.

This is a cleanup target.

## 14. Clock-Domain Design Rules for Future Work

New RTL shall not add an unsynchronized crossing merely because two clocks originate from the same 50 MHz reference.

For every signal crossing between independently clocked domains, the design shall classify the crossing and implement an appropriate mechanism:

| Crossing type | Preferred mechanism |
|---|---|
| Single-bit level | 2+ FF synchronizer where latency is acceptable |
| Single-bit pulse | pulse stretching, toggle synchronizer, or handshake |
| Multi-bit control/data | handshake + stable data, async FIFO, or atomic snapshot |
| High-throughput stream | asynchronous FIFO / clock-converting interface |
| Dual-clock memory | verified dual-port memory primitive / wrapper |
| Reset release | synchronize deassertion in each destination domain |

A CDC exception shall be documented, not assumed.

## 15. Timing Constraints

The following one-line SDC description records the **initial reconstructed baseline**, before the Phase 3 `public_binding_05` clock-constraint update:

```tcl
create_clock -name {clk} -period {20.0} [get_ports {clk}]
```

The **current** public SDC additionally calls `derive_pll_clocks` and `derive_clock_uncertainty`; the approved 3B3 fitted clock inventory contains `clk`, VGA 25 MHz and ADC 25/10 MHz, with no active G-sensor SPI PLL clock. This still does **not** prove complete CDC or external I/O closure. The normative acceptance/exception/evidence rules are in [timing_constraints.md](timing_constraints.md); the historical warnings below describe the earlier reconstruction and are not a statement that they remain unresolved in that exact form.

Historical/current migration timing evidence reports:

- missing generated clocks associated with at least the ADC and VGA PLL paths,
- clock-transfer uncertainty warnings (`332168`, `332169`),
- a recommendation to apply clock uncertainty assignments or `derive_clock_uncertainty`.

Therefore successful timing closure on the primary `clk` domain shall not be interpreted as proof that all generated-domain paths are correctly constrained.

## 16. Timing / CDC Verification Policy

Before a future clock/reset architecture is considered frozen:

1. every active clock shall appear in the timing clock inventory,
2. every generated clock shall have a valid timing relationship or an explicit asynchronous relationship,
3. every cross-domain path shall have a documented CDC mechanism,
4. clock uncertainty shall be derived/assigned appropriately,
5. false paths and asynchronous clock groups shall only be applied after the hardware CDC mechanism is established,
6. reset recovery/removal behavior shall be reviewed for each active clock domain,
7. Quartus CDC/timing warnings shall be triaged rather than accepted solely because the board demo works.

## 17. Baseline Cleanup Targets Before Major Feature Integration

The following items are recorded for the later consolidated baseline-cleanup pass.

### 17.1 Reset Architecture

1. **Clarify/fix system reset assertion semantics**
   - The source comment implies immediate assertion, while distributed `HRESETn` is updated on HCLK.
   - Select and document the intended asynchronous-assert/synchronous-deassert architecture.

2. **Provide destination-domain reset synchronizers**
   - At minimum audit VGA, ADC, and G-sensor generated clock domains.
   - Ensure reset deassertion is safe relative to each destination clock.

3. **Review PLL lock handling**
   - Determine whether VGA/ADC domains require explicit PLL-lock-qualified reset release; frozen A6 removes the active SPI PLL domain in the cleanup target.

### 17.2 CDC Architecture

4. **Synchronize VGA front-buffer ownership transfer**
   - Replace the direct HCLK `front_buffer_idx` use in pclk25 logic with a defined frame-safe CDC handshake/synchronization scheme.

5. **Make G-sensor multi-bit sample transfer atomic**
   - Replace direct spi_clk-domain sample reads from PCLK with a CDC-safe snapshot/handshake.

6. **Audit/fix ADC response crossing**
   - Establish the actual Qsys clock contract and add a CDC bridge/FIFO/handshake if the response interface is asynchronous to PCLK.

7. **Audit asynchronous external inputs**
   - UART RX, LoRa AUX, G-sensor interrupt inputs, buttons/switches, and other asynchronous board inputs shall have explicit synchronization policy where required.

### 17.3 Timing Constraints

8. **Complete generated-clock constraints**
   - Ensure VGA, SPI, and ADC generated clocks are represented correctly in TimeQuest.

9. **Add/derive clock uncertainty**
   - Resolve the existing `332168/332169` warnings.

10. **Define asynchronous clock relationships only after CDC cleanup**
    - Avoid hiding unsafe crossings with false-path constraints.

11. **Add a repeatable clock/reset/CDC review report**
    - Future Quartus build evidence should include clock inventory, unconstrained paths, CDC assumptions, and reset-domain review.

These cleanup items shall later be consolidated into the project-wide `baseline_cleanup.md` before PLIC/AXI implementation starts.

## 18. Baseline Clock / Reset Invariants

The following are current baseline invariants:

1. Active CPU/AHB operating clock is the direct 50 MHz board clock.
2. APB runs synchronously at the same 50 MHz clock as AHB.
3. The active VGA pixel clock is 25 MHz generated from the 50 MHz reference.
4. The G-sensor block keeps all internal state in the 50 MHz PCLK domain and drives a registered external 2 MHz-class SPI clock; it has no internal SPI generated-clock domain.
5. ADC/Qsys generates the fitted 25 MHz `adc_sys_clk` and a 10 MHz hard-IP clock; these remain vendor-managed implementation clocks rather than software-visible timing contracts.
6. `KEY[0]` is the active-low board reset source.
7. System reset release is qualified for approximately 20 ms after synchronization.
8. G-sensor initialization adds an additional approximately 20.97 ms local reset delay.
9. VGA VSync uses an explicit multi-flop crossing into HCLK.
10. VGA buffer ownership and ADC response CDC remain unresolved; G-sensor's former internal SPI-to-PCLK crossing is removed, but its cross-read XYZ/VALID/SEQ coherency remains unresolved.
11. The intended internal clocks are represented and constrained at the P05C checkpoint; final P14 stability/exception review and separate STA-002 external-I/O closure remain incomplete.
12. No new feature may treat an existing CDC/timing gap as an architectural requirement to preserve.

## 19. Related Specifications

This document shall be read with:

- `soc_architecture.md` — system topology
- `cpu_interface.md` — CPU pipeline/bus timing
- `ahb_fabric.md` — HCLK-side system interconnect
- `apb_subsystem.md` — PCLK/APB behavior
- `vga.md` — VGA/VRAM clock-domain behavior
- `gsensor.md` / `spi.md` — G-sensor local clocking
- `adc_joystick.md` — ADC interface behavior
- future `baseline_cleanup.md` — consolidated cleanup execution checklist

## Phase 4A-2 Approved Clock and External-I/O Target — Implementation Status

A1 external `GPIO_IO[15:0]` inputs use two PCLK synchronizer flops; DIR reset is input/Hi-Z. Phase 4A-GSENSOR implemented A6: 50 MHz PCLK is the only active G-sensor state/register clock, registered external SCLK is an output rather than an internal clock, and `GSENSOR_INT[1]` enters a two-flop PCLK synchronizer. The historical private `spi_pll` artifact remains stored but has no active instance or binding. The `gsensor_pclk_01` user-run fit lists only the system `clk` and ADC/VGA generated clocks; 50 MHz setup/hold is positive in both slow corners. Remaining ADC/VGA clock/reset work stays under STA-001/RST-002. Removing the G-sensor generated domain does not establish software-visible VALID/SEQ or cross-APB-read atomicity, so `GS-001`/`CDC-002` remain open.

Approved STA-002 separately owns board-facing I/O timing/electrical closure: port classification, evidence-based delays or documented N/A, I/O voltage/standard/drive/load, unconstrained ports, G-sensor SPI peer timing, ADC/VGA placement warning and ADC measurement with VGA activity. No arbitrary input/output delays shall be invented for asynchronous/static/analog ports. Detailed Phase 4A-GSENSOR timing evidence remains in the private local evidence archive.

## Phase 4A-P05A Approved Reset Policy — Implementation Target

User/Chat approved the project reset policy as asynchronous assertion where appropriate plus synchronous deassertion in every project-owned destination clock domain. The implementation shall preserve the approximately 20 ms `KEY[0]` release qualification, make cold start deterministic, keep a stopped destination domain in reset until its clock resumes, and avoid reset logic added only for stylistic uniformity.

For VGA, Option A is approved: regenerate the private `vga_pll` through the vendor flow to expose `locked`—never hand-edit generated HDL—assert pixel reset when system reset is active or lock is low, deassert through a `pclk_25`-domain synchronizer only after system reset is released and lock is high, and reassert pixel reset on lock loss. The public model/interface and private binding evidence must remain synchronized with the regenerated IP.

ADC/Qsys internal reset controllers remain a documented vendor-managed exception. Project-owned ADC sequencing outside Qsys shall use a local `adc_sys_clk` synchronized reset release and shall keep command-valid inactive until that local release. The PCLK-only G-sensor reset/clock structure remains unchanged. These are approved P05B targets, not claims about the current RTL; implementation and verification are still pending.

## Phase 4A-P05B Reset / Clock Infrastructure — Current Implementation

P05B implements the approved policy in the current public candidate. `system_reset_controller` gives `KEY[0]` an asynchronous assertion path and an HCLK-only release after the existing 1,000,000-cycle qualification. Its reset/synchronizer/counter state has explicit Quartus-supported LOW power-up conditions, so configuration with the button already released still begins in reset. The production value remains approximately 20 ms at 50 MHz; tests reduce only the parameter value, not the sequencing rule.

`reset_release_sync` is the project-owned asynchronous-assert/synchronous-deassert primitive. VGA reset request is `HRESETn AND vga_pll_locked`; its release traverses two `pclk_25` stages, and loss of PLL lock immediately reasserts reset for VGA timing, pixel address, and VRAM read-side state. The private Quartus 19.1 `vga_pll` was vendor-regenerated to add `locked` while retaining c0 at 25 MHz, divide-by-2, 50% duty, and 0° phase. Generated private collateral remains outside the public repository; the public model and manifest expose the same `inclk0/c0/locked` contract.

The project-owned ADC command sequencer now receives an `adc_sys_clk`-local synchronized reset and holds `command_valid=0` until release. The generated Qsys reset implementation is unchanged. G-sensor remains wholly PCLK-owned with no active internal SPI PLL domain. The SDC remains unchanged.

P05C fitted evidence confirms that the system reset controller, VGA/ADC local reset synchronizers, and VGA `locked` interface survive fit; all intended internal clocks are constrained; no G-sensor internal generated clock appears; and setup/hold/recovery/removal are positive with TNS 0. `RST-001`, `RST-002`, and `CDC-004` are therefore VERIFIED. `STA-001` remains IN_PROGRESS for final P14 multicorner/stability and exception review. ADC response CDC (`CDC-003`), VGA buffer-ownership CDC (`CDC-001`), and external I/O/electrical closure (`STA-002`) remain separate.

## P09B G-sensor clock/reset contract — paired publication update

> **Current Public integration:** Direct `PRESETn` is the implemented P09B contract. Historical A6 local-delay text remains historical; external reset/timing acceptance is not promoted.

> **Publication synchronization:** The direct `PRESETn` implementation below is paired with the P09B source commit. Historical A6 local-delay text remains historical; external reset/timing acceptance is not promoted.

The isolated P09B candidate retains the A6 single 50 MHz PCLK architecture and registered mode-3 external SCLK. It removes the wrapper's second `reset_delay` instance and obsolete `RESET_DELAY_BITS` parameter, directly connects `spi_ee_config.iRSTN=PRESETn`, and gives LIVE/HOLD banks, IRQ synchronizer/history, one pending slot and watchdog that same `PRESETn`. It does not modify `system_reset_controller`, bridge reset, `reset_delay.v`, clock domains or CDC exemptions. `KEY[0]` LOW still asserts the shared reset asynchronously; release remains two-flop synchronized plus 1,000,000 qualified 50 MHz edges (~20 ms). The former extra ~20.97152 ms (roughly 41 ms total) is historical A6 behavior. After common release, twelve ordered SPI writes must finish and CS return HIGH before acquisition/watchdog arm. This is not measured startup or proven sensor supply readiness, and is not a claim about current Public `main`.

Common synchronous **release** does not prevent asynchronous **assertion** from intersecting APB SETUP/ACCESS, CAPTURE, E0/E1, HOLD ownership or an active 56-bit SPI burst. Assertion aborts unfinished bus/sensor work; no read that failed to complete before assertion is an accepted transfer or has a guaranteed value/completion. A completed read remains historical. Reset dominates and clears both bank payloads/valid/seq, scheduler and pending state; no stale publication survives. During asserted reset, no initialization/acquisition occurs. After release, APB may operate but VALID remains zero until a new complete burst. No stronger response promise is inferred from reset-overlapped bridge/CPU traffic. The precise ownership/priority table and planned directed checks are in [12_gsensor.md](12_gsensor.md). Physical sensor rail/startup, short INT pulses and pin timing remain external NOT_RUN risks; prior P05C fit does not close them or `GS-001`, `GS-005`, `CDC-002`, `STA-002`.
