# Baseline SoC Private SPI Engine Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/13_spi.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `reset_clock.md`, `gsensor.md`.

## 1. 목적

이 문서는 active FPGA baseline에 실제 존재하는 SPI engine을 정의한다.

현재 baseline에는 software-visible **general-purpose APB SPI controller가 없다.** 실제 active SPI datapath는 G-sensor subsystem 내부에 있는 전용 fixed-function engine이며, 보드의 ADXL345 accelerometer 설정 및 데이터 수집에만 사용된다.

이 문서의 범위는 다음과 같다.

- private SPI engine의 architecture boundary
- active RTL source
- SPI clock/reset generation
- CS/SCLK/SDI/SDO behavior
- 16-bit initialization write transaction
- 56-bit multi-byte accelerometer read transaction
- controller sequencing 및 completion behavior
- 현재 non-programmable limitation
- verification requirement
- reusable/general-purpose SPI를 주장하기 전에 필요한 cleanup

CPU가 읽는 accelerometer APB register 자체는 `gsensor.md`가 소유한다.

## 2. Architecture Role

Active datapath:

```text
CPU
 |
 | accelerometer snapshot APB read
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
      +-- periodic / local interrupt-triggered acquisition
      |
      +-- spi_controller
            |
            +--> G_SENSOR_CS_N
            +--> G_SENSOR_SCLK
            +--> G_SENSOR_SDI   (FPGA -> ADXL345)
            +<-- G_SENSOR_SDO   (ADXL345 -> FPGA)
```

현재 baseline에는 다음이 없다.

```text
SPI_BASE
APB_SPI
software TX/RX FIFO
software programmable CPOL/CPHA
software programmable chip select
software programmable word length
software programmable clock divider
```

따라서 이 프로젝트에서 단순히 "SPI가 있다"고 표현할 때 이를 software-accessible generic peripheral로 해석하면 안 된다.

## 3. Active RTL

주요 active source:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
rtl/peripherals/gsensor/v/adxl345_controller.v
rtl/peripherals/gsensor/v/SPI_MASTER.v
rtl/peripherals/gsensor/v/spi_param.h
rtl/peripherals/gsensor/v/reset_delay.v
비공개 vendor-project vault: spi_pll generated IP (public tree에 없음)
```

Module 관계:

```text
APB_GSENSOR_MB
  |
  +-- reset_delay
  +-- spi_pll
  +-- spi_ee_config
        |
        +-- spi_controller
```

`spi_controller` module은 `SPI_MASTER.v`에 구현되어 있다.

## 4. Clock / Reset Contract

### 4.1 Source clock

G-sensor wrapper는 50 MHz `PCLK`를 사용한다.

```text
PCLK = 50 MHz
```

`reset_delay`는 system reset release 이후 약 다음 시간 동안 local SPI subsystem reset을 유지한다.

```text
2^20 / 50 MHz = 20.97152 ms
```

### 4.2 SPI PLL

`spi_pll`은 50 MHz 입력에서 두 개의 nominal 2 MHz clock을 만든다.

```text
spi_clk      = PLL c0 = 2 MHz
spi_clk_out  = PLL c1 = 2 MHz
```

현재 generated PLL 기준 phase shift는:

```text
c0 = 277778 ps
c1 = 166667 ps
relative offset = 111111 ps
```

2 MHz period가 500 ns이므로 상대 위상은 약 80도다.

- `spi_clk`: controller state, bit counter, receive shift register clock
- `spi_clk_out`: transaction 중 external `G_SENSOR_SCLK` source

### 4.3 PLL lock limitation

현재 PLL `locked` output은 사용하지 않는다. `reset_delay` 종료 후 PLL reset과 controller reset이 explicit lock-qualified handshake 없이 release된다.

이것은 baseline 동작 기록이지 권장 architecture가 아니다.

## 5. Physical Serial Interface

현재 보드 연결은 4-wire SPI-style interface다.

| Signal | Direction | 동작 |
|---|---|---|
| `G_SENSOR_CS_N` | FPGA -> sensor | active-low chip select |
| `G_SENSOR_SCLK` | FPGA -> sensor | idle high, active 시 2 MHz PLL clock |
| `G_SENSOR_SDI` | FPGA -> sensor | command/address/write data |
| `G_SENSOR_SDO` | sensor -> FPGA | read data |

Active design은 bidirectional SDIO를 사용하지 않는다. 과거 tri-state SDIO 구현 시도는 source에 comment로 남아 있지만 active RTL에서는 `SPI_SDI`를 항상 output으로 구동한다.

Read-data phase에서도 `SPI_SDI`는 tri-state가 아니라 0으로 구동된다. 이는 현재 separate MOSI/MISO board wiring에서는 사용할 수 있지만 3-wire SPI로 일반화할 수 없다.

## 6. CS / SCLK Behavior

Low-level engine:

```verilog
assign oSPI_CSN = ~iSPI_GO;
assign oSPI_CLK = spi_count_en ? iSPI_CLK_OUT : 1'b1;
```

따라서:

- `iSPI_GO=1`이면 CS low
- inactive SCLK는 high
- `spi_count_en=1`일 때만 SCLK toggle
- external SCLK는 `spi_clk_out`에서 생성

CS timing은 상위 `spi_ee_config` FSM이 제어하며 software configurable CS timing은 없다.

## 7. Bit Counter / Transaction Width

`spi_controller`는 하나의 6-bit down-counter로 두 transaction type을 처리한다.

```text
Initialization:
    cnt_start_val = 15
    bit index 15 .. 0
    16-bit transaction

Multi-byte read:
    cnt_start_val = 55
    bit index 55 .. 0
    56-bit transaction
```

Completion:

```verilog
assign oSPI_END = ~|spi_count;
```

즉 counter가 0이면 local transfer complete로 판단한다. `oSPI_END`는 CPU/APB에 노출되지 않는다.

## 8. Initialization Write Transaction

Initialization 단계에서는 `ini_config=1`이고 16-bit transaction을 사용한다.

```text
[15:14] WRITE_MODE = 2'b00
[13: 8] ADXL345 register address[5:0]
[ 7: 0] register write data
```

즉:

```text
8-bit command/address + 8-bit data = 16 bits
```

`internal_tx_data[spi_count]`를 counter 감소 순서로 내보내므로 현재 transaction은 bit 15부터 bit 0까지 MSB-first로 전송된다.

Reset 후 hardware가 수행하는 fixed initialization table:

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

Software는 generic SPI register를 통해 이 table을 변경할 수 없다.

## 9. Multi-Byte Accelerometer Read

Initialization 이후 `spi_ee_config`는 다음 중 하나가 참이면 read transaction을 시작한다.

```text
iG_INT2 == 1
또는
private read_idle_count trigger
```

`gsensor.md`에서 정의한 것처럼 현재 fallback trigger는 `IDLE_MSB=14`, 즉 2 MHz에서 약 8.192 ms다.

Read command:

```verilog
p2s_data[15:8] <= {2'b11, X_LB};
```

```text
X_LB = 0x32
```

따라서 DATAX0부터 시작하는 ADXL345 multi-byte read command를 보낸다.

전체 transaction:

```text
8 command/address bits
+ 48 returned data bits
-----------------------
= 56 bits
```

연속으로 읽는 register:

```text
DATAX0
DATAX1
DATAY0
DATAY1
DATAZ0
DATAZ1
```

Low-level phase:

```text
spi_count 55 .. 48
    command/address phase
    FPGA drives SPI_SDI

spi_count 47 .. 0
    read-data phase
    SPI_SDI = 0
    SPI_SDO sampled into oS2P_DATA
```

Read-data phase에서 `posedge spi_clk`마다 SDO sample을 receive shift register에 shift-in한다.

48개 수신 data bit의 X/Y/Z 해석은 `12_gsensor.ko.md`가 소유한다. 이 앞선 문단은 역사 기록이다. 현행 A6은 세 축 모두 완전한 `completed_rx` byte pair로 복원하고 제한된 `GS-002` known-pattern digital 증거가 있으며 P09B 변경 후 재검증해야 한다.

## 10. SPI Mode Classification

현재 engine을 RTL 이름만 보고 SPI Mode 0/1/2/3 중 하나로 공식 분류하면 안 된다.

Baseline에서 확인되는 것은:

- SCLK idle high
- internal state/data sample은 `posedge spi_clk`
- external SCLK는 별도 phase-shifted `spi_clk_out`
- 두 clock은 nominal 2 MHz지만 relative phase가 약 80도

즉 하나의 clock에서 CPOL/CPHA edge를 선택하는 전형적인 generic SPI controller가 아니라 두 PLL output의 phase relationship으로 timing을 만든 구조다.

따라서 ADXL345 timing requirement와의 waveform-level verification 전에는 generic SPI mode compliance를 주장하지 않는다.

보드에서 accelerometer가 동작했다는 사실은 이 engine이 reusable/standards-clean SPI master라는 의미가 아니다.

## 11. Software Visibility

Low-level SPI engine에 대한 direct firmware API는 없다.

Software는 직접 다음을 할 수 없다.

```text
SPI TX
SPI RX
chip-select control
clock-rate change
CPOL/CPHA change
transaction-length change
arbitrary register transaction
```

CPU는 G-sensor APB wrapper를 통해 accelerometer snapshot만 읽는다.

따라서 baseline memory map에는 normative `SPI_BASE`가 없다.

## 12. Error / Status Limitation

Software-visible 다음 status가 없다.

```text
BUSY
DONE
ERROR
TIMEOUT
RX_VALID
TX_READY
FIFO status
slave-not-responding
```

`oSPI_END`, `gsensor_ready`는 local internal signal이다.

Device-ID 확인 sequence도 없고, external sensor가 잘못된 데이터를 반환해도 local bit counter는 clock에 따라 정상 종료된다.

즉 protocol-level sensor-response error detection이 없다.

## 13. Reset Behavior

Low-level controller reset:

```text
spi_count_en = 0
spi_count    = 15
oS2P_DATA    = 0
```

상위 G-sensor controller는 initialization index를 reset하고 local reset release 이후 fixed configuration sequence를 처음부터 수행한다.

Inactive 상태에서는:

```text
CS = high
SCLK = high
```

이며 PLL lock qualification은 없다.

## 14. Baseline Invariants

현재 baseline에서 다음은 normative하다.

1. SPI engine은 G-sensor 전용 private engine이다.
2. software-visible generic SPI peripheral 및 SPI base address는 없다.
3. 보드 accelerometer와 4-wire로 연결된다.
4. Initialization은 hardware-generated fixed 16-bit write다.
5. Acquisition은 fixed 56-bit command + six-byte read다.
6. nominal serial clock은 2 MHz다.
7. inactive SCLK는 high다.
8. CS는 active-low이며 `spi_go`가 제어한다.
9. software는 clock/mode/CS/word length/transaction content를 직접 설정할 수 없다.
10. SPI Mode 0~3 compliance는 baseline에서 주장하지 않는다.

## 15. Verification Requirements

향후 dedicated regression에서는 최소 다음을 검증해야 한다.

1. reset 후 CS inactive, SCLK high
2. initialization command/address/data bit 정확성
3. 11개 initialization write 순서
4. address `0x32`부터 시작하는 multi-byte command
5. command 1 byte + data 6 byte 구조
6. transaction 전체 동안 CS assertion
7. transfer window 외 SCLK inactive
8. MOSI bit order
9. recognizable known-pattern MISO reconstruction
10. 정확한 `oSPI_END` terminal timing
11. 이전 transaction 완료 전 새 transaction 금지
12. deterministic reset/clock release
13. ADXL345 serial timing requirement 만족 여부

Known-pattern test에서는 all-zero나 대칭 pattern 대신 X/Y/Z 6 byte가 서로 다른 값을 사용해야 bit/byte-order 오류가 숨지 않는다.

## 16. Baseline Cleanup Targets

### SPI-001 — Private engine과 generic SPI architecture 구분

향후 SoC가 general-purpose SPI를 지원한다고 하려면:

- 현재 G-sensor engine은 private로 명확히 유지하고 별도 generic SPI IP를 설계하거나,
- transport layer를 generic SPI master로 refactor하고 ADXL345 policy layer를 위에 분리해야 한다.

### SPI-002 — Dual-phase PLL timing 제거/정리

승인된 A6은 private ADXL345 engine에 하나의 50 MHz PCLK state clock, clock-enable/tick, registered 외부 SCLK를 사용한다. Reusable SPI는 별도 향후 과제다.

### SPI-003 — CPOL/CPHA 공식 정의 및 verification

현재 idle-high만으로 mode를 단정하지 않는다. Future generic controller에서는 지원 mode를 명시적으로 정의한다.

### SPI-004 — PLL lock/reset policy

PLL을 계속 사용한다면 generated clock valid 여부를 확인한 뒤 controller를 release해야 한다. 또는 PLL dependency 자체를 제거한다.

### SPI-005 — Transaction-level directed verification

16-bit write, 56-bit read, bit order, byte order, CS duration, clock count, known-pattern readback을 검증한다.

### SPI-006 — Sensor policy와 transport 분리

ADXL345 initialization/sampling/axis parsing은 reusable SPI transport controller 내부에 structurally embed하지 않는다.

### SPI-007 — Generic SPI 도입 시 별도 software contract 작성

향후 software-visible generic SPI를 넣는다면 최소 다음을 별도 approved spec으로 정의해야 한다.

```text
base address
control/status
clock divider
CPOL/CPHA
chip-select
TX/RX datapath
FIFO
busy/done/error
interrupt
transfer width
timeout/backpressure
```

현재 baseline에는 이 contract가 없다.

## 17. Non-Goals

이 baseline spec은 다음을 정의하지 않는다.

- generic SPI용 새 APB slot
- future SPI register map
- multiple slave support
- DMA-driven SPI
- FIFO
- SPI Mode 0~3 compliance
- ADXL345 hardware sequence 변경

현행 구현은 그대로이며 아래 Phase 4A-2 cleanup target이 승인된 RTL 구현 architecture다.

## Phase 4A-2 승인된 SPI timing 목표 (현행 RTL 아님)

A6은 50 MHz PCLK 하나만 FSM clock으로 사용하며 clock-enable tick과 registered idle-high 외부 SCLK를 쓴다. Combinational clock gating/active dual-phase `spi_pll`은 없다. SCLK half-period를 12/13 PCLK tick 번갈아 생성하여 full period 25 tick(평균 2 MHz)이다. Private ADXL345 transport는 4-wire, active-low CS, MSB-first, mode 3(CPOL=1/CPHA=1): SCLK high일 때 CS assert, 첫 falling edge 전 setup, falling edge에서 다음 MOSI bit 변경, rising edge에서 MISO sampling, 마지막 sample 후 CS deassert 전 hold를 보장한다. Pin setup/hold 수치는 ADXL345 peer data에 근거해 STA-002에서 닫고 임의 SDC는 만들지 않는다. `GSENSOR_INT` PCLK sync와 XYZ atomic publication/VALID/SEQ는 별도 미완료다.

## Phase 4A-SPI-001 디지털 증거 종료 (2026-09-15)

User/Chat 승인에 따라 현행 tracker의 `SPI-001` 상태는 디지털 transaction/waveform 검증 범위에서 `VERIFIED`다. `verification/directed/models/gsensor/tb_gsensor_single_pclk.sv`와 focused G-sensor 회귀가 mode 3, registered SCLK의 12/13-PCLK half-period, 11개 16-bit 초기화 write, 3개 완전한 56-bit read, MOSI 순서, rising-edge MISO 수집, CS 유지, known-pattern 데이터 및 전송 중 reset 중단·safe idle·재시작을 검증했다. 이 종료에서 합성 RTL·SDC·QSF 변경, Quartus 빌드, 보드 테스트는 없었다. 물리 ADXL345 timing의 `SPI-002`는 `IN_PROGRESS`이며 `GS-005`, `STA-002`, `CDC-002`, `GS-001`은 별도 미완료다.

기존 §16의 “SPI-001” private/generic SPI 논의는 A6 이전 역사 기록으로 보존한다. 현행 tracker의 `SPI-001`은 디지털 파형 검증 행이며 용어 정리는 이후 Full Spec Refresh에서 수행한다.

## P09B ADXL345 transaction 계약 — source/documentation 동시 게시 갱신

> **현행 Public 통합:** 12-write PCLK-only 구현은 P09B source/documentation 동시 commit과 함께 현행 상태가 된다. Historical 11-write 증거는 역사 기록이고 `SPI-002`는 열려 있다.

> **게시 정합성:** 12-write PCLK-only 구현은 대응 source commit과 함께만 게시된다. Historical 11-write 증거는 역사 기록이고 `SPI-002`는 열려 있다.

격리 P09B 후보는 fixed-function PCLK-only mode-3 전송과 전체 56-bit DATAX0..DATAZ1 read를 유지한다. 순서가 고정된 12개 초기화 write는 `(0x24,0x20)`, `(0x25,0x03)`, `(0x26,0x01)`, `(0x27,0x7F)`, `(0x28,0x09)`, `(0x29,0x46)`, `(0x2C,0x09)`, `(0x2F,0x00)`, `(0x2E,0x80)`, `(0x31,0x00)`, `(0x20,0x07)`, `(0x2D,0x08)`이다. 즉 50 Hz DATA_READY를 켜서 INT1으로 map하고 measurement mode를 마지막에 시작한다. 기존 11-write 파형 증거는 역사 기록이며 새 table의 검증 증거가 아니다. 격리 후보에서 controller reset 입력은 historical 추가 2^20-PCLK local delay가 아닌 `PRESETn` 직접 연결이다. 공통 reset release 후 초기화를 시작하고 12개 write와 CS HIGH 완료 이후에만 acquisition/watchdog을 arm한다. 비동기 reset assertion은 SPI를 중단하고 scheduler를 clear하며 동기 release 후 전체 sequence를 재시작한다. 과거 E0/E1 completion이 이후 publish되면 안 된다. 디지털 burst 완료가 새로운 물리 conversion의 증명은 아니다. INT1이 primary trigger이고 30 ms elapsed-PCLK watchdog이 fallback이며 종전의 명목상 8.192 ms idle poll이 아니다. 정확한 coalescing·edge 우선순위·sample publish는 [12_gsensor.ko.md](12_gsensor.ko.md)를 따른다. Stage 1 `NOT_RUN` 표시는 역사 기록이다. 격리 후보에는 focused digital 및 CPU/host 근거가 있지만 sensor supply startup, ADXL345 board timing, 물리 pin 확인은 이 계약 밖에 남고 `SPI-002`는 종료되지 않았다. 이는 통합 승인 전 현재 Public `main`을 갱신하지 않는다.
