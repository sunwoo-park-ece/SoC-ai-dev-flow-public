# Baseline SoC G-Sensor Subsystem Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `gsensor.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

> **Current A6 clocking:** The active G-sensor RTL has no `spi_pll` instance or internal SPI clock domain. Controller, sample registers, and APB wrapper use 50 MHz PCLK; external mode-3 SCLK is a registered output. Historical PLL/CDC descriptions below are identified as such; they are not current defects. Separate APB reads still lack an atomic XYZ snapshot and software-visible VALID/SEQ.

> **P09B Public integration status:** The Public P09B implementation provides the final-section LIVE/HOLD/VALID/SEQ ABI, 12 initialization writes, INT1/30 ms scheduler and direct shared reset. Focused/CPU/host evidence, a fresh private fit/STA and one board display observation exist; external timing/electrical, physical INT1/orientation, calibration and the explicitly retained NOT_RUN cases remain open.

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

with active project-owned submodules:

```text
rtl/peripherals/gsensor/reset_delay.v
rtl/peripherals/gsensor/spi_ee_config.v
```

The old `adxl345_controller.v`, `SPI_MASTER.v`, `spi_param.h`, and private-vault `spi_pll` belong to the historical reference implementation, not the active public G-sensor source or FPGA binding.

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
       +--> spi_ee_config             fixed-function ADXL345 controller, PCLK
                  |
                  +--> GSENSOR_CS_N
                  +--> GSENSOR_SCLK   registered mode-3 output, ~2 MHz
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
poll_div_count = 25 PCLKs per increment of poll_count (historical 11-write acquisition policy)
```

Starting from zero, bit 14 becomes high after 16,384 `poll_count` increments.

Therefore the nominal fallback interval is approximately:

```text
16,384 × 25 / 50,000,000
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

The active controller and sample registers use only 50 MHz PCLK. A registered mode-3 `GSENSOR_SCLK` output uses 12/13-PCLK half-periods (25 PCLKs per nominal 2 MHz serial cycle); it is not an internal clock. The former dual-phase `spi_pll` implementation is historical and has no active G-sensor wrapper instance or Quartus binding.

The SPI engine supports the transactions needed by this accelerometer controller:

- 16-bit initialization writes,
- 56-bit multi-byte reads.

It is not exposed as a generic APB SPI master. `spi.md` documents the private implementation boundary separately; software shall not assume a generic SPI programming model exists.

## 8. Reset and Startup Sequencing

The APB wrapper receives the system `PRESETn` and adds a local delay using `reset_delay`.

The pinned `reset_delay` has a 20-bit PCLK counter and keeps `dly_rst=1` until the counter reaches all ones; it deasserts on the following PCLK edge. Relative to `PRESETn` release, the local delay is:

```text
2^20 PCLK cycles
= 1,048,576 cycles
= 20.97152 ms at 50 MHz
```

During the delay:

```text
spi_ee_config iRSTN = 0
```

When the delay expires, the controller reset is released. There is no G-sensor PLL reset or `locked` signal in the active path.

### 8.1 Sample-register reset limitation

`out_acc_x`, `out_acc_y`, and `out_acc_z` are explicitly reset to zero in the active `spi_ee_config`.

Therefore an APB read before the first completed sensor burst returns deterministic zero, but software shall not interpret it as a valid sensor sample.

The current APB interface exposes no status bit that lets software determine when the first valid sample has arrived.

## 9. Internal `gsensor_ready` Signal

`spi_ee_config` contains a registered `gsensor_ready` output asserted on completion of a full read transaction in the PCLK domain.

However, `APB_GSENSOR_MB` does not connect this output to a wrapper signal or APB status register.

Consequently the active software contract has:

```text
sample_ready     = not exposed
sample_valid     = not exposed
sample_sequence  = not exposed
sample_timestamp = not exposed
```

P09B proposes to consume this PCLK-domain completion one edge later for a coherent LIVE publication and software-visible snapshot/valid contract.

## 10. Sample Coherency (no active internal SPI-to-PCLK CDC)

The historical multi-bit `spi_clk`→PCLK crossing was removed by A6. The remaining limitation is a software-visible snapshot boundary, not an active internal CDC path.

The source sample registers:

```text
out_acc_x
out_acc_y
out_acc_z
```

are updated together in the 50 MHz PCLK domain after a completed burst.

The APB wrapper reads those buses with combinational readback. There is no:

- destination-domain snapshot register,
- sample-version handshake,
- atomic X/Y/Z capture mechanism.

There is no internal multi-bit metastability claim from an SPI-to-PCLK crossing. A read at an update boundary and two separate APB word reads still lack a specified coherent CPU snapshot.

X/Y are returned in one APB word while Z requires a second APB transaction; LIVE may refresh between them. An explicit HOLD snapshot is required if software must guarantee one acquisition generation.

This is the `GS-001`/`CDC-002` software-coherency cleanup scope; the old generated-clock CDC mechanism itself is not present in active RTL.

## 11. Current Data-Reconstruction Logic

At the end of a full 56-bit burst, the active A6 controller registers the completed six data bytes with these bit selections:

```text
X = {completed_rx[39:32], completed_rx[47:40]}
Y = {completed_rx[23:16], completed_rx[31:24]}
Z = {completed_rx[7:0], completed_rx[15:8]}
```

All three axes use complete low/high byte pairs, with ADXL345 low bytes received first. The project-owned `spi_ee_config.v` registers XYZ together at completion. Existing `GS-002` known-pattern digital evidence used `X=0x1234, Y=0x5678, Z=0x9ABC`; this supports byte reconstruction only, not physical orientation or cross-APB-read atomicity.

**Historical pre-A6 reference only:** the old vendor-derived extraction used `Z={s2p_data[6:0],1'b0,s2p_data[14:7]}` and had an inserted zero bit. It is not the current A6 RTL or an open current Z-bit defect.

Software must still interpret each axis as signed 16-bit data; no software bit-repair mapping is needed. P09B must preserve the actual full-byte reconstruction and independently reverify it after the proposed reset/acquisition changes.

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
- full-byte signed/asymmetric known-pattern XYZ reconstruction (historical inserted-zero Z is not active),
- first-sample validity behavior,
- sample update while APB reads are occurring,
- sensor interrupt input behavior versus periodic fallback,
- absence of CPU/PLIC interrupt behavior.

Board-level acceptance should separately verify that known physical orientations/motions produce plausible X/Y/Z polarity and magnitude. A successful Quartus build alone is not sensor-function evidence.

## 16. Baseline Cleanup Targets Before Major Feature Integration

The following items shall be carried into the consolidated baseline cleanup list:

| Priority | Cleanup target | Required direction |
|---|---|---|
| Historical, resolved by A6 | Unsafe multi-bit `spi_clk -> PCLK` crossing | Removed with PCLK-only controller; retain separate LIVE/HOLD software coherency target. |
| High | No software-visible sample-valid/ready state | Expose a synchronized valid/ready or sequence mechanism; define first-sample validity. |
| Historical, GS-002 VERIFIED | X/Y/Z byte reconstruction | A6 full-byte extraction passed the scoped known-pattern digital check; preserve it in P09B regression without claiming physical accuracy. |
| High | No atomic three-axis snapshot | Define a coherent XYZ snapshot contract. |
| Historical, resolved by A6 | G-sensor PLL lock ignored | No active G-sensor PLL or generated-clock reset/lock path. |
| Medium | Stale 16.384 ms RTL comment | Correct documentation to the active bit-14 / ~8.192 ms fallback behavior or redesign the rate generator. |
| Medium | Sensor ODR versus polling-rate mismatch | Define acquisition policy around the intended 50 Hz sensor update rate and avoid unnecessary duplicate reads if appropriate. |
| Medium | Interrupt-pin naming/mapping ambiguity | Resolve `GSENSOR_INT[1]` versus internal `iG_INT2` naming and verify the physical pin contract. |
| Medium | `INT_ENABLE=0x00` despite interrupt-trigger path | Decide whether acquisition is timer-driven, data-ready-driven, or hybrid and configure the ADXL345 consistently. |
| Medium | Zero reset without validity indication | A6 resets sample registers to zero; P09B must expose VALID to distinguish pre-first-sample data. |
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
7. The current sensor controller uses only 50 MHz PCLK and generates a registered nominal 2 MHz external SCLK.
8. The fallback read trigger is based on active `read_idle_count[14]`, approximately 8.192 ms before transfer overhead.
9. The APB wrapper exposes no valid/ready/timestamp/sequence status.
10. The active CPU has no G-sensor interrupt source.
11. There is no active internal `spi_clk -> PCLK` crossing; coherent CPU readout across XY and Z remains a cleanup item.
12. The active full-byte `completed_rx` reconstruction is the current source contract; any RTL correction requires new verification and an updated specification.

## Historical A6 implementation/evidence status

At the A6 evidence point, the fixed-function ADXL345 FSM and X/Y/Z result registers used only 50 MHz PCLK, with registered mode-3 external SCLK and 12/13-PCLK half-periods (25 PCLKs per 2 MHz SCLK cycle). The historical dual-phase `spi_pll` remained in the private vault but had no active wrapper instance or Quartus binding. `GSENSOR_INT[1]` entered a two-flop PCLK synchronizer. The eleven initialization writes, 56-bit read, APB register packing and `PREADY=1` contract were retained. This paragraph records pinned A6 facts, not the P09B candidate contract below.

Focused/open tests pass, and the user-run `gsensor_pclk_01` Quartus fit has two active PLLs (ADC/VGA), no G-sensor generated clock, and positive 50 MHz setup/hold slack at the analyzed corners. This verifies the internal single-PCLK clocking sub-scope, **not** ADXL345 board-pin setup/hold, a VALID/SEQ API, atomicity across two separate APB reads, physical interrupt mapping, `GS-001`/`CDC-002` closure, or board acceptance. Detailed raw build evidence and the Phase 4A-GSENSOR report remain in the private local evidence archive.

## P09B final implementation and scoped evidence — paired publication update

> **Current Public integration:** This implementation is current with the paired P09B source/documentation commits. Earlier candidate wording is pre-publication provenance only; scoped evidence does not promote physical acceptance or retained NOT_RUN checks.

> **Publication synchronization:** The implementation below becomes the Public contract only with the paired source and documentation commits. Scoped evidence does not promote physical acceptance or retained NOT_RUN checks.

The P09B Public implementation implements the final P09B contract in
this document: direct shared `PRESETn`, twelve ordered initialization writes,
INT1-triggered/30 ms fallback acquisition, and the LIVE/HOLD/VALID/SEQ APB ABI.
Focused, host and CPU checker evidence, a fit/STA review and one board-display
observation exist for that candidate. These facts do not describe Public `main`,
do not turn physical INT1/orientation/calibration or external timing into a
pass, and do not close the retained NOT_RUN negative tests.

## Historical Stage 1 target/evidence at that time — not current candidate status

### Reset ownership and interrupted-transaction boundary

At Stage 1, the then-pinned A6 source had two sequential reset qualifications;
the then-proposed P09B target had only the shared system qualification. This
following subsection records that historical specification/evidence boundary;
it is not a statement that the P09B candidate above was unimplemented.

| Path/owner | Current pinned A6 | P09B target after separately approved RTL stage |
|---|---|---|
| `KEY[0]` → system | LOW asynchronously asserts `system_reset_controller`; release uses two HCLK flops then 1,000,000 qualified 50 MHz edges (~20 ms) | unchanged |
| SoC/bridge/APB | top `HRESETn=PRESETN_SYS`; bridge `PCLK=HCLK`, `PRESETn=HRESETn` | unchanged |
| G-sensor controller | wrapper `reset_delay(PRESETn,PCLK)` holds `iRSTN=!dly_rst` for another 2^20 PCLK (~20.97152 ms); init starts roughly 41 ms plus synchronization after button release | wrapper connects `spi_ee_config.iRSTN` **directly to `PRESETn`**; no second timer, generated reset or new clock domain |
| LIVE/HOLD/scheduler | not yet implemented | all XYZ/SEQ/VALID, IRQ synchronizer/history, pending request and watchdog use the same `PRESETn` |

The target removes the `reset_delay` **instantiation** and obsolete wrapper `RESET_DELAY_BITS` parameter at Stage 2 only; `reset_delay.v` is neither edited nor deleted at Stage 1. The existing shared reset controller, bridge and other consumers are unchanged. On common reset release, the controller begins exactly 12 ordered SPI initialization writes; acquisition/IRQ recognition and watchdog arming occur only after write 11 (`POWER_CTL`) has completed and CS is HIGH. This is a target sequence, not a measured startup time. The [ADXL345 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adxl345.pdf) describes bus availability with both supplies present and recommends configuration in standby before enabling measurement; the proposed POWER_CTL-last order follows that recommendation. Common reset does **not** prove sensor rail readiness by 20 ms: ramp, bus electrical availability, initialization and first DATA_READY behavior require separate physical validation.

Normal APB transfers are valid only while common reset is deasserted. Its **asynchronous assertion can overlap** SETUP, ACCESS, CAPTURE, E0/E1 or SPI shifting. Assertion aborts in-flight bus/sensor operations and dominates bank/command state. A read not completed before assertion has **no guaranteed valid return or completion and is not an accepted transfer**; an already completed read remains a historical completion. No specific AHB ERROR/OKAY is promised for an aborted transfer beyond actual bridge/CPU reset semantics. While reset is asserted, LIVE/HOLD are zero/invalid and initialization/acquisition are disabled. After synchronous release, APB accesses may resume, but both VALID bits remain zero until the first new complete digital burst (HOLD remains invalid until a later successful CAPTURE). Reset coincident with a clock edge is an asynchronous boundary, **not** the pre-edge STATUS/HOLD read linearization rule used for normal deasserted-reset transfers.

| Reset/transaction order | Contract / independent check |
|---|---|
| Read completes before reset assertion | Its old value is a valid historical completion; reset then clears both banks. |
| Reset assertion before read completion, including SETUP or ACCESS | Abort; no accepted read/command, no guaranteed read value/completion. |
| Reset overlaps CAPTURE/RELEASE or E0/E1 | Reset wins; no stale HOLD ownership, pending LIVE generation or post-release publication from the old burst. |
| Reset during a 56-bit SPI transaction | Abort transfer, drive safe idle pins, clear scheduler and restart the 12-write initialization after common release. |
| Reset during HOLD ownership | Clear HOLD XYZ/SEQ/VALID and LIVE; old owner must not return stale data or issue an unowned RELEASE. |

### Ownership, digital sample identity, and priorities

The P09 target retains one 50 MHz PCLK domain and fixed bank roles. The ADXL345 controller owns acquisition; LIVE `{x,y,z,seq[31:0],valid}` is a continuously overwritten producer bank; HOLD `{x,y,z,seq[31:0],valid}` is a CPU-owned snapshot. HOLD never changes after a successful CAPTURE until RELEASE or reset. Acquisition never waits for CPU consumption; there is no FIFO or promise to preserve intermediate generations. An uninterrupted, locally counted 56-bit SPI read is a **digital completed burst**, not an ACK/CRC/device-ID check or proof of a fresh, physically coherent sensor conversion.

At E0, the existing controller registers all three axes and `gsensor_ready=1` by nonblocking assignments on its last rising sample edge. A wrapper sequential process sees the old ready at E0. At E1 it observes ready=1 and stable axes; this **single E1 `sample_complete`** must atomically publish LIVE XYZ, increment LIVE_SEQ, and set LIVE_VALID. Do not increment a separate controller SEQ at E0. Reset sets both banks' XYZ, valid and seq to zero. The first completed burst publishes seq=1; every completed burst increments modulo 2^32 even for identical XYZ or watchdog rereads. A wrapped seq=0 may be valid.

`LIVE_VALID` means an **unconsumed completed digital burst pending since the last successful CAPTURE**, not “ever initialized.” `HOLD_VALID` means occupied snapshot. Let `C` be an accepted, correctly encoded CAPTURE whose **pre-edge** LIVE_VALID=1 and HOLD_VALID=0, and `E` be E1 `sample_complete`. Except for reset, `live_valid_next = (pre_live_valid && !C) || E`. A successful CAPTURE copies the pre-edge complete LIVE XYZ+SEQ into HOLD and sets HOLD_VALID. An ineligible CAPTURE is OKAY/no-op and does not clear LIVE_VALID. A same-edge E+C copies old LIVE to HOLD, publishes the new burst to LIVE and leaves LIVE_VALID=1; with pre-edge LIVE invalid, C no-ops and E sets pending. RELEASE clears HOLD XYZ/SEQ/VALID but not LIVE; same-edge E+RELEASE publishes LIVE independently. Reset dominates every event, command and read session.

| Edge/transfer | LIVE next | HOLD next | Observable result |
|---|---|---|---|
| Reset assertion | XYZ=0, seq=0, valid=0 | XYZ=0, seq=0, valid=0 | pending and ownership cancelled |
| E only | source XYZ, seq+1, valid=1 | unchanged | one digital generation |
| eligible C only | XYZ/seq unchanged, valid=0 | pre-edge LIVE XYZ/seq, valid=1 | one atomic snapshot |
| ineligible C | unchanged | unchanged | OKAY, no side effect |
| E+C, pre-live valid and HOLD empty | source XYZ, seq+1, valid=1 | pre-edge LIVE XYZ/seq, valid=1 | event wins over pending clear |
| E+C, pre-live invalid or HOLD occupied | source XYZ, seq+1, valid=1 | unchanged | C no-op; event preserved |
| RELEASE, with or without E | E publishes if present; otherwise unchanged | XYZ=0, seq=0, valid=0 | idempotent OKAY |
| malformed SNAP_CTRL, with or without E | E publishes if present; otherwise unchanged | unchanged | ERROR, no command effect |
| STATUS read concurrent with E | E publishes after edge | unchanged | read returns **pre-edge** registered bits; next read sees E |

STATUS read has no side effects and **no same-edge event-forwarding/bypass**. With reset deasserted, its APB combinational PRDATA corresponds to pre-edge registered state at the completing ACCESS edge. A concurrent E can therefore yield read bit0=0 while setting LIVE_VALID=1 immediately after that edge; the next read sees it. Same-edge forwarding may be recorded later only as an unimplemented engineering optimization, never as an AC. HOLD read data is likewise pre-edge on a normal command collision; asynchronous reset assertion instead follows the aborted-transaction rule above.

### APB ABI and errors

Only naturally aligned 32-bit accesses at base `0x4003_0000`, `PSEL[3]`, and the exact offsets below are valid. The bridge must extend the slot-3 full-offset allowlist from `+0x00/+0x04` to all five listed offsets, while still blocking mirrors, aliases, other offsets, unsupported sizes and reserved slots before any real select. A normal selected transfer is zero-wait (`PREADY=1`). A command fires exactly once at its accepted APB ACCESS completion, never in SETUP or once per ACCESS wait cycle; back-to-back ACCESS completions are distinct commands.

| Offset | Name | Read | Write | Invalid/side-effect policy |
|---:|---|---|---|---|
| `+0x00` | HOLD_XY | HOLD_VALID ? `{X[15:0],Y[15:0]}` : `0` | ERROR | no read effect |
| `+0x04` | HOLD_Z | HOLD_VALID ? `{16'b0,Z[15:0]}` : `0` | ERROR | no read effect |
| `+0x08` | STATUS | `{30'b0,HOLD_VALID,LIVE_VALID}` | ERROR | side-effect-free, pre-edge |
| `+0x0C` | HOLD_SEQ | HOLD_VALID ? HOLD_SEQ : `0` | ERROR | valid seq=0 is possible |
| `+0x10` | SNAP_CTRL | ERROR | exact `32'h1` CAPTURE; exact `32'h2` RELEASE | `0`, `3`, any reserved bit: ERROR/no command effect |
| other/noncanonical | none | ERROR | ERROR | no bank/command side effect |

Wrong direction at a listed offset and malformed control use wrapper `PSLVERR` at completing ACCESS, routed by top to the existing bridge `PSLVERR` input and project two-cycle AHB ERROR (`HRESP=01,HREADY=0` then `HRESP=01,HREADY=1`). The current top ties that input low: this error behavior is a **target**, not an existing end-to-end feature for G-sensor. Ineligible but well-encoded CAPTURE and RELEASE of empty HOLD are normal OKAY transactions, not traps. Invalid HOLD readback is zero, but zero data or seq alone never means invalid. No generic SPI/configuration writes or CPU/PLIC interrupt are introduced. The historical “G-sensor is read-only / writes no-op OKAY” statements in §§3, 14 and 17 describe the pre-P09 source and must not be used as the P09 ABI.

### Fixed sensor initialization and trigger scheduler

The replacement table uses project-owned constants, **not** the historical redistribution-restricted `spi_param.h`. Every row is one 16-bit SPI register write and must execute exactly once in the order shown; `POWER_CTL` is last. `BW_RATE=0x09` selects nominal 50 Hz normal-power ODR, `INT_MAP=0` routes DATA_READY to INT1, `INT_ENABLE=0x80` enables its output, and `DATA_FORMAT=0` retains the default ±2 g/right-justified format. `OFSZ=+7` is an additive offset of approximately +109 mg (7 × 15.6 mg), approximately 28 output counts in default ±2 g mode; it is **not** +28 mg. Its board calibration suitability remains an external check.

| Index | Register/address | Value |
|---:|---|---:|
| 0 | THRESH_ACT `0x24` | `0x20` |
| 1 | THRESH_INACT `0x25` | `0x03` |
| 2 | TIME_INACT `0x26` | `0x01` |
| 3 | ACT_INACT_CTL `0x27` | `0x7F` |
| 4 | THRESH_FF `0x28` | `0x09` |
| 5 | TIME_FF `0x29` | `0x46` |
| 6 | BW_RATE `0x2C` | `0x09` |
| 7 | INT_MAP `0x2F` | `0x00` |
| 8 | INT_ENABLE `0x2E` | `0x80` |
| 9 | DATA_FORMAT `0x31` | `0x00` |
| 10 | OFSZ `0x20` | `0x07` |
| 11 | POWER_CTL `0x2D` | `0x08` |

The current RTL maps top `G_SENSOR_INT[1]` through wrapper `GSENSOR_INT[1]` to controller port `iG_INT2`; the port name is misleading. The public pin assignment binds index 1 to `PIN_Y14`, and the DE10-Lite manual identifies Y14 as **INT1** (index 2/Y13 is INT2). This source/document identity does not replace a board electrical/waveform test. ADXL345 DATA_READY is deasserted by reading its axis data registers; the existing 56-bit DATAX0..DATAZ1 burst is the intended clear. A synchronized high level must not be interpreted as one new event per PCLK, and a pulse too short to reach the two-flop synchronizer cannot be guaranteed captured.

Target scheduler contract (one pending request slot, no FIFO): after the twelfth initialization write has fully ended and CS returns high, arm acquisition and zero the elapsed-PCLK counter. On the **next** PCLK edge, an already-high synchronized INT1 is recognized once. Recognize an IRQ when armed and synchronized INT1 is high; disarm IRQ recognition until a synchronized LOW is observed, then rearm. A new LOW→HIGH while the SPI engine is busy is recognized and coalesced into the one pending slot; further events coalesce. This is not a guarantee of one burst per physical DATA_READY pulse. Once recognized, IRQ resets the watchdog on that edge, including while busy; a held HIGH does not repeatedly reset it.

The watchdog independently counts PCLK edges while armed, including SPI-active time. At an arm/restart edge set elapsed=0; the **1,500,000th subsequent rising edge** reaches the 30 ms threshold (50 MHz), not the 1,499,999th. If no IRQ is eligible then, request one fallback acquisition. If busy, hold one FALLBACK pending and saturate the deadline until service, not a new timeout on each subsequent edge. Restart elapsed=0 when fallback is actually accepted/started. IRQ recognition and deadline on the same edge select IRQ, create only one acquisition request and one timer restart; an IRQ arriving before a deferred fallback starts upgrades it to IRQ. A pending request launches only when no init/read/CS-hold transfer is in flight; no transfer is aborted or overlapped. Reset clears sync history, arm state, timer, pending request and transfer. This policy guarantees one bounded request slot, **not** lossless interrupt capture or a precise 20 ms burst cadence. Normal 50 Hz DATA_READY should reset the watchdog before 30 ms; absence/stuck INT permits fallback, which may reread old physical data and still advances digital SEQ.

The pending request is a **single enum `NONE / FALLBACK / IRQ`**, not two independent bits. `IRQ > FALLBACK > NONE`; the table applies after reset and before any launch on the same edge. A recognized IRQ always restarts the watchdog once; a fallback start restarts it once; mere continued INT HIGH or saturated timeout does not. One completed idle launch consumes the pending slot.

| Pending before edge | Recognized IRQ | Watchdog deadline | Pending after arbitration, before optional idle launch |
|---|---|---|---|
| any | yes | either | IRQ; any old FALLBACK is upgraded/cancelled, never added |
| IRQ | no | either | IRQ; timeout cannot enqueue a second fallback |
| FALLBACK | no | either | FALLBACK; repeated deadline coalesces |
| NONE | no | yes | FALLBACK |
| NONE | no | no | NONE |

If the SPI engine is idle at arbitration, it starts at most the one selected request and clears pending; if busy, that one state remains deferred. Recognition of a new IRQ while busy resets elapsed even if another IRQ is already pending. A deadline reached while IRQ is already pending is suppressed, not queued. If that deadline saturates before the deferred IRQ can launch, the eventual IRQ launch consumes the suppressed deadline and restarts elapsed=0 once; otherwise the counter retains its origin at the last recognized IRQ. Thus a long busy interval cannot cause an immediate duplicate fallback after the IRQ read. An IRQ+deadline collision, including with a busy transfer or pending IRQ, must yield **one eventual read, never an extra fallback read**. Synchronized LOW rearms interrupt recognition; a continuously HIGH pin cannot generate another recognized IRQ, although the 30 ms watchdog may separately request a fallback later.

The old `POLL_BITS=14` checks bit14 of an idle counter incremented once per 25 PCLKs: nominal 16,384 × 25 / 50 MHz = 8.192 ms of **idle-count time**, not a precise end-to-end sampling interval. It is historical after P09. The P09 30 ms threshold is from last recognized IRQ or accepted fallback start, **not** from SPI completion. No physical ADXL345 update atomicity, peer setup/hold, ODR one-to-one delivery, orientation/calibration, or board acceptance follows from this digital contract.

### Firmware and acceptance boundary

The single-owner firmware lifecycle and error semantics are specified in `19_firmware_contract.md` and its Korean companion. The following acceptance list is the historical Stage 1 planned-check list. Its `NOT_RUN` labels apply to that gate, not to the later Public implementation evidence; independently retained negative and physical scope is identified in the closure packet.

| Acceptance IDs | Independent oracle / required observation | Stage 1 execution |
|---|---|---|
| AC-01..04 | Reference reset and pre-edge generation state; independently driven 56-bit asymmetric bytes; HOLD tuple fixed through LIVE refresh | NOT_RUN |
| AC-05..08 | APB command ledger and pre-edge state model; ineligible/malformed controls, release/recapture, E+C/E+RELEASE/pre-edge STATUS, seq wrap through valid zero | NOT_RUN |
| AC-09..10 | Full-address/size/direction ACCESS ledger and two-cycle fault; reset in SETUP, ACCESS, CAPTURE, 56-bit SPI, E0/E1 and HOLD ownership with no stale accepted command/sample | NOT_RUN |
| AC-11..12 | Scripted ordered firmware MMIO and actual CPU/AHB/APB result/fault signature, not a driver-derived expectation | NOT_RUN |
| AC-13..15 | Compiled-path HOLD_Z-from-LIVE_Z mutation rejected; pinned regression exit chain; separate external timing/pin/orientation gate | NOT_RUN |
| AC-16 (P09B) | Independent 12-write address/value/count/order oracle, including INT_MAP before INT_ENABLE and POWER_CTL last | NOT_RUN |
| AC-17 (P09B) | Independent 50 MHz edge counter at 1,499,999/1,500,000/1,500,001; initial-high, stuck-high, low rearm, busy IRQ, IRQ+deadline, pending priority and restart | NOT_RUN |
| AC-18 (P09B) | Negative one-slot oracle: inject IRQ+deadline while busy/IRQ pending, including >30 ms deferral, and reject any second/immediate fallback read; verify launch count/source and saturated-deadline restart | NOT_RUN |
| AC-19 (P09B) | Independent reset/accepted-transfer ledger: shared-release startup and all abort windows; no completion claim for an interrupted APB read and no old sample after reinit | NOT_RUN |

These IDs preserve P09A AC-01..15 as planned checks, updated to the approved P09B contract; any earlier `NO_SAMPLE` label is replaced by the four-result firmware API. No checker, runner or mutation has been implemented at this gate.

| Requirement | Pinned source evidence → target spec | Planned independent AC |
|---|---|---|
| Shared async-assert/sync-release path | `rtl/soc/system_reset_controller.v`, `rtl/soc/AMBA_SoC_TOP.v`, `rtl/bus/AHB_APB_bridge.v` → reset ownership table here and `06_reset_clock.md` | AC-01, AC-10, AC-19 |
| Remove only local G-sensor delay; preserve reset abort semantics | `rtl/peripherals/gsensor/APB_GSENSOR_MB.v`, `reset_delay.v`, `spi_ee_config.v` → reset/transaction table here | AC-09, AC-10, AC-19 |
| Full-byte digital XYZ, E0/E1 publish and atomic HOLD | `rtl/peripherals/gsensor/spi_ee_config.v` → §§11 and Ownership above | AC-02..04, AC-07, AC-13 |
| Exact 12-write startup, INT1 and one-slot IRQ/watchdog | current 11-write `spi_ee_config.v`, pin assignment → initialization/scheduler tables above | AC-16..18, AC-15 physical gate |
| APB error and single-owner firmware lifecycle | `rtl/bus/AHB_APB_bridge.v`, `rtl/soc/AMBA_SoC_TOP.v`, current wrapper → ABI above and `19_firmware_contract.md` | AC-05, AC-09, AC-11..12, AC-19 |
