# Baseline SoC G-Sensor Subsystem Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `gsensor.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

> **Implementation note (Phase 4A-GSENSOR, 2026-09-14):** Sections describing `spi_pll`, `spi_clk`, pre-first-sample unknown reset values, and direct `spi_clk`→PCLK readback document the historical baseline. The narrowly scoped implementation status at the end of this file supersedes those clocking/reset descriptions for the current public candidate; the APB software contract and remaining VALID/SEQ limitations still apply.

## 1. Purpose

This document defines the active DE10-Lite accelerometer / G-sensor subsystem in the FPGA baseline. It specifies:

- the APB-visible register contract,
- the fixed-function ADXL345 initialization sequence,
- the private SPI acquisition path,
- the software-visible X/Y/Z packing,
- acquisition trigger and refresh behavior,
- reset/startup behavior,
- the relationship of the board interrupt pins to the local sensor controller,
- current CDC and sample-coherency limitations,
- known data-reconstruction uncertainties,
- verification requirements,
- baseline cleanup items required before major future integration.

The active subsystem is **not a generic software-programmable SPI controller**. Software reads accelerometer samples through two APB registers while dedicated hardware owns sensor initialization and SPI traffic.

## 2. Active RTL Boundary

The active APB wrapper is:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
```

with private submodules:

```text
rtl/peripherals/gsensor/v/reset_delay.v
rtl/peripherals/gsensor/v/adxl345_controller.v
rtl/peripherals/gsensor/v/SPI_MASTER.v
rtl/peripherals/gsensor/v/spi_param.h
private vendor-project vault: spi_pll generated IP (not in public tree)
```

Top-level integration is:

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +--> PSEL[3]
       |
       v
 APB_GSENSOR_MB                       PCLK domain, 50 MHz
       |
       +--> reset_delay
       |
       +--> spi_pll
       |      +--> spi_clk            2 MHz
       |      +--> spi_clk_out        2 MHz, phase shifted
       |
       +--> spi_ee_config             fixed-function ADXL345 controller
                  |
                  +--> spi_controller
                  |
                  +--> GSENSOR_CS_N
                  +--> GSENSOR_SCLK
                  +--> GSENSOR_SDI
                  +<-- GSENSOR_SDO
                  +<-- GSENSOR_INT[1]
```

Canonical base address:

```text
GSENSOR_BASE = 0x4003_0000
APB slot     = PSEL[3]
```

The APB wrapper permanently asserts:

```text
PREADY = 1
```

and has no CPU interrupt output in the active baseline.

## 3. Canonical APB Register Map

The wrapper implements two software-visible read registers:

| Offset | Register | Access | Data |
|---:|---|---|---|
| `0x00` | `GSENSOR_XY_DATA` | R | `[31:16] = X`, `[15:0] = Y` |
| `0x04` | `GSENSOR_Z_DATA` | R | `[31:16] = 0`, `[15:0] = Z` |

Offsets `0x08` and `0x0C` return zero in the current local decode.

The wrapper has no software-visible control, status, ready, error, configuration, timestamp, or sample-counter register.

### 3.1 Write behavior

The wrapper does not implement APB writes. `PWDATA` is unused by the sensor function.

A write into the selected G-sensor APB slot still completes because `PREADY=1`, but it changes no G-sensor state and raises no error.

Software shall treat the canonical G-sensor register bank as **read-only**.

### 3.2 Register mirroring

The local wrapper decodes only:

```text
PADDR[3:2]
```

Therefore the local four-word decode repeats every 16 bytes within the broader APB slot. These physical mirrors are implementation artifacts and are not architectural addresses.

Only naturally aligned 32-bit accesses to the canonical offsets are normative, consistent with `apb_subsystem.md`.

## 4. Software-Visible Sample Format

The APB wrapper exposes the controller's three 16-bit sample registers directly.

```text
GSENSOR_XY_DATA @ +0x00
31                    16 15                     0
+-----------------------+-----------------------+
|        X[15:0]        |        Y[15:0]        |
+-----------------------+-----------------------+

GSENSOR_Z_DATA @ +0x04
31                    16 15                     0
+-----------------------+-----------------------+
|          0            |        Z[15:0]        |
+-----------------------+-----------------------+
```

The local RTL comments treat X/Y/Z as signed 16-bit two's-complement values. Software that interprets the raw values shall sign-extend each 16-bit field before signed arithmetic.

This baseline specification does **not** define a stable physical-unit conversion such as mg/LSB as a firmware contract. That conversion shall be tied to a verified ADXL345 configuration/datasheet contract before being made normative.

## 5. Fixed Hardware Initialization

After local reset release, `spi_ee_config` performs 11 fixed ADXL345 register writes. The initialization table implemented in RTL is:

| Index | ADXL register | Address | Written value | Baseline note |
|---:|---|---:|---:|---|
| 0 | `THRESH_ACT` | `0x24` | `0x20` | fixed hardware configuration |
| 1 | `THRESH_INACT` | `0x25` | `0x03` | fixed hardware configuration |
| 2 | `TIME_INACT` | `0x26` | `0x01` | fixed hardware configuration |
| 3 | `ACT_INACT_CTL` | `0x27` | `0x7F` | fixed hardware configuration |
| 4 | `THRESH_FF` | `0x28` | `0x09` | fixed hardware configuration |
| 5 | `TIME_FF` | `0x29` | `0x46` | fixed hardware configuration |
| 6 | `BW_RATE` | `0x2C` | `0x09` | RTL comment identifies 50 Hz output-data rate |
| 7 | `INT_ENABLE` | `0x2E` | `0x00` | sensor interrupt sources disabled by this initialization |
| 8 | `INT_MAP` | `0x2F` | `0x00` | fixed mapping value |
| 9 | `DATA_FORMAT` | `0x31` | `0x00` | fixed format value |
| 10 | `POWER_CONTROL` | `0x2D` | `0x08` | measurement-mode start value |

Software cannot change these values through the current APB wrapper.

The initialization sequence uses 16-bit SPI write transactions generated entirely by hardware.

## 6. Acquisition Trigger and Read Cycle

After the 11 initialization writes complete, the controller enters a repeated acquisition loop.

A new sensor burst read begins when either:

```text
GSENSOR_INT[1] is observed high
```

or the local periodic fallback counter reaches its trigger bit.

The source input is named `iG_INT2` inside `spi_ee_config`, but the wrapper connects it to `GSENSOR_INT[1]`. This naming/mapping inconsistency is an implementation quirk; the name `iG_INT2` shall not be treated as proof that the physical ADXL345 INT2 pin is the active source.

### 6.1 Periodic fallback timing

The active parameters are:

```text
IDLE_MSB = 14
read_idle_count[14:0]
trigger condition = read_idle_count[14]
spi_clk = 2 MHz nominal
```

Starting from zero, bit 14 becomes high after 16,384 `spi_clk` increments.

Therefore the nominal fallback interval is approximately:

```text
16,384 / 2,000,000
= 8.192 ms
```

before transfer overhead.

An RTL comment describes this as approximately 16.384 ms and refers to bit 15, but the active parameter and trigger are bit 14. The **implemented value is approximately 8.192 ms**, and the stale comment is non-authoritative.

Because `BW_RATE` is initialized to `0x09` and the RTL labels that setting as 50 Hz, the private SPI controller can poll faster than the sensor's nominal output-data update interval. Re-reading an unchanged sensor sample is therefore possible and is not an APB error.

### 6.2 Burst-read command

The read path constructs:

```text
{2'b11, X_LB}
```

where `X_LB = 0x32`, producing the ADXL345 multi-byte read command beginning at `DATAX0`.

The private SPI controller then performs a 56-bit transaction consisting of the command/address phase followed by six returned data bytes.

The CPU does not initiate or schedule these SPI transactions directly.

## 7. Private SPI Interface

The G-sensor uses a dedicated four-wire SPI-style interface:

```text
GSENSOR_CS_N  chip select, active low
GSENSOR_SCLK  serial clock
GSENSOR_SDI   FPGA -> sensor data
GSENSOR_SDO   sensor -> FPGA data
```

The generated `spi_pll` produces two nominal 2 MHz clocks from the 50 MHz input. In the generated baseline IP, the configured phase shifts are different for `c0` and `c1`; `spi_clk` is used by the internal state/sampling logic and `spi_clk_out` drives the gated external serial clock.

The SPI engine supports the transactions needed by this accelerometer controller:

- 16-bit initialization writes,
- 56-bit multi-byte reads.

It is not exposed as a generic APB SPI master. `spi.md` documents the private implementation boundary separately; software shall not assume a generic SPI programming model exists.

## 8. Reset and Startup Sequencing

The APB wrapper receives the system `PRESETn` and adds a local delay using `reset_delay`.

`reset_delay` holds `dly_rst=1` until bit 20 of a 21-bit PCLK counter becomes set. Relative to `PRESETn` release, the local delay is:

```text
2^20 PCLK cycles
= 1,048,576 cycles
= 20.97152 ms at 50 MHz
```

During the delay:

```text
spi_pll areset = 1
spi_ee_config iRSTN = 0
```

When the delay expires, PLL reset and controller reset are released together.

The baseline does not use the PLL `locked` output and therefore does not explicitly wait for PLL lock before allowing the controller to begin operation.

### 8.1 Sample-register reset limitation

`out_acc_x`, `out_acc_y`, and `out_acc_z` are not explicitly assigned in the reset branch of `spi_ee_config`.

Therefore an APB read before the first completed sensor burst does not have a defined architectural sample value. In simulation the values may be unknown; in hardware software shall not interpret pre-first-sample data as valid sensor data.

The current APB interface exposes no status bit that lets software determine when the first valid sample has arrived.

## 9. Internal `gsensor_ready` Signal

`spi_ee_config` contains a `gsensor_ready` output. It is asserted for the internal SPI-clock-domain completion of a successful read transaction.

However, `APB_GSENSOR_MB` does not connect this output to a wrapper signal or APB status register.

Consequently the active software contract has:

```text
sample_ready     = not exposed
sample_valid     = not exposed
sample_sequence  = not exposed
sample_timestamp = not exposed
```

Future cleanup should reuse or replace this completion indication as part of a proper PCLK-domain snapshot/valid handshake.

## 10. Clock-Domain Crossing and Sample Coherency

This is a known baseline correctness limitation.

The source sample registers:

```text
out_acc_x
out_acc_y
out_acc_z
```

are updated in the 2 MHz `spi_clk` domain.

The APB wrapper reads those multi-bit buses directly from the 50 MHz `PCLK` domain using combinational logic. There is no:

- multi-bit CDC handshake,
- destination-domain snapshot register,
- asynchronous FIFO,
- sample-version handshake,
- atomic X/Y/Z capture mechanism.

Therefore a sample update close to an APB read can theoretically produce metastability or a torn multi-bit value.

In addition, X/Y are returned in one APB word while Z requires a second APB transaction. Even after the CDC mechanism is corrected, an explicit snapshot mechanism is required if software must guarantee that X, Y, and Z came from the same acquisition event.

This issue is already part of the system-level CDC cleanup identified in `reset_clock.md` and is normative here for the G-sensor block.

## 11. Current Data-Reconstruction Logic

At the end of a 56-bit burst, the controller reconstructs samples with the following active bit selections:

```text
X = {s2p_data[38:31], s2p_data[46:39]}
Y = {s2p_data[22:15], s2p_data[30:23]}
Z = {s2p_data[6:0], 1'b0, s2p_data[14:7]}
```

X and Y use two complete eight-bit fields. Z is reconstructed asymmetrically: seven captured bits, one inserted zero bit, and one eight-bit field.

The RTL itself contains a comment stating that the receive-shift indexing requires confirmation. Therefore the current Z reconstruction, and the complete byte/bit ordering of the 56-bit read path, shall be treated as **implementation behavior requiring directed verification**, not as a proven ideal ADXL345 byte mapping.

Software shall not compensate for this possible RTL issue by inventing a different software bit mapping. The RTL shall be verified and corrected during baseline cleanup if required.

## 12. Interrupt Architecture Relationship

The G-sensor subsystem has no interrupt connection to the CPU or PLIC in the active baseline.

The board sensor interrupt input is consumed only by the private acquisition controller as an optional local trigger.

Furthermore, the active initialization writes:

```text
INT_ENABLE = 0x00
```

so the configured sensor interrupt sources are disabled by the initialization table. The periodic fallback counter is therefore the dependable acquisition trigger in the reconstructed baseline.

Any future CPU-visible G-sensor interrupt requires a new contract covering:

- sensor event source,
- physical INT pin selection,
- synchronizer/CDC behavior,
- level versus edge semantics,
- masking/enable policy,
- PLIC source ID,
- clear/acknowledge behavior,
- relationship to sample-ready state.

## 13. APB Timing

The wrapper is a zero-wait APB slave:

```text
PREADY = 1
```

`PRDATA` is combinational during a selected APB ACCESS read.

The G-sensor block does not stall the APB bus while SPI traffic is active. Software reads simply observe whichever sample-register values are currently visible.

This means APB completion is **not** evidence that a new sensor acquisition has completed.

## 14. Firmware Contract

Until baseline cleanup changes this interface, firmware shall:

1. use only aligned 32-bit reads at `GSENSOR_BASE + 0x00` and `+0x04`,
2. treat the registers as read-only,
3. sign-extend each 16-bit axis value when signed data is required,
4. not assume a read returns a newly acquired sample,
5. not assume X/Y and Z form an atomic three-axis snapshot,
6. not use pre-first-sample values as valid measurements,
7. not depend on APB writes to configure the sensor,
8. not treat the board sensor interrupt pin as a CPU interrupt,
9. not use register aliases outside the canonical offsets.

There is currently no dedicated production firmware driver exposing a stronger G-sensor validity or snapshot contract.

## 15. Verification Requirements

Baseline-directed verification should cover at minimum:

- APB reads of canonical `+0x00` and `+0x04`,
- canonical bit packing at the wrapper boundary,
- writes causing no software-visible configuration change,
- `PREADY=1` behavior,
- reset-delay duration,
- all 11 initialization SPI writes and their order,
- transition from initialization into repeated read mode,
- periodic fallback trigger interval,
- 56-bit burst command and transfer length,
- known-pattern SPI return data for X/Y/Z byte-order validation,
- the asymmetric Z reconstruction case,
- first-sample validity behavior,
- sample update while APB reads are occurring,
- sensor interrupt input behavior versus periodic fallback,
- absence of CPU/PLIC interrupt behavior.

Board-level acceptance should separately verify that known physical orientations/motions produce plausible X/Y/Z polarity and magnitude. A successful Quartus build alone is not sensor-function evidence.

## 16. Baseline Cleanup Targets Before Major Feature Integration

The following items shall be carried into the consolidated baseline cleanup list:

| Priority | Cleanup target | Required direction |
|---|---|---|
| High | Unsafe multi-bit `spi_clk -> PCLK` crossing | Add a proper sample-transfer handshake, snapshot register, or equivalent CDC-safe structure. |
| High | No software-visible sample-valid/ready state | Expose a synchronized valid/ready or sequence mechanism; define first-sample validity. |
| High | Unverified X/Y/Z bit reconstruction | Run known-pattern directed tests; correct byte/bit extraction, especially asymmetric Z logic, if required. |
| High | No atomic three-axis snapshot | Define a coherent XYZ snapshot contract. |
| High | PLL lock ignored | Define generated-clock/reset release policy and wait for lock if required. |
| Medium | Stale 16.384 ms RTL comment | Correct documentation to the active bit-14 / ~8.192 ms fallback behavior or redesign the rate generator. |
| Medium | Sensor ODR versus polling-rate mismatch | Define acquisition policy around the intended 50 Hz sensor update rate and avoid unnecessary duplicate reads if appropriate. |
| Medium | Interrupt-pin naming/mapping ambiguity | Resolve `GSENSOR_INT[1]` versus internal `iG_INT2` naming and verify the physical pin contract. |
| Medium | `INT_ENABLE=0x00` despite interrupt-trigger path | Decide whether acquisition is timer-driven, data-ready-driven, or hybrid and configure the ADXL345 consistently. |
| Medium | Sample registers not reset | Define deterministic reset/invalid values or gate visibility with VALID. |
| Medium | No software configuration interface | Decide whether fixed hardware initialization remains intentional or whether controlled configuration registers are required. |
| Low | Local register mirrors | Tighten local offset decode or explicitly contain the alias behavior. |
| Low | Unused APB write inputs / debug-only outputs | Clean interface naming and remove or formalize debug-only signals. |

## 17. Baseline Invariants

Until a later approved specification changes the architecture:

1. The G-sensor is APB slot 3 at canonical base `0x4003_0000`.
2. Software-visible G-sensor access is read-only.
3. `+0x00` returns X in `[31:16]` and Y in `[15:0]`.
4. `+0x04` returns Z in `[15:0]` with the upper halfword zero.
5. The sensor is initialized by dedicated hardware, not firmware SPI transactions.
6. The private SPI interface is not a generic software-visible APB SPI controller.
7. The current sensor controller uses nominal 2 MHz generated clocks.
8. The fallback read trigger is based on active `read_idle_count[14]`, approximately 8.192 ms before transfer overhead.
9. The APB wrapper exposes no valid/ready/timestamp/sequence status.
10. The active CPU has no G-sensor interrupt source.
11. Direct multi-bit `spi_clk -> PCLK` sample crossing remains a known cleanup item.
12. The current sample reconstruction shall not be silently rewritten in documentation; any correction requires RTL verification and an updated specification.

## Phase 4A-GSENSOR A6 Implementation Status

A6 is implemented in the current public candidate: the fixed-function ADXL345 FSM and X/Y/Z result registers use only 50 MHz PCLK, with registered mode-3 external SCLK and 12/13-PCLK half-periods (25 PCLKs per 2 MHz SCLK cycle). The historical dual-phase `spi_pll` remains in the private vault but has no active wrapper instance or Quartus binding. `GSENSOR_INT[1]` enters a two-flop PCLK synchronizer. The eleven initialization writes, 56-bit read, APB register packing and `PREADY=1` contract are retained. Sample registers reset to zero and publish X/Y/Z together after a completed read, but zero is **not** a software-visible VALID indication.

Focused/open tests pass, and the user-run `gsensor_pclk_01` Quartus fit has two active PLLs (ADC/VGA), no G-sensor generated clock, and positive 50 MHz setup/hold slack at the analyzed corners. This verifies the internal single-PCLK clocking sub-scope, **not** ADXL345 board-pin setup/hold, a VALID/SEQ API, atomicity across two separate APB reads, physical interrupt mapping, `GS-001`/`CDC-002` closure, or board acceptance. Detailed raw build evidence and the Phase 4A-GSENSOR report remain in the private local evidence archive.
