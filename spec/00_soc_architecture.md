# Baseline SoC Architecture Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `soc_architecture.ko.md` conflict, this file is authoritative.
>
> **Scope:** Current FPGA board-validated baseline in `rtl/`, excluding the frozen PLIC development snapshot under `verification/legacy/`.

## 1. Purpose

This document defines the top-level architecture of the imported FPGA SoC baseline. It establishes the architectural boundaries that all lower-level specifications, RTL changes, firmware, verification, and FPGA integration work shall use as the starting contract.

This is a **baseline reconstruction**: the existing FPGA implementation predates the authoritative `spec/` flow, so the current active RTL, firmware memory map, active Quartus source list, and preserved validation evidence are used to recover the implemented architecture. After this baseline specification is approved, future implementation work shall be driven from `spec/` rather than inferred from RTL.

This document intentionally does not duplicate detailed register maps or cycle-level peripheral behavior. Those requirements belong in the corresponding subordinate specification documents.

## 2. Source-of-Truth Boundary for This Baseline

For reconstruction of the current baseline only, architectural evidence is interpreted in the following order:

1. Active Quartus project source list and top-level integration (`fpga/quartus/project/AMBA_SoC_TOP.qsf`, `rtl/soc/AMBA_SoC_TOP.v`).
2. RTL reachable from the active top-level instance hierarchy.
3. Active firmware BSP, linker script, headers, and drivers under `firmware/`.
4. Current integration/build evidence under `reports/integration/`.
5. Current non-legacy documentation.
6. Historical material under `docs/legacy/`, `reports/**/legacy/`, and `verification/legacy/`.

Historical or legacy material may explain design intent but shall not silently override the active FPGA implementation.

After baseline approval, the priority changes: `spec/` becomes the authoritative architecture and behavioral contract.

## 3. Baseline Identification

The baseline targets the Intel/Altera **DE10-Lite** board and the **MAX 10 10M50DAF484C7G** FPGA.

The active SoC top-level module is:

```text
AMBA_SoC_TOP
```

The external system input clock is **50 MHz**. The CPU/AHB/APB domain operates from this clock in the current baseline. Additional clocks are generated locally for display and sensor-related functions.

The baseline contains:

- RV32I 5-stage pipelined CPU.
- Local instruction memory.
- Single-master AHB-style system data bus.
- AHB-connected data memory.
- AHB-connected VGA/VRAM subsystem.
- AHB-to-APB bridge.
- Eight APB peripheral slots.
- Dual UART instances for LoRa and PC communication.
- GPIO.
- Polling timer.
- ADXL345 accelerometer subsystem with internal SPI engine.
- AES-GCM accelerator.
- MAX 10 ADC joystick controller.
- Six-digit seven-segment display controller.
- VGA 640x480 display path with dual VRAM buffers.

The baseline **does not contain an integrated PLIC or external interrupt path**.

## 4. Top-Level Architecture

### 4.1 Block Diagram

```text
                                      +----------------------------------+
                                      |        AMBA_SoC_TOP              |
                                      |                                  |
      clk 50 MHz -------------------->| HCLK / system clock              |
      KEY[0] ------------------------>| reset conditioning               |
                                      |                                  |
                                      |  +----------------------------+  |
                                      |  | RV32I 5-stage CPU          |  |
                                      |  | RV32I46F5SPMMIO            |  |
                                      |  |                            |  |
                                      |  | +------------------------+ |  |
                                      |  | | Local IMEM, 16 KiB     | |  |
                                      |  | +------------------------+ |  |
                                      |  +-------------+--------------+  |
                                      |                |                 |
                                      |      EX/MEM load/store          |
                                      |                |                 |
                                      |  +-------------v--------------+  |
                                      |  | AHB_Master_Interface       |  |
                                      |  | single-beat transfers      |  |
                                      |  +-------------+--------------+  |
                                      |                |                 |
                                      |      system data bus            |
                                      |                |                 |
                     +----------------+----------------+----------------+
                     |                |                |                |
                     v                v                v                |
              +-------------+  +----------------+  +----------------+  |
              | AHB DMEM    |  | AHB VRAM/VGA   |  | AHB->APB       |  |
              | 32 KiB BRAM |  | dual buffer    |  | bridge         |  |
              |             |  | 640x480 1 bpp  |  +-------+--------+  |
              +-------------+  +-------+--------+          |           |
                                      |                    | APB       |
                                      | VGA                |           |
                                      v                    v           |
                              VGA_R/G/B, HS, VS     +------+------+----+------+
                                                    |      |      |           |
                                                    v      v      v           v
                                                 UART0   GPIO   TIMER      GSENSOR
                                                 LoRa                    ADXL345
                                                    |      |      |           |
                                                    +------+------+-----------+
                                                           |
                                                    +------+------+-----------+
                                                    |      |      |           |
                                                    v      v      v           v
                                                 AES-GCM JOYSTICK UART1      HEX
                                                         ADC     PC          6-digit
                                      +----------------------------------+
```

### 4.2 Architectural Data Paths

The baseline has two distinct CPU memory paths:

1. **Instruction fetch path**
   - The CPU fetches instructions from a local instruction memory instantiated as part of the CPU-side implementation.
   - Instruction fetch traffic does not traverse the AHB system data bus.

2. **Load/store path**
   - CPU load/store operations are exported from the pipeline into `AHB_Master_Interface`.
   - The address phase is sourced from the EX-stage memory operation.
   - Store data is sourced from the following pipeline stage so that write data aligns with the bus data phase.
   - Bus backpressure is converted to a CPU pipeline stall request through `HREADY`.

No instruction cache, data cache, DMA master, or multi-master arbitration fabric is part of this baseline.

## 5. CPU Architecture Boundary

The integrated CPU module is `RV32I46F5SPMMIO`.

The architectural CPU baseline is:

- 32-bit RISC-V integer core.
- RV32I software model.
- Five pipeline stages: IF, ID, EX, MEM, WB.
- 32-bit address and data path.
- Pipeline forwarding and hazard handling.
- Load/store alignment support for RISC-V byte, halfword, and word operations inside the CPU/memory path.
- Bus-induced full-pipeline stall support.
- Synchronous trap handling for implemented exception/trap cases.

The CPU is not specified as a generic reusable AMBA master by itself. The SoC integration contract is the combination of:

```text
RV32I46F5SPMMIO
        +
AHB_Master_Interface
```

Detailed pipeline-to-bus timing, transfer size encoding, store alignment, load extension, and stall semantics are defined in `cpu_interface.md`.

## 6. Interconnect Architecture

### 6.1 System Bus Topology

The baseline uses a **single-master, non-arbitrated AHB-style data interconnect**.

There is exactly one active bus master:

```text
CPU -> AHB_Master_Interface
```

There is no bus arbiter because no second AHB master exists in the baseline.

The AHB master generates single transfers only. Burst operation is not part of the baseline architectural contract.

The top level performs address decode and data-phase response multiplexing for three logical AHB targets:

| Target | Canonical base | Architectural purpose |
|---|---:|---|
| DMEM | `0x1000_0000` | CPU data RAM |
| VRAM/VGA | `0x2000_0000` | Framebuffer and display control |
| APB bridge | `0x4000_0000` | Low-bandwidth peripheral subsystem |

Detailed decode and response timing are specified in `ahb_fabric.md`.

### 6.2 AHB-to-APB Bridge

The APB bridge converts CPU AHB data transfers into APB SETUP/ACCESS transactions.

The current APB domain uses the same effective system clock as HCLK:

```text
PCLK = HCLK = 50 MHz
```

The bridge owns:

- APB address/control capture.
- SETUP and ACCESS sequencing.
- AHB backpressure while an APB transfer is in progress.
- Eight-way `PSEL` generation.
- Read-data return from APB to AHB.

All current APB slaves expose `PREADY = 1`, but the bridge architecture supports waiting for `PREADY` and propagating that wait through `HREADY`.

Detailed behavior is defined in `apb_subsystem.md`.

## 7. Memory Architecture

### 7.1 Instruction Memory

The canonical instruction-memory region is:

```text
0x0000_0000 - 0x0000_3FFF   16 KiB
```

Instruction memory is populated from the selected FPGA IMEM image and is local to the CPU fetch path.

### 7.2 Data Memory

The canonical data-memory region is:

```text
0x1000_0000 - 0x1000_7FFF   32 KiB
```

The DMEM subsystem uses FPGA block RAM and supports byte write enables. The implementation includes handling for a store-to-load BRAM hazard by merging bypassed store bytes with BRAM read data where required.

The canonical 32 KiB region above is the software-visible architectural memory region. Any response caused by broader RTL decode outside this range is an **implementation alias and shall not be treated as a supported architectural address**.

Detailed BRAM timing and hazard semantics are specified in `memory_subsystem.md`.

### 7.3 VGA Framebuffer Memory

The VGA subsystem owns two framebuffer memories and exposes the current CPU-visible **back buffer** through the AHB VRAM window.

The framebuffer format is:

- Resolution: 640 x 480 visible pixels.
- Pixel depth: 1 bit per pixel.
- CPU write granularity: 32-bit word.
- One frame: 307,200 bits = 38,400 bytes = 9,600 32-bit words.
- Two physical framebuffers are used for front/back-buffer operation.

Display-control registers are implemented in the same AHB target as the framebuffer window.

Detailed display behavior is defined in `vga.md`.

## 8. APB Peripheral Architecture

The bridge decodes eight canonical 64 KiB APB slots:

| PSEL | Canonical region | Peripheral | External role |
|---:|---|---|---|
| 0 | `0x4000_0000 - 0x4000_FFFF` | UART0 | LoRa UART + AUX status |
| 1 | `0x4001_0000 - 0x4001_FFFF` | GPIO | DE10-Lite switches / LEDs |
| 2 | `0x4002_0000 - 0x4002_FFFF` | TIMER | Polling timer |
| 3 | `0x4003_0000 - 0x4003_FFFF` | GSENSOR | ADXL345 accelerometer subsystem |
| 4 | `0x4004_0000 - 0x4004_FFFF` | AES-GCM | Cryptographic accelerator |
| 5 | `0x4005_0000 - 0x4005_FFFF` | JOYSTICK | MAX 10 ADC joystick controller |
| 6 | `0x4006_0000 - 0x4006_FFFF` | UART1 | PC/debug UART |
| 7 | `0x4007_0000 - 0x4007_FFFF` | HEX | Six-digit seven-segment display |

These are the only canonical APB peripheral slots in the baseline.

A broad implementation decode may cause address mirroring outside the canonical regions. Firmware and verification shall not rely on such aliases unless a future specification explicitly promotes them.

Peripheral register maps and behavior are specified in the individual peripheral documents and summarized in `memory_map.md`.

## 9. Display Architecture

The active FPGA display path is **not an APB VGA peripheral**.

The active path is:

```text
CPU
  |
  | AHB
  v
AHB_VRAM_DUAL_BUFFER
  |-- VRAM0
  |-- VRAM1
  |-- HW_Cleaner
  |-- VGA prefetch/read path
  |-- VGA timing generator
  +--> VGA_R / VGA_G / VGA_B / VGA_HS / VGA_VS
```

The display subsystem generates a 25 MHz pixel clock from the board 50 MHz clock and implements 640x480 VGA timing.

Front/back buffer roles are switched by a software-triggered swap command. A hardware clear engine can clear the current back buffer without CPU word-by-word writes.

A VSync event is synchronized into the HCLK domain and exposed through a status flag for software synchronization.

The source file `rtl/video/vga/APB_VGA_Top.v` exists in the Quartus source set but is **not the instantiated display path in `AMBA_SoC_TOP`**. Its presence in the project source list shall not be interpreted as an active architectural block.

## 10. UART Architecture

Two UART peripherals share a common software-visible register structure:

- UART0 at `0x4000_0000`: LoRa communication.
- UART1 at `0x4006_0000`: PC/debug communication.

Both UARTs provide:

- 8-bit transmit data.
- Receive path.
- 16-byte receive FIFO.
- Programmable baud divisor.
- TX-ready / RX-ready / RX-error status.

UART0 additionally exposes synchronized LoRa AUX status.

The current UART control register is storage for future control/interrupt functionality; no architectural interrupt generation is implemented in the baseline.

Detailed behavior is specified in `uart.md`.

## 11. Timer Architecture

The APB timer is a software-polled counter/compare peripheral.

It provides:

- Enable control.
- 32-bit counter.
- 32-bit compare value.
- Sticky READY/completion status.
- Software clear of READY.

The timer does **not** generate an interrupt in the active FPGA baseline.

Detailed cycle behavior is specified in `timer.md`.

## 12. GPIO Architecture

The GPIO block provides ten software-visible GPIO bits corresponding to DE10-Lite board I/O.

Each bit has:

- Output-data storage.
- Direction control.
- Readback that returns output data for output-configured bits and physical input data for input-configured bits.

Detailed behavior is specified in `gpio.md`.

## 13. Accelerometer and SPI Architecture

The ADXL345 accelerometer is exposed to software through the APB `GSENSOR` block.

The SPI controller used for the accelerometer is **internal to the G-sensor subsystem**. It is not a generic CPU-visible SPI controller and has no independent MMIO base address.

The G-sensor subsystem owns:

- Sensor reset/startup sequencing.
- Locally generated SPI clocks.
- ADXL345 initialization.
- Periodic/multi-byte sensor reads.
- Software-visible X/Y/Z sample registers.

`gsensor.md` defines the APB-visible accelerometer contract. `spi.md` defines the internal SPI engine contract and its relationship to the accelerometer subsystem.

## 14. AES-GCM Architecture

The AES-GCM peripheral is an APB wrapper around the integrated AES-GCM core.

The wrapper provides software-visible key, nonce/direction, sequence, length, payload, authentication-tag, control, and status registers and converts software commands into the internal accelerator handshake sequence.

The current baseline is designed around a 128-bit payload block transaction interface at the APB wrapper boundary, with AES-128-GCM software usage implemented by the current firmware stack.

Detailed register ordering, IV/AAD construction, start/done behavior, encryption/decryption mode, and tag validation are specified in `aes_gcm.md`.

## 15. ADC Joystick Architecture

The joystick block connects the APB subsystem to the MAX 10 ADC/Qsys interface.

It provides:

- Alternating X/Y ADC channel commands.
- Captured 12-bit raw samples.
- Configurable channel numbers.
- Configurable center values.
- Configurable deadzone.
- Derived forward/backward/left/right status.
- Sample/response diagnostic information.

Detailed behavior is specified in `adc_joystick.md`.

## 16. Seven-Segment Display Architecture

The HEX peripheral controls six DE10-Lite seven-segment displays.

It supports:

- Six hexadecimal nibbles through a packed value register.
- Decode mode.
- Raw segment mode.
- Display enable.
- Active-low segment drive.

Detailed behavior is specified in `hex_display.md`.

## 17. Reset Architecture

The external board reset source is `KEY[0]`, treated as an active-low reset request.

The top level performs reset conditioning before releasing the system:

1. Asynchronous assertion from the push button.
2. Two-flop synchronization into the system clock domain.
3. Approximately 20 ms release qualification at 50 MHz.
4. Generation of the internal active-low system reset (`HRESETn` / APB `PRESETn`).

Individual sub-blocks may convert polarity internally or implement additional local reset sequencing.

Detailed reset-domain and release behavior is specified in `reset_clock.md`.

## 18. Clock Architecture

The baseline clock structure includes:

| Clock | Nominal frequency | Primary consumers |
|---|---:|---|
| Board `clk` / HCLK | 50 MHz | CPU, AHB, top-level system logic |
| PCLK | 50 MHz | APB bridge and APB peripherals |
| VGA pixel clock | 25 MHz | VGA timing and framebuffer read path |
| G-sensor SPI clocks | 2 MHz-class generated clocks | ADXL345 SPI engine |
| ADC/Qsys clocks | Vendor-IP generated/managed | MAX 10 ADC subsystem |

The current timing constraint set explicitly constrains the external 50 MHz input clock. Complete generated-clock/CDC constraint coverage is not claimed by the migration baseline and requires dedicated timing review.

Detailed clock generation, reset interaction, and CDC requirements are specified in `reset_clock.md`.

## 19. Interrupt and Trap Architecture

### 19.1 External Interrupts

The active baseline has **no architectural external interrupt support**.

Specifically:

- No PLIC is instantiated in `AMBA_SoC_TOP`.
- No external interrupt request input is connected to the active CPU top.
- UART peripherals do not generate CPU interrupts.
- The timer does not generate a CPU interrupt.
- The baseline firmware uses polling for these peripherals.

The PLIC implementation preserved under `verification/legacy/plic_snapshot/` is development/reference material only. It is excluded from the active FPGA synthesis path and shall not be treated as baseline functionality.

### 19.2 Synchronous Trap Support

The CPU contains synchronous trap/exception handling logic and machine CSR support for the implemented trap path. The current baseline includes handling associated with ECALL, EBREAK, misaligned access/instruction cases, trap-vector redirection, and MRET-related return behavior.

This synchronous trap mechanism is architecturally distinct from the not-yet-integrated external interrupt architecture.

Detailed current trap behavior and the boundary for future PLIC integration are specified in `interrupt_architecture.md`.

## 20. Firmware Architecture Contract

The baseline firmware is bare-metal RISC-V software.

The firmware contract includes:

- Code execution from IMEM.
- Data, constants, BSS, and stack in DMEM according to the linker script.
- Memory-mapped peripheral access through volatile loads/stores.
- Polling-based UART and timer operation.
- VGA framebuffer and display-control access through the AHB VRAM window.
- Register-level drivers for current APB peripherals.

Peripheral MMIO is architecturally specified by each peripheral document. Unless a peripheral specification explicitly permits narrower accesses, software should use naturally aligned 32-bit register accesses for control/status registers.

The complete software/hardware boundary is specified in `firmware_contract.md`.

## 21. Address-Space Policy

The architectural address map is the set of canonical regions defined by `memory_map.md`.

The current RTL contains some coarse top-level decode expressions that can create mirrored/aliased behavior outside canonical regions. Such behavior is classified as an **implementation quirk**, not a supported software contract.

Therefore:

- Firmware shall use canonical addresses only.
- Verification shall verify canonical regions first and may separately test alias behavior as an implementation observation.
- Future RTL cleanup may tighten decode logic without being considered an architectural compatibility break, provided canonical regions are unchanged.
- No new software shall intentionally depend on undocumented aliases.

## 22. Error-Response Policy

The current baseline does not implement a comprehensive bus-fault/error-response architecture.

At top level, unmapped or unselected accesses can return zero data with ready/OKAY-style completion rather than generating a processor-visible bus fault. Individual current slaves also generally return successful bus responses.

This behavior is part of the observed baseline but shall not be interpreted as a requirement that future interconnect revisions can never add explicit error handling. Any such change requires an updated bus and CPU-interface specification.

## 23. Active, Dormant, and Legacy Source Classification

A source file being present in the repository or listed in the Quartus project does not by itself make that block architecturally active.

### 23.1 Active baseline

Architecturally active blocks are those reachable from `AMBA_SoC_TOP` in the active synthesis hierarchy, including the CPU, bus interfaces, DMEM, AHB VRAM/VGA subsystem, APB bridge, and the eight APB slots described above.

### 23.2 Dormant/non-instantiated source

Some synthesizable source files are retained in the Quartus source set but are not instantiated by the active SoC top. These are implementation collateral/reference sources, not additional active peripherals. `APB_VGA_Top.v` is a known example.

### 23.3 Legacy development snapshots

`verification/legacy/plic_snapshot/` contains a frozen PLIC development snapshot and candidate CPU/timer integration changes. It is excluded from the active FPGA source list and is not part of this baseline architecture.

## 24. Baseline Verification Status

Architecture presence and verification evidence shall be treated as separate properties.

The imported baseline has reproduced a successful Quartus full compile and preserved historical FPGA results. The currently selected `display_smoke` firmware image has developer-confirmed physical-board operation for VGA, HEX, and LED diagnostic behavior.

This evidence does **not** imply that every integrated peripheral was revalidated by `display_smoke`. In particular, the current diagnostic does not independently establish end-to-end LoRa operation, ADC behavior, VGA hardware-clear behavior, external interrupt/PLIC functionality, or full timing-constraint completeness.

Each subordinate specification should record its own implementation and verification status where useful.

## 25. Baseline Exclusions

The following features are outside the current baseline contract:

- PLIC integration.
- External CPU interrupt entry.
- Interrupt-driven timer/UART firmware.
- AXI interconnect.
- Multi-master bus arbitration.
- DMA.
- Data cache.
- Instruction cache.
- External SDRAM controller.
- Cache coherency.
- Generic CPU-visible SPI controller separate from the G-sensor subsystem.

These may be introduced only through future specifications and implementation milestones.

## 26. Required Subordinate Specifications

This architecture document is intentionally decomposed into lower-level contracts:

```text
spec/
├─ soc_architecture.md          # this document
├─ memory_map.md
├─ memory_subsystem.md
├─ cpu_interface.md
├─ ahb_fabric.md
├─ apb_subsystem.md
├─ interrupt_architecture.md
├─ reset_clock.md
├─ vga.md
├─ uart.md
├─ timer.md
├─ gpio.md
├─ gsensor.md
├─ spi.md
├─ aes_gcm.md
├─ adc_joystick.md
├─ hex_display.md
└─ firmware_contract.md
```

If a lower-level specification conflicts with this document, the conflict shall be resolved explicitly rather than silently inferred. The architecture owner shall decide which document is updated.

## 27. Known Baseline Implementation Quirks Requiring Preservation or Review

The following observations shall remain visible during subsequent specification work:

1. **DMEM coarse decode:** top-level selection is broader than the canonical 32 KiB DMEM region, while the physical BRAM addressing implements the 32 KiB memory. Non-canonical mirroring is not architectural.
2. **VRAM coarse decode:** top-level VRAM selection is broader than the canonical framebuffer/control window. Non-canonical mirroring is not architectural.
3. **APB coarse decode:** the top/bridge decode can create mirrored peripheral selections outside the canonical eight slots. Only the canonical regions are supported.
4. **No bus error architecture:** unmapped accesses are not guaranteed to trap.
5. **Dormant VGA source:** `APB_VGA_Top.v` is present in project sources but is not the active display instance.
6. **SPI visibility:** the accelerometer SPI controller is private to the G-sensor subsystem, not an independent MMIO peripheral.
7. **External interrupts absent:** the preserved PLIC snapshot is not integrated baseline functionality.
8. **Timing constraints incomplete as an architectural proof:** the preserved 50 MHz timing result does not by itself establish full generated-clock and CDC constraint completeness.

These items should be resolved or intentionally preserved in the relevant subordinate specification rather than hidden by documentation cleanup.

## 28. Baseline Architecture Invariants

Unless explicitly revised by an approved future specification, the following are baseline invariants:

- CPU software address width is 32 bits.
- CPU is the only system data-bus master.
- IMEM is local to the CPU fetch path.
- Canonical DMEM is 32 KiB at `0x1000_0000`.
- VGA/VRAM is an AHB-side subsystem, not an APB slot.
- APB contains eight canonical peripheral slots from `0x4000_0000` through `0x4007_FFFF`.
- UART0 is the LoRa-facing UART; UART1 is the PC-facing UART.
- The G-sensor SPI engine is internal to the G-sensor subsystem.
- VGA visible resolution is 640x480 at 1 bit per pixel in the framebuffer.
- Front/back framebuffer operation uses two physical VRAM buffers.
- The baseline has no integrated PLIC or external CPU interrupt path.
- System HCLK/PCLK nominal frequency is 50 MHz.
- External reset originates from active-low `KEY[0]` and is conditioned before internal release.

---

**Next-level contracts:** `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`, `ahb_fabric.md`, `apb_subsystem.md`, and the peripheral specifications listed above.
