# Baseline SoC Private SPI Engine Specification

> **Status:** ACTIVE SPECIFICATION — current integrated P09B baseline.
>
> **Canonical language:** English. If this file and `spi.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `reset_clock.md`, `gsensor.md`.

## 1. Purpose

This document defines the private SPI engine in the active FPGA baseline.

The baseline does **not** contain a software-visible, general-purpose APB SPI controller. The only active SPI datapath is a private fixed-function engine inside the G-sensor subsystem, dedicated to configuring and sampling the on-board ADXL345 accelerometer.

This specification owns:

- the architectural boundary of the private SPI engine,
- active RTL sources,
- SPI clock and reset generation,
- chip-select and serial-line behavior,
- the 16-bit initialization-write transaction format and 12-write configuration sequence,
- the 56-bit multi-byte accelerometer-read transaction format,
- acquisition scheduling (INT1 primary trigger and 30 ms watchdog fallback),
- controller sequencing and completion behavior,
- current limitations and non-programmable properties,
- verification status and remaining physical timing closure items,
- historical pre-P09 baseline behavior retained for provenance.

The software-visible accelerometer registers and coherent sample publication ABI are defined by `12_gsensor.md`.

## 2. Architectural Role

The active datapath is:

```text
CPU
 |
 | APB read of coherent sample snapshot (HOLD bank)
 v
APB_GSENSOR_MB                 PCLK = 50 MHz, shared PRESETn
 |
 +-- LIVE / HOLD sample banks + VALID / SEQ / SNAP_CTRL
 |
 +-- spi_ee_config             fixed-function ADXL345 controller, 50 MHz PCLK
      |
      +-- 12 ordered initialization writes (POWER_CTL last)
      +-- INT1-triggered / 30 ms watchdog fallback acquisition
      |
      +-- SPI engine           registered mode-3 SCLK, ~2 MHz
            |
            +--> G_SENSOR_CS_N
            +--> G_SENSOR_SCLK
            +--> G_SENSOR_SDI   (FPGA -> ADXL345, MOSI)
            +<-- G_SENSOR_SDO   (ADXL345 -> FPGA, MISO)
```

There is no:

```text
SPI_BASE
APB_SPI
software TX/RX FIFO
software programmable CPOL/CPHA
software programmable chip select
software programmable word length
software programmable clock divider
```

in the active baseline. References to "SPI" in this project refer strictly to this private sensor transport unless a future specification introduces a general-purpose SPI controller.

## 3. Active RTL Sources

The active implementation consists of:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
rtl/peripherals/gsensor/spi_ee_config.v
```

Module relationships:

```text
APB_GSENSOR_MB
  |
  +-- LIVE and HOLD sample banks + APB register interface
  +-- spi_ee_config
```

The historical modules `reset_delay.v`, `adxl345_controller.v`, `SPI_MASTER.v`, `spi_param.h`, and the private IP `spi_pll` are inactive in the current P09B baseline.

## 4. Clock and Reset Contract

### 4.1 Source Clock

`APB_GSENSOR_MB` and `spi_ee_config` operate entirely in the 50 MHz APB/system clock domain:

```text
PCLK = 50 MHz
```

There is no internal SPI generated clock domain or PLL.

### 4.2 Reset Distribution

The G-sensor controller connects directly to shared `PRESETn`:

```text
spi_ee_config.iRSTN = PRESETn
```

The historical wrapper `reset_delay` instance is removed from the active path.

- **Asynchronous assertion:** When `PRESETn` asserts low, any in-flight SPI transfer is immediately aborted, serial pins return to their safe idle values, and controller/scheduler state is cleared.
- **Synchronous release:** Reset release is synchronized to PCLK through the system reset qualification (~20 ms). Upon release, the controller immediately starts its 12 ordered initialization writes.

### 4.3 Serial Clock Generation

The external serial clock `G_SENSOR_SCLK` is driven directly by a registered output flip-flop in the 50 MHz PCLK domain.

The controller generates nominal 2 MHz SCLK by alternating 12 and 13 PCLK half-periods:

```text
12 PCLKs (240 ns) + 13 PCLKs (260 ns) = 25 PCLKs (500 ns = 2.0 MHz)
```

This registered clock output exists only on the board-facing pin; it is not an internal clock domain and does not clock internal registers.

## 5. Physical Serial Interface

The active board interface is a dedicated four-wire SPI connection:

| Signal | Direction | Baseline behavior |
|---|---|---|
| `G_SENSOR_CS_N` | FPGA -> sensor | active-low chip select |
| `G_SENSOR_SCLK` | FPGA -> sensor | idle high; registered 2 MHz mode-3 clock while active |
| `G_SENSOR_SDI` | FPGA -> sensor | command/address/write-data output (MOSI) |
| `G_SENSOR_SDO` | sensor -> FPGA | read-data input (MISO) |

The active design uses separate MOSI and MISO lines. During the read-data phase of a transaction, `G_SENSOR_SDI` is driven low.

## 6. Serial Protocol and Mode-3 Timing

The private SPI engine operates in **SPI Mode 3** (`CPOL = 1, CPHA = 1`):

- `G_SENSOR_SCLK` is high while idle.
- `G_SENSOR_CS_N` asserts low while SCLK remains high.
- MOSI data (`G_SENSOR_SDI`) changes on falling edges of SCLK.
- MISO data (`G_SENSOR_SDO`) is sampled on rising edges of SCLK.
- CS remains asserted low across the entire transaction and holds through the last sampled bit before returning high.

## 7. Initialization Write Transactions

### 7.1 Transaction Format

Each initialization transaction is a 16-bit serial write:

```text
[15:14] WRITE_MODE = 2'b00
[13: 8] ADXL345 register address[5:0]
[ 7: 0] register write data
```

Transmitted MSB-first from bit 15 to bit 0.

### 7.2 12-Write Initialization Sequence

Upon reset release, `spi_ee_config` executes exactly 12 ordered register writes:

| Index | ADXL345 register | Address | Written value | Operational purpose |
|---:|---|---:|---:|---|
| 0 | `THRESH_ACT` | `0x24` | `0x20` | Activity threshold |
| 1 | `THRESH_INACT` | `0x25` | `0x03` | Inactivity threshold |
| 2 | `TIME_INACT` | `0x26` | `0x01` | Inactivity time |
| 3 | `ACT_INACT_CTL` | `0x27` | `0x7F` | Activity/inactivity control |
| 4 | `THRESH_FF` | `0x28` | `0x09` | Free-fall threshold |
| 5 | `TIME_FF` | `0x29` | `0x46` | Free-fall time |
| 6 | `BW_RATE` | `0x2C` | `0x09` | 50 Hz output data rate, normal power |
| 7 | `INT_MAP` | `0x2F` | `0x00` | Routes DATA_READY to INT1 pin |
| 8 | `INT_ENABLE` | `0x2E` | `0x80` | Enables DATA_READY interrupt output |
| 9 | `DATA_FORMAT` | `0x31` | `0x00` | Default ±2g range, 10-bit right-justified |
| 10 | `OFSZ` | `0x20` | `0x07` | Z-axis offset calibration (~ +109 mg) |
| 11 | `POWER_CTL` | `0x2D` | `0x08` | Measurement mode enable (**executed last**) |

Executing `POWER_CTL` last ensures that the ADXL345 is fully configured in standby mode before measurement begins.

After the twelfth write completes and CS returns high, the acquisition scheduler arms, enabling INT1 recognition and the 30 ms watchdog.

## 8. Multi-Byte Accelerometer Read (56-Bit Burst)

### 8.1 Command and Structure

Each accelerometer acquisition performs a 56-bit SPI transaction:

```text
8-bit command/address phase  : {1'b1 (read), 1'b1 (multibyte), 6'h32 (DATAX0)} = 0xF2
48-bit read-data phase       : 6 bytes returned contiguously by ADXL345
```

The 6 returned data bytes correspond to:

```text
DATAX0, DATAX1 (X-axis low/high)
DATAY0, DATAY1 (Y-axis low/high)
DATAZ0, DATAZ1 (Z-axis low/high)
```

The controller extracts full 16-bit values for all three axes.

### 8.2 Internal Handshake

The low-level transfer completion is signaled internally by `spi_end` / `sample_complete`. Upon completion, the sample is atomically published to the LIVE bank in `APB_GSENSOR_MB`.

## 9. Acquisition Scheduler and Watchdog

### 9.1 Primary Trigger: INT1

- External pin `GSENSOR_INT[1]` (connected to DE10-Lite pin `Y14`, ADXL345 INT1) is synchronized into PCLK through a 2-FF synchronizer.
- When armed, a synchronized rising edge on INT1 triggers an acquisition read.
- Reading the axis data registers automatically clears DATA_READY inside the ADXL345.

### 9.2 Fallback Trigger: 30 ms Watchdog

- A 50 MHz counter measures elapsed PCLK cycles since the last recognized acquisition.
- At threshold 1,500,000 cycles (exactly 30 ms), a fallback acquisition is requested if no INT1 trigger has fired.
- Under normal 50 Hz operation, DATA_READY arrives every ~20 ms, resetting the watchdog before the 30 ms deadline.

### 9.3 Pending Request Arbitration

The scheduler maintains a single-slot pending request enum:

```text
NONE / FALLBACK / IRQ
```

- Priority: `IRQ > FALLBACK > NONE`.
- Triggers occurring while the SPI engine is busy are coalesced into the single pending slot; no duplicate reads are queued.
- When the SPI engine returns to idle, the pending request launches immediately.

## 10. Software Visibility and Status

There is no direct firmware interface to the private SPI engine:

- Software cannot configure SPI clock rate, mode, or chip select.
- Software cannot trigger manual SPI writes or reads.
- All software interaction occurs through the APB G-sensor register map (`HOLD_XY`, `HOLD_Z`, `STATUS`, `HOLD_SEQ`, `SNAP_CTRL`) using the `gsensor_read_sample()` API as defined in `12_gsensor.md` and `19_firmware_contract.md`.

## 11. Verification Status and Residual Closure Gaps

### 11.1 Verification Status

- **SPI-001 (Digital Transaction Verification):** `VERIFIED`. Scoped digital testbenches (`tb_gsensor_single_pclk.sv`) verify Mode 3 SCLK timing, 12/13-PCLK halves, all initialization writes, 56-bit burst reads, MSB-first bit order, rising-edge MISO sampling, exact CS assertion duration, and reset abort behavior.
- **Internal Timing Closure:** Quartus TimeQuest confirms positive 50 MHz setup/hold margins on all internal G-sensor paths across slow and fast corners.

### 11.2 Residual Closure Gaps (Why IN_PROGRESS / BLOCKED)

- **SPI-002 (Physical ADXL345 Pin Timing):** `IN_PROGRESS`. Board-facing SPI pin timing (external setup/hold relative to the ADXL345 datasheet limits, PCB trace delays, and pin capacitance) has not been physically characterized with an oscilloscope.
- **STA-002 (External I/O Timing / Electrical Closure):** `BLOCKED`. Awaiting physical board-level timing measurements and electrical sign-off across all board I/O interfaces.

## 12. Historical Baseline / Pre-P09 Notes

The following information describes earlier iterations of the G-sensor SPI subsystem and is retained strictly for provenance and historical interpretation:

1. **Historical Dual-Phase `spi_pll` (Pre-A6):**
   Originally, the subsystem used an Altera `spi_pll` IP generating two nominal 2 MHz clocks from 50 MHz with an ~80-degree phase shift (`spi_clk` for controller state and `spi_clk_out` for external SCLK). This created an unsafe internal `spi_clk -> PCLK` clock-domain crossing and required a separate PLL lock wait. A6 eliminated `spi_pll` entirely and converted the controller to single 50 MHz PCLK operation.
2. **Historical Local Reset Delay (`reset_delay.v`):**
   The A6 wrapper retained an instance of `reset_delay.v` (a 20-bit counter adding ~20.97 ms delay after system reset release, for a total startup delay of ~41 ms). P09B removed this instance, connecting `spi_ee_config` directly to shared `PRESETn`.
3. **Historical 11-Write Sequence:**
   The pre-P09 baseline executed 11 initialization writes with `INT_ENABLE = 0x00` (interrupts disabled) and enabled measurement mode (`POWER_CTL = 0x08`) at write index 10 rather than last. P09B expanded this to 12 ordered writes, enabling DATA_READY on INT1 and placing `POWER_CTL` last.
4. **Historical ~8.192 ms Polling Fallback:**
   The pre-P09 controller polled for data based on bit 14 of an idle counter (`POLL_BITS = 14`, nominal 16,384 × 25 / 50 MHz ≈ 8.192 ms), which was asynchronous to sensor ODR and produced duplicate samples. P09B replaced this with INT1-driven acquisition and a 30 ms watchdog.
5. **Historical Raw 2-Register APB Interface:**
   The pre-P09 APB wrapper exposed only two read-only registers (`GSENSOR_XY_DATA` and `GSENSOR_Z_DATA`) without `VALID`, `SEQ`, or atomic snapshot capability, risking torn reads across separate bus transactions. P09B introduced the coherent LIVE/HOLD architecture.
