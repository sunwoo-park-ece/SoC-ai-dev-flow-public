# Baseline SoC Private SPI Engine Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `spi.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `reset_clock.md`, `gsensor.md`.

> **Implementation note (Phase 4A-GSENSOR, 2026-09-14):** Earlier dual-phase `spi_pll`/`spi_clk` descriptions and the historical lack of a verified SPI mode are superseded for the current public candidate by the narrowly scoped implementation status at the end of this file. This does not assert physical pin-timing or board acceptance.

## 1. Purpose

This document defines the SPI engine that exists in the active FPGA baseline.

The baseline does **not** contain a software-visible, general-purpose APB SPI controller. The only active SPI datapath is a private fixed-function engine inside the G-sensor subsystem, dedicated to configuring and sampling the on-board ADXL345 accelerometer.

This specification owns:

- the architectural boundary of the private SPI engine,
- active RTL sources,
- SPI clock/reset generation,
- chip-select and serial-line behavior,
- the 16-bit initialization-write transaction format,
- the 56-bit multi-byte accelerometer-read transaction format,
- controller sequencing and completion behavior,
- current limitations and non-programmable properties,
- verification requirements,
- cleanup requirements before a reusable/general-purpose SPI peripheral is claimed.

The software-visible accelerometer registers themselves are defined by `gsensor.md`.

## 2. Architectural Role

The active datapath is:

```text
CPU
 |
 | APB read of accelerometer snapshot
 v
APB_GSENSOR_MB                 PCLK = 50 MHz
 |
 +-- reset_delay
 |
 +-- spi_pll
 |    +-- spi_clk      = 2 MHz   (controller state/sample clock)
 |    +-- spi_clk_out  = 2 MHz   (external SCLK source)
 |
 +-- spi_ee_config
      |
      +-- fixed ADXL345 initialization table
      +-- periodic / local-interrupt-triggered acquisition
      |
      +-- spi_controller
            |
            +--> G_SENSOR_CS_N
            +--> G_SENSOR_SCLK
            +--> G_SENSOR_SDI   (FPGA -> ADXL345)
            +<-- G_SENSOR_SDO   (ADXL345 -> FPGA)
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

in the active baseline.

Therefore references to "SPI" in this project shall not be interpreted as a generic software-accessible peripheral unless a future specification explicitly introduces one.

## 3. Active RTL Sources

The active implementation is primarily:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
rtl/peripherals/gsensor/v/adxl345_controller.v
rtl/peripherals/gsensor/v/SPI_MASTER.v
rtl/peripherals/gsensor/v/spi_param.h
rtl/peripherals/gsensor/v/reset_delay.v
private vendor-project vault: spi_pll generated IP (not in public tree)
```

Module relationships:

```text
APB_GSENSOR_MB
  |
  +-- reset_delay
  +-- spi_pll
  +-- spi_ee_config
        |
        +-- spi_controller
```

The module named `spi_controller` is implemented in `SPI_MASTER.v`.

## 4. Clock and Reset Contract

### 4.1 Source clock

`APB_GSENSOR_MB` receives the 50 MHz APB/system clock:

```text
PCLK = 50 MHz
```

A local `reset_delay` keeps the G-sensor SPI subsystem in reset for approximately:

```text
2^20 / 50 MHz = 20.97152 ms
```

after the system reset input is released.

### 4.2 SPI PLL

The generated `spi_pll` derives two nominal 2 MHz outputs from the 50 MHz input using divide-by-25 clock outputs.

```text
spi_clk      = PLL c0 = 2 MHz
spi_clk_out  = PLL c1 = 2 MHz
```

The generated PLL configuration uses different phase shifts for the two outputs. In the currently generated file:

```text
c0 phase shift = 277778 ps
c1 phase shift = 166667 ps
relative offset = 111111 ps
```

At a 2 MHz period of 500 ns, the relative offset is approximately 80 degrees.

`spi_clk` clocks the internal controller state, bit counter, and receive shift register. `spi_clk_out` is gated onto the external G-sensor SCLK pin while a transaction is active.

### 4.3 PLL lock limitation

The PLL `locked` output is not used. After `reset_delay` expires, the PLL reset and SPI controller reset are released without an explicit lock-qualified startup handshake.

This is current baseline behavior, not a preferred clock/reset architecture.

## 5. Physical Serial Interface

The active board interface is four-wire SPI-style signaling:

| Signal | Direction | Baseline behavior |
|---|---|---|
| `G_SENSOR_CS_N` | FPGA -> sensor | active-low chip select |
| `G_SENSOR_SCLK` | FPGA -> sensor | idle high; phase-shifted 2 MHz PLL clock while active |
| `G_SENSOR_SDI` | FPGA -> sensor | command/address/write-data output |
| `G_SENSOR_SDO` | sensor -> FPGA | read-data input |

The active design does not use a bidirectional SDIO line. A previously considered tri-state implementation remains commented out in the source; the active `SPI_SDI` output is always driven.

During the read-data phase, `SPI_SDI` is driven low rather than tri-stated. This is valid for the active separate-MOSI/separate-MISO board wiring but shall not be generalized to 3-wire SPI.

## 6. Chip-Select and SCLK Behavior

The private engine implements:

```verilog
assign oSPI_CSN = ~iSPI_GO;
assign oSPI_CLK = spi_count_en ? iSPI_CLK_OUT : 1'b1;
```

Therefore:

- `iSPI_GO = 1` drives chip select low.
- inactive SCLK is forced high.
- the external SCLK toggles only while `spi_count_en = 1`.
- the external clock source is `spi_clk_out`, not the internal state clock `spi_clk`.

Chip select is controlled by the higher-level `spi_ee_config` FSM. The low-level engine does not expose independent CS timing configuration.

## 7. Low-Level Bit Counter

`spi_controller` uses one 6-bit down-counter for both supported transaction types.

```text
initialization transaction:
    cnt_start_val = 15
    intended bit indices = 15 .. 0
    transaction width = 16 bits

multi-byte read transaction:
    cnt_start_val = 55
    intended bit indices = 55 .. 0
    transaction width = 56 bits
```

The completion indication is:

```verilog
assign oSPI_END = ~|spi_count;
```

so the higher-level controller treats counter value zero as the transfer-completion condition.

`oSPI_END` is an internal local handshake. It is not exposed to APB software.

## 8. Initialization Write Transactions

### 8.1 Format

During initial configuration, `ini_config = 1` and the low-level engine operates on a 16-bit transaction.

The higher-level controller creates:

```text
[15:14] WRITE_MODE = 2'b00
[13: 8] ADXL345 register address[5:0]
[ 7: 0] register write data
```

Conceptually:

```text
+----------------------+----------------------+
| 8-bit command/address| 8-bit register data  |
+----------------------+----------------------+
          16 serial bits total
```

The current source sends bits by indexing `internal_tx_data[spi_count]` while the counter decrements, so the transaction is emitted MSB-first from bit 15 toward bit 0.

### 8.2 Fixed initialization sequence

`spi_ee_config` performs eleven fixed register writes after reset. The active table includes:

```text
THRESH_ACT      <- 0x20
THRESH_INACT    <- 0x03
TIME_INACT      <- 0x01
ACT_INACT_CTL   <- 0x7F
THRESH_FF       <- 0x09
TIME_FF         <- 0x46
BW_RATE         <- 0x09
INT_ENABLE      <- 0x00
INT_MAP         <- 0x00
DATA_FORMAT     <- 0x00
POWER_CONTROL   <- 0x08
```

These transactions are generated entirely by hardware. Software cannot modify this table through a generic SPI register interface in the baseline.

## 9. Multi-Byte Accelerometer Read

### 9.1 Trigger

After initialization, `spi_ee_config` periodically initiates an accelerometer read when either:

```text
iG_INT2 == 1
```

or the private read-idle counter reaches its trigger bit.

As defined in `gsensor.md`, the current fallback counter uses `IDLE_MSB = 14`, corresponding to approximately 8.192 ms at 2 MHz.

### 9.2 Command format

The read command is constructed as:

```verilog
p2s_data[15:8] <= {2'b11, X_LB};
```

with:

```text
X_LB = 0x32
```

Thus the transmitted command byte is the ADXL345 multi-byte-read command beginning at DATAX0.

The 56-bit transfer is structured as:

```text
8 command/address bits
+ 48 returned data bits
-----------------------
= 56 serial bits total
```

The six returned bytes correspond to the contiguous ADXL345 axis-data register range:

```text
DATAX0
DATAX1
DATAY0
DATAY1
DATAZ0
DATAZ1
```

### 9.3 Drive/sample phases

For a 56-bit read:

```text
spi_count 55 .. 48
    command/address phase
    FPGA drives SPI_SDI

spi_count 47 .. 0
    read-data phase
    FPGA drives SPI_SDI low
    FPGA samples SPI_SDO into oS2P_DATA
```

The receive register shifts one SDO sample into its least-significant end on each `posedge spi_clk` for which the controller is in the read-data phase.

The interpretation of the 48 received data bits into X/Y/Z is owned by `12_gsensor.md`. This older paragraph is historical: active A6 reconstructs all three axes from complete `completed_rx` byte pairs, with scoped `GS-002` known-pattern digital evidence; P09B must revalidate it after changes.

## 10. SPI Timing Mode Classification

The current engine shall **not** be advertised as a generic SPI Mode 0, 1, 2, or 3 controller solely from the RTL naming.

Observable baseline properties include:

- SCLK is forced high while idle.
- internal state/data sampling occurs on `posedge spi_clk`.
- external SCLK is sourced from a separately phase-shifted `spi_clk_out`.
- `spi_clk` and `spi_clk_out` have the same nominal 2 MHz frequency but a generated relative phase offset of approximately 80 degrees.

Because launch/sample timing is created by two distinct phase-shifted PLL outputs rather than by one standard CPOL/CPHA edge-selection scheme, a standard SPI mode classification requires waveform-level confirmation against the ADXL345 timing requirements.

The fact that the existing FPGA design communicates with the board accelerometer does not by itself make this engine a reusable or standards-clean SPI master.

## 11. Software Visibility

There is no direct firmware API for the low-level SPI engine.

Software cannot directly request:

```text
SPI transmit
SPI receive
chip-select change
clock-rate change
CPOL/CPHA change
transaction-length change
register-address transaction
```

The CPU only observes accelerometer data through the G-sensor APB wrapper.

Accordingly, there is no normative `SPI_BASE` address in the baseline memory map.

## 12. Error and Status Behavior

The private SPI engine has no software-visible:

```text
BUSY
DONE
ERROR
TIMEOUT
RX_VALID
TX_READY
FIFO status
slave-not-responding status
```

The low-level `oSPI_END` and higher-level `gsensor_ready` are internal signals only.

The engine does not perform an explicit device-ID read/validation before beginning normal operation.

There is no protocol-level timeout if the external sensor returns invalid data. The bit counter completes based on locally generated clocks regardless of sensor response.

## 13. Reset Behavior

On low-level controller reset:

```text
spi_count_en = 0
spi_count    = 15
oS2P_DATA    = 0
```

The higher-level G-sensor controller resets its initialization index and restarts the fixed configuration sequence after local reset release.

The active external SCLK idle value is high and CS is deasserted when `spi_go = 0`.

As noted above, the baseline does not qualify controller release with PLL `locked`.

## 14. Baseline Invariants

For the current FPGA baseline, the following are normative:

1. The SPI engine is private to the G-sensor subsystem.
2. There is no software-visible generic SPI peripheral or SPI base address.
3. The engine uses a dedicated four-wire connection to the board accelerometer.
4. Initialization writes are fixed 16-bit hardware-generated transactions.
5. Accelerometer acquisition uses a fixed 56-bit command-plus-six-byte-read transaction.
6. The nominal serial clock is 2 MHz.
7. SCLK is high while inactive.
8. CS is active low and is controlled by `spi_go`.
9. Software cannot configure clock rate, mode, chip select, word length, or transaction content directly.
10. Standard SPI Mode 0–3 compliance is not claimed for this private implementation.

## 15. Verification Requirements

A dedicated SPI regression shall eventually verify at minimum:

1. reset leaves CS inactive and SCLK high,
2. each initialization entry produces exactly the intended command/address byte and data byte,
3. all eleven initialization writes occur in the intended order,
4. a multi-byte read emits the expected command beginning at address `0x32`,
5. the read transaction contains one command byte followed by six returned bytes,
6. CS remains asserted across the complete intended transaction,
7. SCLK is active only during the intended transfer window,
8. MOSI/SDI bit ordering is correct,
9. MISO/SDO sampling reconstructs deterministic known response patterns correctly,
10. `oSPI_END` occurs at the expected terminal count,
11. the higher-level controller does not start a new transaction before the previous transfer completes,
12. clock/reset release behavior is deterministic,
13. waveform timing satisfies the ADXL345 serial-interface timing requirements.

For known-pattern read verification, the testbench should return recognizable byte values for all six axis bytes rather than all-zero or symmetric patterns, so bit-order and byte-order faults cannot hide.

## 16. Baseline Cleanup Targets Before Major Feature Integration

The following items shall be carried into the consolidated baseline cleanup list.

### SPI-001 — Decide private engine versus reusable SPI architecture

The current block is a sensor-specific sequencer, not a general-purpose SPI peripheral. Before describing the future SoC as having a general-purpose SPI controller, either:

- keep this block explicitly private and design a separate generic SPI IP, or
- replace/refactor it into a generic SPI master with a clean device-specific layer above it.

### SPI-002 — Replace dual-phase-PLL protocol timing with a clear synchronous SPI architecture

Frozen A6 selects a single 50 MHz PCLK state clock, clock-enable/tick timing, and a registered external SCLK for the private ADXL345 engine. A future reusable controller is separate from this baseline cleanup.

### SPI-003 — Define and verify CPOL/CPHA behavior

The baseline idles SCLK high but does not expose a standard mode abstraction. Waveform-level timing shall be checked and a future generic controller shall explicitly define supported modes.

### SPI-004 — Qualify reset release with clock readiness or eliminate the PLL dependency

If a PLL remains in the architecture, controller operation shall not begin until the generated clock is valid according to an explicit lock/reset policy.

### SPI-005 — Add deterministic transaction-level verification

Verify exact 16-bit writes, 56-bit reads, bit order, byte order, CS duration, clock count, and known-pattern readback.

### SPI-006 — Separate sensor policy from transport

ADXL345 register initialization, sampling policy, and axis parsing should not be structurally embedded in a reusable SPI transport controller.

### SPI-007 — Add generic software contract only if generic SPI is introduced

A future software-visible SPI peripheral would require a separate approved specification covering at least:

```text
base address
control/status registers
clock divisor
CPOL/CPHA
chip-select selection
TX/RX data path
FIFO policy
busy/done/error behavior
interrupt policy
transfer width
backpressure / timeout semantics
```

No such contract exists in the baseline.

## 17. Non-Goals

This baseline specification does not:

- allocate a new APB slot for generic SPI,
- define a future SPI register map,
- claim support for multiple SPI slaves,
- claim DMA-driven SPI,
- claim FIFO buffering,
- claim standard SPI Mode 0–3 compliance,
- change the existing ADXL345 hardware sequence.

The statements above describe the historical pre-A6 implementation; the Phase 4A-GSENSOR status below records the current public candidate.

## Phase 4A-GSENSOR A6 SPI Timing Implementation

The current public candidate implements the approved A6 private ADXL345 transport with one 50 MHz PCLK FSM, registered idle-high SCLK, and no active dual-phase `spi_pll`. Alternate 12/13 PCLK half-periods make a 25-PCLK (2 MHz) SCLK cycle. It remains 4-wire, active-low CS, MSB first, mode 3 (CPOL=1, CPHA=1): CS asserts while SCLK is high, MOSI changes on falling edges, MISO is sampled on rising edges, and CS holds through the last sampled bit. Directed 16/56-bit transactions, reset, INT synchronization and known-pattern XYZ tests pass. The user-run fit contains no SPI PLL generated clock and passes internal 50 MHz setup/hold.

Earlier sections about two phase-shifted `spi_pll` clocks describe the historical baseline only. Physical ADXL345 pin setup/hold, board operation and the software-visible VALID/SEQ/cross-read snapshot remain unverified; `SPI-002` and `STA-002` are not closed by the internal timing result. Detailed Phase 4A-GSENSOR evidence remains in the private local evidence archive.

## Phase 4A-SPI-001 Digital Evidence Closure (2026-09-15)

User/Chat approved the current tracker `SPI-001` transition to `VERIFIED` for digital transaction/waveform evidence only. The directed `verification/directed/models/gsensor/tb_gsensor_single_pclk.sv` checks mode 3, registered 12/13-PCLK SCLK halves, all eleven 16-bit initialization writes, three complete 56-bit reads, MOSI order, rising-edge MISO capture, exact CS lifetime, non-symmetric known-pattern data, and in-flight reset abort/safe-idle/restart; the focused G-sensor regression passes. No synthesizable RTL or SDC/QSF change, Quartus build, or board test was part of this closure. `SPI-002` remains `IN_PROGRESS` for physical ADXL345 timing; `GS-005`, `STA-002`, `CDC-002`, and `GS-001` retain their separate open gates.

The older §16 heading also labeled “SPI-001” discusses private versus generic SPI as historical pre-A6 context. It is preserved here; the current tracker `SPI-001` is the directed digital waveform-verification row. Terminology cleanup belongs to the later Full Spec Refresh.

## P09B ADXL345 transaction contract — paired publication update

> **Current Public integration:** The 12-write PCLK-only implementation is current with the paired P09B source/documentation commits. Historical 11-write evidence remains historical and `SPI-002` remains open.

> **Publication synchronization:** The 12-write PCLK-only implementation is published only with its matching source commit. Historical 11-write evidence remains historical and `SPI-002` remains open.

The isolated P09B candidate retains the fixed-function PCLK-only mode-3 transport and full 56-bit DATAX0..DATAZ1 read. Its 12 initialization writes, in order, are `(0x24,0x20)`, `(0x25,0x03)`, `(0x26,0x01)`, `(0x27,0x7F)`, `(0x28,0x09)`, `(0x29,0x46)`, `(0x2C,0x09)`, `(0x2F,0x00)`, `(0x2E,0x80)`, `(0x31,0x00)`, `(0x20,0x07)`, `(0x2D,0x08)`. Thus 50 Hz DATA_READY is enabled and mapped to INT1; measurement mode is last. The existing 11-write waveform evidence remains historical and cannot verify this new table. In the isolated candidate the controller reset input is direct `PRESETn`, **not** the historical extra 2^20-PCLK local delay. It starts initialization on common reset release and arms acquisition/watchdog only after all twelve writes end with CS HIGH. Asynchronous reset assertion aborts in-flight SPI, clears scheduler state and restarts this full sequence after synchronous release; no old E0/E1 completion may publish afterward. A completed digital burst is not proof of a new physical conversion. INT1 is the primary trigger and a 30 ms elapsed-PCLK watchdog is the fallback, not the historical nominal 8.192 ms idle poll. Exact coalescing, edge priorities and sample publication are specified in [12_gsensor.md](12_gsensor.md). The Stage 1 `NOT_RUN` labels are historical. The isolated candidate has focused digital and CPU/host evidence, but sensor-supply startup, ADXL345 board timing and physical pin checks remain outside this contract; `SPI-002` is not closed. None of this updates current Public `main` before integration approval.
