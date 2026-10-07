# Baseline SoC Reset and Clock Specification

> **Status:** Current baseline reset/clock contract. `RST-001` and `RST-002` are accepted prerequisites; VGA ownership CDC `CDC-001` remains OPEN and is governed in detail by `08_vga.md`.
>
> **Canonical language:** English. If this file and `kor/06_reset_clock.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `ahb_fabric.md`, `apb_subsystem.md`.

> **Current G-sensor reset contract:** The integrated P09B architecture uses single 50 MHz PCLK and direct shared PRESETn. The historical local reset_delay instance is no longer part of the active wrapper path, and external SPI SCLK is a registered output rather than an internal clock domain.

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
              |      +--> G-sensor controller (PCLK-only, shared PRESETn)
              |             +--> registered external SCLK ~2 MHz
              |
              +--> VGA PLL
                     |
                     +--> pclk_25 = 25 MHz

KEY[0] (active-low)
      |
      v
system_reset_controller
  asynchronous assertion /
  2-FF HCLK release synchronization
      |
      v
~20 ms HCLK release qualification
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
| ADC/Qsys | `adc_sys_clk` | 25 MHz | `adc_qsys` from board `clk`; separate 10 MHz ADC hard-IP input | P11 ADC acquisition engine / vendor ADC subsystem | Generated domain; configured total ADC sampling rate is 1 MSPS, while effective project frame cadence is separate |

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

The VGA PLL remains free-running from `CLOCK_50`; this contract does not require a new PLL reset input or sequence. Its active interface exposes `vga_pll_locked`. Pixel-domain reset request is the conjunction:

```text
HRESETn & vga_pll_locked
```

and release occurs only through the `pclk_25`-clocked `reset_release_sync` primitive. System reset or PLL lock loss therefore asserts the VGA pixel reset; release requires system reset released, PLL lock high, and destination-domain synchronous release. This P05 architecture is an **accepted prerequisite** (`RST-002`) and shall be preserved.

PLL lock qualification is not itself VGA ownership CDC closure. The HCLK↔pixel request/commit/ACK/ownership protocol remains tracked by `CDC-001`; its normative transaction semantics are defined in `08_vga.md`.


## 7. G-Sensor SPI Clocks

`APB_GSENSOR_MB` and `spi_ee_config` use only 50 MHz `PCLK`; the controller drives a registered external mode-3 SCLK with 12/13-PCLK half-periods. The historical two-output `spi_pll` has no active G-sensor instance or Quartus binding. The G-sensor controller connects directly to shared `PRESETn`; the historical local `reset_delay` is inactive in P09B.

## 8. ADC / Qsys Clock and Reset Domain — P11 Target (In-progress)

P11A establishes the generated instance clocks as:

```text
board clk                     = 50 MHz
adc_sys_clk                   = 25 MHz
ADC hard-IP input clock       = 10 MHz
configured ADC total rate     = 1 MSPS
```

`adc_qsys` remains a vendor-managed subsystem and receives:

```text
clk_clk                      <- board clk
clock_bridge_sys_out_clk_clk -> adc_sys_clk
reset_reset_n                <- HRESETn
```

The generated Qsys implementation internally uses its PLL-lock/reset-controller infrastructure. PLL `locked` is not exported to project-local top RTL in the current generated interface and shall not be created by hand-editing generated HDL.

Project-owned P11 acquisition logic runs on `adc_sys_clk` and uses a project-local `adc_reset_n` generated by `reset_release_sync` from qualified `HRESETn`. Thus reset assertion is asynchronous where implemented by the primitive, while deassertion is synchronized to `adc_sys_clk`.

HCLK/PCLK does **not** require another local release synchronizer: `HRESETn` is already qualified/released in HCLK and `PCLK=HCLK`.

P11 command/response cadence, vendor lock-loss recovery, and exact accepted-command-to-response timing remain **(In-progress)** verification and shall not be inferred solely from the 25/10 MHz clocks or the configured 1 MSPS sampling rate.

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

### 10.3 System Reset Assertion Contract

`KEY[0]` low causes asynchronous assertion of distributed `HRESETn` through `system_reset_controller`; assertion does not wait for an HCLK edge. Reset release is synchronized and qualified in HCLK and occurs only after the existing 1,000,000-cycle (approximately 20 ms at 50 MHz) high-level release qualification, plus synchronizer/edge-alignment latency.

This preserves the accepted P05 `RST-001` / `RST-002` semantics. The historical next-HCLK-edge assertion description is superseded and is not the current contract.

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
| G-sensor controller / banks | `PRESETn` directly (shared with APB bridge) |

`LEDR[9]` is driven as `~HRESETn` and acts as a visible reset-state indicator in the current top-level.

## 12. G-Sensor Reset Architecture

In the integrated P09B architecture, the G-sensor controller (`spi_ee_config`), LIVE/HOLD banks, acquisition scheduler, IRQ synchronizer/history, and 30 ms watchdog connect directly to shared `PRESETn`.

The local `reset_delay` instance and the wrapper `RESET_DELAY_BITS` parameter are removed from the active P09B wrapper path.

Reset assertion may asynchronously abort unfinished APB or SPI operations. Reset release follows the existing system reset qualification (two-stage HCLK synchronization plus 1,000,000 PCLK cycles, approximately 20 ms). After synchronous reset release, the controller immediately begins its 12 ordered ADXL345 initialization writes.

### 12.1 Historical G-Sensor Local Reset Delay

The historical A6 baseline added a second local reset delay after system reset release using `reset_delay.v`. Its 20-bit counter held the G-sensor controller in reset for an additional 2^20 / 50 MHz ≈ 20.97152 ms (total delay approximately 41 ms after button release). The `reset_delay.v` source file is retained in the repository for provenance, but its instantiation is inactive in the current P09B baseline.

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

### 13.3 VGA Ownership Protocol: HCLK <-> pclk25 — `CDC-001` OPEN

The active VGA ownership interface is no longer the historical direct HCLK `front_buffer_idx` selector. The logical protocol is:

```text
HCLK                                  pclk_25
accepted SWAP-bearing operation
  -> publish one swap-request epoch
        -- synchronized event ------> pending swap
                                      |
                                      +-- commit front ownership only
                                      |   at (799,524)->(0,0)
                                      v
        <------ post-commit ACK ------+
consume synchronized ACK
  -> update HCLK ownership view
```

The pixel-domain display owner and the HCLK writable-owner view may differ transiently after pixel commit and before ACK synchronization. During that interval the one-outstanding-operation rule keeps framebuffer writes blocked. Clear-only does not require a pixel ownership request; combined SWAP+CLEAR performs swap commit/ACK first and clears the resulting new back bank afterward.

The logical swap request has event semantics. Any concrete internal bit used to encode/qualify the request is an implementation detail and does not create a normative multi-bit payload contract. Its stability and synchronizer topology remain subject to later structural/static CDC review.

Reset or PLL lock loss starts a new ownership epoch. Recovery must rebase ownership and request/ACK observation state, suppress stale pre-recovery events, keep `DOMAIN_READY=0` until the new pixel epoch is established, and allow the next valid transaction to make progress. Full system reset clears VGA status state; PLL lock loss with system reset released uses the software-visible `OP_ABORT` behavior defined in `08_vga.md`.

This section freezes the **behavioral architecture** only. `CDC-001` remains OPEN until independent async/reset behavioral verification and separate structural CDC review are accepted. Positive STA does not prove this protocol correct.


### 13.4 G-Sensor Sample Data: Single PCLK Domain and Coherent Snapshot

Historical multi-bit `spi_clk -> PCLK` CDC was removed by the A6 PCLK-only conversion. The P09B architecture additionally eliminates software-visible torn sample reads across separate APB reads by introducing coherent LIVE and HOLD sample banks with atomic CAPTURE/RELEASE, VALID gating, and SEQ tracking.

Therefore, no active internal CDC hazard exists between the SPI controller and the CPU interface. `CDC-002` remains `IN_PROGRESS` solely for conservative engineering-closure criteria (such as exhaustive reset-negative coverage and physical verification), not because an active unsafe clock crossing remains in the RTL.

### 13.5 ADC Scan Frame: adc_sys_clk -> PCLK — P11 Target (In-progress)

The historical direct Qsys response crossing is not part of the P11 target contract.

A completed ADC scan frame shall cross through a stable bundled-data request/acknowledge toggle mailbox:

```text
adc_sys_clk source:
  complete frame -> stable payload -> REQ toggle -> hold until ACK

PCLK destination:
  synchronize REQ -> atomically capture whole frame into LIVE -> return ACK
```

The source shall hold the complete frame payload stable until ACK and shall not overwrite the payload or publish another completed frame while the mailbox is busy. The acquisition engine may pause at the frame boundary until acknowledgement. This makes the P11 baseline a coherent/lossless-at-publication latest-state channel rather than a maximum-throughput stream.

An asynchronous FIFO is required instead if multiple frames must accumulate per handshake round trip, acquisition cannot pause, every high-rate frame must be retained, destination stalls can be long while acquisition continues, or a future DMA/SDRAM streaming path is introduced.

No live Qsys response bus field may be exposed directly through APB after P11. P11 frame CDC implementation/verification and vendor lock-loss/protocol verification remain **(In-progress)**; this target description is not an implementation-completion or closure claim.

### 13.6 Reset Release Into Generated Domains

The reset architecture distinguishes **central reset policy** from **destination-domain release synchronization**.

```text
KEY[0] -> system_reset_controller -> HRESETn
  +-> HCLK/PCLK logic directly
  +-> (HRESETn & vga_pll_locked)
  |      -> reset_release_sync(pclk_25) -> vga_reset_n
  +-> reset_release_sync(adc_sys_clk)
  |      -> adc_reset_n for project-owned ADC logic
  +-> adc_qsys reset port
         -> vendor-managed internal reset/lock behavior
```

HCLK/PCLK is already release-qualified in HCLK and `PCLK=HCLK`, so it shall not receive an unnecessary second synchronizer. Every independently generated project-owned domain shall deassert reset relative to its own destination clock. The VGA PLL remains free-running from `CLOCK_50`; no new PLL reset requirement is introduced.

For ADC, Qsys internal reset/PLL-lock behavior is a documented vendor boundary, while project-local acquisition logic uses `adc_reset_n`. P11 verification shall exercise reset during partial assembly/mailbox activity and vendor lock/reset recovery where feasible before claiming full generated-domain closure.

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

## 17. Current Cleanup Coordination Relevant to VGA CDC

The project-wide status owner is `baseline_cleanup.md`; this specification does not duplicate the full cleanup checklist. For the VGA CDC/reset boundary:

| Item | Current status | Contract role |
|---|---|---|
| `RST-001` | VERIFIED | Accepted system-reset prerequisite; preserve asynchronous assertion / qualified HCLK release behavior. |
| `RST-002` | VERIFIED | Accepted generated-domain reset/PLL-lock prerequisite; preserve `vga_pll_locked` qualification and pclk_25 synchronized release. |
| `CDC-001` | OPEN | Freeze and later prove the VGA request/commit/ACK/ownership/recovery protocol defined in Sections 6 and 13 and in `08_vga.md`. |
| `VER-003` | OPEN | Later independent asynchronous-clock/reset behavioral verification; not performed by this specification stage. |
| `STA-001` | IN_PROGRESS | Separate timing/exception/recovery-removal review; no CDC correctness claim follows from timing PASS. |

Older broad cleanup target lists are historical coordination material; current status and required outcome are owned by `baseline_cleanup.md`.


## 18. Baseline Clock / Reset Invariants

The following are current baseline invariants:

1. Active CPU/AHB operating clock is the direct 50 MHz board clock.
2. APB runs synchronously at the same 50 MHz clock as AHB.
3. The active VGA pixel clock is 25 MHz generated from the 50 MHz reference.
4. The G-sensor block keeps all internal state in the 50 MHz PCLK domain and drives a registered external 2 MHz-class SPI clock; it has no internal SPI generated-clock domain.
5. ADC/Qsys generates the fitted 25 MHz `adc_sys_clk` and a 10 MHz hard-IP clock; these remain vendor-managed implementation clocks rather than software-visible timing contracts.
6. `KEY[0]` is the active-low board reset source.
7. `KEY[0]` low asynchronously asserts system reset through `system_reset_controller`; release is HCLK-synchronized and qualified for approximately 20 ms.
8. G-sensor initialization uses shared PRESETn directly; the historical ~20.97 ms local reset delay is inactive in P09B.
9. VGA VSync uses an explicit multi-flop crossing into HCLK.
10. VGA ownership uses the request/commit/ACK architecture defined above, but `CDC-001` remains OPEN until later independent behavioral and structural CDC acceptance. The historical direct-selector architecture is not current. The historical direct ADC response crossing is superseded by the frozen P11 scan-frame mailbox target architecture; its implementation/verification remains **(In-progress)**; G-sensor internal SPI-to-PCLK crossing is removed and cross-read XYZ/VALID/SEQ coherency is resolved by P09B LIVE/HOLD snapshot.
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

## Appendix A. Historical / Milestone Notes

The notes below preserve milestone history and accepted prerequisite provenance. Where a historical target statement conflicts with Sections 1–19, the current active contract in Sections 1–19 governs.

### A.1 Phase 4A-2 Approved Clock and External-I/O Target — Historical Status

A1 external `GPIO_IO[15:0]` inputs use two PCLK synchronizer flops; DIR reset is input/Hi-Z. Phase 4A-GSENSOR implemented A6: 50 MHz PCLK is the only active G-sensor state/register clock, registered external SCLK is an output rather than an internal clock, and `GSENSOR_INT[1]` enters a two-flop PCLK synchronizer. The historical private `spi_pll` artifact remains stored but has no active instance or binding. The `gsensor_pclk_01` user-run fit lists only the system `clk` and ADC/VGA generated clocks; 50 MHz setup/hold is positive in both slow corners. Remaining ADC/VGA clock/reset work stays under STA-001/RST-002. P09B resolves software-visible VALID/SEQ and cross-APB-read atomicity via LIVE/HOLD snapshot; `GS-001`/`CDC-002` remain IN_PROGRESS for residual engineering closure evidence.

Approved STA-002 separately owns board-facing I/O timing/electrical closure: port classification, evidence-based delays or documented N/A, I/O voltage/standard/drive/load, unconstrained ports, G-sensor SPI peer timing, ADC/VGA placement warning and ADC measurement with VGA activity. No arbitrary input/output delays shall be invented for asynchronous/static/analog ports. Detailed Phase 4A-GSENSOR timing evidence remains in the private local evidence archive.

### A.2 Phase 4A-P05A Approved Reset Policy — Historical Target

User/Chat approved the project reset policy as asynchronous assertion where appropriate plus synchronous deassertion in every project-owned destination clock domain. The implementation shall preserve the approximately 20 ms `KEY[0]` release qualification, make cold start deterministic, keep a stopped destination domain in reset until its clock resumes, and avoid reset logic added only for stylistic uniformity.

For VGA, Option A is approved: regenerate the private `vga_pll` through the vendor flow to expose `locked`—never hand-edit generated HDL—assert pixel reset when system reset is active or lock is low, deassert through a `pclk_25`-domain synchronizer only after system reset is released and lock is high, and reassert pixel reset on lock loss. The public model/interface and private binding evidence must remain synchronized with the regenerated IP.

ADC/Qsys internal reset controllers remain a documented vendor-managed exception. Project-owned ADC sequencing outside Qsys shall use a local `adc_sys_clk` synchronized reset release and shall keep command-valid inactive until that local release. The PCLK-only G-sensor reset/clock structure remains unchanged. At the historical P05A stage these were approved P05B targets with implementation and verification pending; the accepted P05 prerequisite outcome is recorded in A.3.

### A.3 Phase 4A-P05B Reset / Clock Infrastructure — Accepted Prerequisite History

P05B implements the approved policy in the current public candidate. `system_reset_controller` gives `KEY[0]` an asynchronous assertion path and an HCLK-only release after the existing 1,000,000-cycle qualification. Its reset/synchronizer/counter state has explicit Quartus-supported LOW power-up conditions, so configuration with the button already released still begins in reset. The production value remains approximately 20 ms at 50 MHz; tests reduce only the parameter value, not the sequencing rule.

`reset_release_sync` is the project-owned asynchronous-assert/synchronous-deassert primitive. VGA reset request is `HRESETn AND vga_pll_locked`; its release traverses two `pclk_25` stages, and loss of PLL lock immediately reasserts reset for VGA timing, pixel address, and VRAM read-side state. The private Quartus 19.1 `vga_pll` was vendor-regenerated to add `locked` while retaining c0 at 25 MHz, divide-by-2, 50% duty, and 0° phase. Generated private collateral remains outside the public repository; the public model and manifest expose the same `inclk0/c0/locked` contract.

The project-owned ADC command sequencer now receives an `adc_sys_clk`-local synchronized reset and holds `command_valid=0` until release. The generated Qsys reset implementation is unchanged. G-sensor remains wholly PCLK-owned with no active internal SPI PLL domain. The SDC remains unchanged.

P05C fitted evidence confirms that the system reset controller, VGA/ADC local reset synchronizers, and VGA `locked` interface survive fit; all intended internal clocks are constrained; no G-sensor internal generated clock appears; and setup/hold/recovery/removal are positive with TNS 0. `RST-001`, `RST-002`, and `CDC-004` are therefore VERIFIED. `STA-001` remains IN_PROGRESS for final P14 multicorner/stability and exception review. ADC response CDC (`CDC-003`), VGA buffer-ownership CDC (`CDC-001`), and external I/O/electrical closure (`STA-002`) remain separate.

### A.4 P11 ADC Reset / CDC Freeze Note

The P11 ADC target preserves the P05 reset architecture rather than replacing it. `system_reset_controller` remains the owner of external reset conditioning and the approximately 20 ms HCLK release qualification; `reset_release_sync` remains the reusable destination-domain primitive.

P11 therefore does **not** fold `adc_sys_clk` deassertion into one multi-clock `system_reset_controller`. Central policy remains centralized; destination synchronizers remain distributed. Project-local ADC logic uses `adc_reset_n`; Qsys internal reset/PLL-lock behavior remains vendor-managed. Do not invent a project-top PLL `locked` export or hand-edit generated HDL.

The established `adc_sys_clk=25 MHz`, ADC hard-IP input `10 MHz`, and configured total ADC rate `1 MSPS` are the clock facts in Sections 3 and 8, not evidence of P11 frame cadence or CDC closure. The P11 target replaces historical direct response sampling with a stable bundled-data req/ack mailbox for complete frames from `adc_sys_clk` to PCLK: source holds payload stable until ACK, does not overwrite/publish the next completed frame while busy, and destination synchronizes the request and atomically captures the whole frame.

P11 status:

- global HCLK/PCLK reset policy: already implemented/verified by P05 scope;
- project-local ADC reset synchronizer: existing infrastructure retained;
- ADC response/frame CDC replacement: **(In-progress)**;
- Qsys lock-loss/vendor protocol behavior under P11: **(In-progress)**;
- external ADC/VGA electrical/placement closure: separate `STA-002` scope.

### A.5 P09B G-Sensor Clock and Reset Integration Note

The integrated P09B implementation operates entirely in the single 50 MHz PCLK domain with registered mode-3 external SCLK. It connects `spi_ee_config.iRSTN` directly to `PRESETn`, sharing the system reset qualification without an active local `reset_delay` instance. LIVE/HOLD banks, IRQ synchronization/history, pending scheduler state, and the 30 ms watchdog all share this same `PRESETn`.

Reset assertion is asynchronous and aborts any active SPI transaction or APB transfer in flight; reset release is synchronized to PCLK through the system reset qualification (~20 ms). Reset clears both LIVE and HOLD banks, SEQ, VALID, and pending scheduler states. External ADXL345 board timing and electrical characterization remain tracked under `STA-002` / `SPI-002`.
