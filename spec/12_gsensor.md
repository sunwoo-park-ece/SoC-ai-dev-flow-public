# Baseline SoC G-Sensor Subsystem Specification

> **Status:** ACTIVE SPECIFICATION — current integrated P09B baseline.
>
> **Canonical language:** English. If this file and `gsensor.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. Purpose

This document defines the on-board ADXL345 accelerometer / G-sensor subsystem in the active DE10-Lite FPGA baseline.

The subsystem operates as a dedicated hardware controller and coherent sample publication interface. It specifies:

- top-level integration and APB slot assignment,
- single 50 MHz PCLK domain and shared `PRESETn` reset architecture,
- fixed-function 12-write ADXL345 hardware initialization sequence,
- INT1-triggered acquisition scheduler with 30 ms watchdog fallback,
- private 4-wire SPI Mode 3 transaction engine,
- coherent sample publication using producer (LIVE) and snapshot (HOLD) banks,
- 5-register APB register map with atomic CAPTURE and RELEASE semantics,
- simultaneous event priority and asynchronous reset abort rules,
- production firmware driver contract (`gsensor_read_sample()`),
- current verification status and residual engineering closure gaps,
- historical pre-P09 baseline behavior retained for provenance.

The subsystem is a dedicated sensor transport and publication interface, not a generic software-programmable SPI controller.

## 2. Current Architecture

The G-sensor subsystem occupies APB slot 3 at canonical base address:

```text
GSENSOR_BASE = 0x4003_0000
APB slot     = PSEL[3]
```

Top-level integration:

```text
CPU (RV32I)
 |
 | AHB
 v
AHB-to-APB bridge
 |
 +--> PSEL[3]
       |
       v
 APB_GSENSOR_MB                       50 MHz PCLK, shared PRESETn
       |
       +-- LIVE bank                  producer payload {X, Y, Z, SEQ, VALID}
       +-- HOLD bank                  CPU snapshot {X, Y, Z, SEQ, VALID}
       +-- APB register decode        HOLD_XY, HOLD_Z, STATUS, HOLD_SEQ, SNAP_CTRL
       |
       +-- spi_ee_config              PCLK-only ADXL345 FSM
             |
             +-- 12-write initialization table
             +-- INT1 / 30 ms watchdog scheduler (1 pending slot)
             +-- registered mode-3 SPI master (~2 MHz)
                   |
                   +--> G_SENSOR_CS_N
                   +--> G_SENSOR_SCLK (~2 MHz registered output)
                   +--> G_SENSOR_SDI  (MOSI)
                   +<-- G_SENSOR_SDO  (MISO)
                   +<-- GSENSOR_INT[1] (INT1 input from sensor)
```

Active RTL sources:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
rtl/peripherals/gsensor/spi_ee_config.v
```

The historical modules `reset_delay.v`, `adxl345_controller.v`, `SPI_MASTER.v`, `spi_param.h`, and `spi_pll` are inactive in the current P09B baseline.

The APB wrapper provides zero-wait transfers (`PREADY = 1`) on canonical offsets. The APB wrapper asserts `PSLVERR` on the completing ACCESS for invalid accesses (unmapped offsets, wrong access directions, or malformed commands). The AHB-to-APB bridge converts that slave error into the project's two-cycle AHB ERROR response (`HRESP=01`).

## 3. Clock / Reset

### 3.1 Clock Architecture

The G-sensor controller, sample banks, and APB interface run synchronously on the single 50 MHz APB clock:

```text
PCLK = 50 MHz
```

- No internal SPI generated clock domain or PLL exists.
- The external serial clock `G_SENSOR_SCLK` is driven by a registered flip-flop with alternating 12/13 PCLK half-periods (nominal 2 MHz). SCLK is an external pin output only, not an internal clock domain.

### 3.2 Reset Architecture

The entire subsystem connects directly to the shared system peripheral reset:

```text
spi_ee_config.iRSTN = PRESETn
```

- **Shared Reset Qualification:** System reset release occurs after two-stage HCLK synchronization plus 1,000,000 PCLK cycles (~20 ms).
- **No Local Reset Delay:** The historical wrapper `reset_delay` instance (~20.97 ms) is removed from the active path.
- **Asynchronous Assertion:** Assertion of `PRESETn` immediately aborts any in-flight SPI transaction or APB access, drives serial lines to safe idle levels, and clears both LIVE and HOLD banks, SEQ, VALID, and scheduler state.
- **Synchronous Release:** Upon release, the controller immediately starts its 12 ordered ADXL345 initialization writes.

## 4. Initialization

After reset release, `spi_ee_config` performs exactly 12 ordered 16-bit register writes over SPI:

| Index | ADXL345 register | Address | Written value | Operational purpose |
|---:|---|---:|---:|---|
| 0 | `THRESH_ACT` | `0x24` | `0x20` | Activity threshold |
| 1 | `THRESH_INACT` | `0x25` | `0x03` | Inactivity threshold |
| 2 | `TIME_INACT` | `0x26` | `0x01` | Inactivity time |
| 3 | `ACT_INACT_CTL` | `0x27` | `0x7F` | Activity/inactivity control |
| 4 | `THRESH_FF` | `0x28` | `0x09` | Free-fall threshold |
| 5 | `TIME_FF` | `0x29` | `0x46` | Free-fall time |
| 6 | `BW_RATE` | `0x2C` | `0x09` | 50 Hz normal-power output data rate |
| 7 | `INT_MAP` | `0x2F` | `0x00` | Routes DATA_READY to INT1 pin |
| 8 | `INT_ENABLE` | `0x2E` | `0x80` | Enables DATA_READY interrupt output |
| 9 | `DATA_FORMAT` | `0x31` | `0x00` | Default ±2g range, 10-bit right-justified |
| 10 | `OFSZ` | `0x20` | `0x07` | Z-axis offset calibration (~ +109 mg) |
| 11 | `POWER_CTL` | `0x2D` | `0x08` | Measurement mode enable (**executed last**) |

Executing `POWER_CTL` last ensures the sensor is fully configured before measurement begins. Acquisition arms only after write 11 finishes and CS returns high.

## 5. Acquisition Scheduler

The scheduler arbitrates between physical sensor interrupts and a fallback timer:

### 5.1 Primary Trigger: INT1

- Board pin `G_SENSOR_INT[1]` (DE10-Lite pin `Y14`, ADXL345 INT1) is synchronized into PCLK via a 2-FF synchronizer.
- A synchronized rising edge recognized while armed triggers an acquisition burst.
- Reading axis registers over SPI clears the sensor's internal DATA_READY condition.

### 5.2 Fallback Trigger: 30 ms Watchdog

- An internal 50 MHz counter measures elapsed PCLK cycles since the last recognized acquisition.
- At 1,500,000 cycles (30 ms), a fallback acquisition is requested if no INT1 trigger has fired.
- Normal 50 Hz DATA_READY pulses arrive every ~20 ms, resetting the watchdog before the 30 ms deadline.

### 5.3 Request Arbitration

The scheduler maintains a single-slot pending request enum:

```text
NONE / FALLBACK / IRQ
```

- Priority: `IRQ > FALLBACK > NONE`.
- Triggers occurring while an SPI transfer is active are coalesced into the single pending slot; no duplicate reads are queued.
- When the SPI master returns to idle, the pending request launches immediately.

## 6. SPI Transaction Contract

- **Mode 3 Timing:** `CPOL = 1, CPHA = 1`. SCLK idles high; CS asserts while SCLK is high; MOSI toggles on falling edges; MISO is sampled on rising edges; CS holds through the last sampled bit.
- **Initialization Write (16 bits):** 8-bit command/address (`{2'b00, addr[5:0]}`) followed by 8-bit data.
- **Burst Read (56 bits):** 8-bit command `0xF2` (`{1'b1 (read), 1'b1 (multibyte), 6'h32 (DATAX0)}`) followed by 48 bits (6 bytes) of contiguous axis data:
  ```text
  DATAX0, DATAX1 (X-axis)
  DATAY0, DATAY1 (Y-axis)
  DATAZ0, DATAZ1 (Z-axis)
  ```
  The controller extracts full 16-bit values for X, Y, and Z.

## 7. LIVE/HOLD Sample Publication

The APB wrapper provides coherent publication through two internal banks:

- **LIVE Bank:** `{x[15:0], y[15:0], z[15:0], seq[31:0], valid}`. Continuously updated producer bank.
- **HOLD Bank:** `{x[15:0], y[15:0], z[15:0], seq[31:0], valid}`. CPU-owned snapshot bank.

### 7.1 Sample Completion Boundary (E0 / E1)

1. At SPI bit-counter completion (**E0**), axis registers and `gsensor_ready = 1` are registered.
2. On the following PCLK edge (**E1**, `sample_complete`), the wrapper atomically:
   - copies new X/Y/Z data into the LIVE bank,
   - increments `LIVE_SEQ` modulo 2^32 (first completed sample publishes `seq = 1`),
   - asserts `LIVE_VALID = 1`.

### 7.2 Capture and Release Semantics

- **CAPTURE (`SNAP_CTRL = 1`):** If `LIVE_VALID == 1` and `HOLD_VALID == 0`, atomically copies pre-edge LIVE data and sequence into HOLD, sets `HOLD_VALID = 1`, and clears `LIVE_VALID = 0`. An ineligible CAPTURE (when LIVE is invalid or HOLD is already occupied) completes as an APB OKAY no-op.
- **RELEASE (`SNAP_CTRL = 2`):** Clears HOLD data and sequence to zero, sets `HOLD_VALID = 0`. Does not alter the LIVE bank.

## 8. APB Register Map

Canonical base address is `0x4003_0000`. Aligned 32-bit accesses only:

| Offset | Name | Access | Read Data | Write Effect |
|---:|---|---|---|---|
| `0x00` | `HOLD_XY` | R | `HOLD_VALID ? {X[15:0], Y[15:0]} : 0` | ERROR (`PSLVERR`) |
| `0x04` | `HOLD_Z` | R | `HOLD_VALID ? {16'b0, Z[15:0]} : 0` | ERROR (`PSLVERR`) |
| `0x08` | `STATUS` | R | `{30'b0, HOLD_VALID, LIVE_VALID}` | ERROR (`PSLVERR`) |
| `0x0C` | `HOLD_SEQ` | R | `HOLD_VALID ? HOLD_SEQ : 0` | ERROR (`PSLVERR`) |
| `0x10` | `SNAP_CTRL` | W | ERROR (`PSLVERR`) | `32'h1` = CAPTURE, `32'h2` = RELEASE; others ERROR |

- Accesses to unmapped offsets (`> 0x10`), wrong access directions, or malformed write values to `SNAP_CTRL` cause the APB wrapper to assert `PSLVERR` on the completing ACCESS, which the AHB-to-APB bridge converts into the project's two-cycle AHB ERROR response.
- Reading `STATUS` has no side effects and returns the pre-edge registered state.

## 9. Event Priority / Reset Semantics

### 9.1 Simultaneous Event Priority

| Event Condition | LIVE Next | HOLD Next | Observable Behavior |
|---|---|---|---|
| Reset Assertion | All 0, valid = 0 | All 0, valid = 0 | Operations aborted, ownership cancelled |
| E only | New XYZ, seq+1, valid = 1 | Unchanged | New sample published to LIVE |
| Eligible C only | Unchanged, valid = 0 | Pre-edge LIVE, valid = 1 | Atomic snapshot acquired into HOLD |
| Ineligible C | Unchanged | Unchanged | APB OKAY no-op |
| E + C (LIVE valid, HOLD empty) | New XYZ, seq+1, valid = 1 | Pre-edge LIVE, valid = 1 | HOLD gets old sample, LIVE gets new |
| E + C (LIVE invalid or HOLD occupied) | New XYZ, seq+1, valid = 1 | Unchanged | C no-ops, E publishes new sample to LIVE |
| RELEASE (with/without E) | E publishes if present | All 0, valid = 0 | HOLD snapshot cleared |
| STATUS read concurrent with E | E publishes after edge | Unchanged | Returns the complete pre-edge STATUS value; E publication becomes visible on the following read |

### 9.2 Reset Abort Rules

- Asynchronous reset assertion overrides all bus and controller operations immediately.
- Any APB read or write interrupted by reset is aborted; no transfer completion or return value is guaranteed.
- Following reset release, `LIVE_VALID` and `HOLD_VALID` remain 0 until initialization completes and the first full digital burst finishes.

## 10. Firmware-visible Behavior

Firmware interacts with the G-sensor through the canonical C driver API:

```c
gsensor_status_t gsensor_read_sample(gsensor_sample_t *out);
```

### 10.1 Polling Protocol

1. Read `STATUS`.
   - If `HOLD_VALID == 1`, return `GSENSOR_BUSY`.
   - If `LIVE_VALID == 0`, return `GSENSOR_NO_NEW`.
2. Write `SNAP_CTRL = 1` (CAPTURE).
3. Read `STATUS` and verify `HOLD_VALID == 1`. If not, return `GSENSOR_NO_NEW`.
4. Read `HOLD_SEQ`, `HOLD_XY`, `HOLD_Z` in order.
5. Write `SNAP_CTRL = 2` (RELEASE).
6. Return `GSENSOR_OK` with populated `*out`.

### 10.2 Return Codes

- `GSENSOR_OK`: New coherent sample successfully retrieved.
- `GSENSOR_NO_NEW`: No new sample available since last capture.
- `GSENSOR_BUSY`: Snapshot currently occupied or contention detected.
- `GSENSOR_ERROR`: Null pointer or driver fault.

The driver is single-owner and non-reentrant.

## 11. Verification Status

P09B functional implementation, digital verification, actual RV32I CPU integration, Quartus/TimeQuest timing, and practical FPGA board operation are **COMPLETED and INTEGRATED**:

- **Digital Verification:** Mode 3 SPI waveforms, 12-write initialization sequence, 56-bit burst reads, LIVE/HOLD atomicity, single pending scheduler slot, and APB register decode/error handling pass all self-checking regressions.
- **CPU Integration:** RV32I CPU harness and driver mock-MMIO tests verify end-to-end CAPTURE/RELEASE polling and trap handling.
- **Timing Closure:** Internal 50 MHz PCLK timing passes with positive setup/hold margins across slow and fast temperature corners.
- **Board Demonstration:** Practical FPGA board operation confirmed via display applications (observed photo `SEQ=0x1450`, user observed `SEQ≈0x7C00`, dynamic tilt response).

## 12. Remaining Closure Gaps

The tracker retains conservative `IN_PROGRESS` (and `STA-002` `BLOCKED`) statuses for narrowly defined residual closure evidence gaps:

1. **GS-001 (Coherent XYZ / VALID / SEQ):** Functionality is verified in normal/CPU paths. Residual closure gap is exhaustive robustness evidence (asynchronous reset overlapping APB SETUP/ACCESS, reset vs CAPTURE/RELEASE, and sample-completion boundary edge cases).
2. **GS-003 (Acquisition policy):** 12-write init and INT1/watchdog scheduler are verified digitally. Residual gap is physical characterization (physical INT1 oscilloscope waveform/pin mapping, sensor ODR vs IRQ behavior, and physical fallback under abnormal conditions).
3. **GS-004 (First-sample validity / reset semantics):** Normal reset behavior verified. Residual gap is exhaustive reset-abort/corner coverage across active SPI transactions, APB phases, and HOLD ownership.
4. **GS-005 (Full G-sensor cleanup/acceptance):** Board-functional for baseline development. Full sign-off requires quantitative calibration, systematic orientation matrix, physical INT1 waveform evidence, long-duration SEQ integrity stress, and external SPI timing closure (`STA-002`).
5. **CDC-002:** Unsafe `spi_clk -> PCLK` crossing was removed earlier; P09B resolves software-visible torn reads via LIVE/HOLD publication. Non-VERIFIED status is due to conservative completion evidence, not an active unsafe crossing.
6. **FW-008 (Firmware API):** Driver is functional and verified. Residual gap is exhaustive reset-negative coverage and concurrent caller misuse handling.
7. **STA-002:** External ADXL345 SPI timing and board-level electrical sign-off remain BLOCKED pending physical measurements.

## 13. Historical A6 / Pre-P09 Notes

The following details describe earlier iterations and are retained strictly for provenance:

1. **A6 PCLK Conversion and `spi_pll` Removal:**
   Earlier designs used an Altera `spi_pll` to generate phase-shifted 2 MHz clocks (`spi_clk` and `spi_clk_out`), creating an unconstrained `spi_clk -> PCLK` CDC. A6 converted all internal logic to single 50 MHz PCLK and drove external SCLK from a registered flip-flop.
2. **Historical Local `reset_delay`:**
   The A6 wrapper instantiated `reset_delay.v`, which held the controller in reset for an additional 2^20 PCLK cycles (~20.97 ms) after system reset release. P09B eliminated this delay, connecting directly to shared `PRESETn`.
3. **Historical 11-Write Sequence:**
   The pre-P09 sequence performed 11 writes with `INT_ENABLE = 0x00` (interrupts disabled) and enabled measurement mode (`POWER_CTL = 0x08`) at index 10. P09B expanded this to 12 writes, routing DATA_READY to INT1 (`INT_ENABLE = 0x80`) and executing `POWER_CTL` last.
4. **Historical ~8.192 ms Polling Fallback:**
   The pre-P09 controller polled based on bit 14 of an idle counter (`POLL_BITS = 14`, ~8.192 ms), producing asynchronous repeated samples. P09B replaced this with INT1-triggered acquisition and a 30 ms watchdog.
5. **Historical Raw 2-Register APB Map:**
   The pre-P09 APB interface exposed only `GSENSOR_XY_DATA` (`+0x00`) and `GSENSOR_Z_DATA` (`+0x04`) as read-only registers without `VALID`, `SEQ`, or atomic snapshotting. P09B replaced this with the 5-register LIVE/HOLD ABI.
