# Baseline SoC G-Sensor Subsystem Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/12_gsensor.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. 목적

이 문서는 active DE10-Lite accelerometer / G-sensor subsystem을 정의한다. 범위는 다음과 같다.

- APB-visible register contract
- 고정형 ADXL345 초기화 sequence
- private SPI acquisition path
- X/Y/Z software-visible packing
- acquisition trigger / refresh behavior
- reset / startup behavior
- board interrupt pin과 local sensor controller의 관계
- CDC / sample coherency limitation
- 현재 data reconstruction 불확실성
- verification requirement
- PLIC/AXI 이전 baseline cleanup target

현재 subsystem은 **generic software-programmable SPI controller가 아니다**. Software는 두 개의 APB read register로 accelerometer sample만 읽으며, sensor initialization과 SPI traffic은 dedicated hardware가 담당한다.

## 2. Active RTL 경계

Active wrapper:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
```

Private implementation:

```text
rtl/peripherals/gsensor/v/reset_delay.v
rtl/peripherals/gsensor/v/adxl345_controller.v
rtl/peripherals/gsensor/v/SPI_MASTER.v
rtl/peripherals/gsensor/v/spi_param.h
비공개 vendor-project vault: spi_pll generated IP (public tree에 없음)
```

Top-level path:

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
 APB_GSENSOR_MB                       PCLK 50 MHz
       |
       +--> reset_delay
       +--> spi_pll
       |      +--> spi_clk            2 MHz
       |      +--> spi_clk_out        2 MHz, phase shifted
       |
       +--> spi_ee_config
                  |
                  +--> spi_controller
                  +--> GSENSOR_CS_N / SCLK / SDI
                  +<-- GSENSOR_SDO
                  +<-- GSENSOR_INT[1]
```

Canonical base:

```text
GSENSOR_BASE = 0x4003_0000
PSEL         = PSEL[3]
```

`PREADY=1` 고정이며 active baseline에는 CPU interrupt output이 없다.

## 3. Canonical APB Register Map

| Offset | Register | Access | Data |
|---:|---|---|---|
| `0x00` | `GSENSOR_XY_DATA` | R | `[31:16]=X`, `[15:0]=Y` |
| `0x04` | `GSENSOR_Z_DATA` | R | `[31:16]=0`, `[15:0]=Z` |

`0x08`, `0x0C` read는 local decode에서 0을 반환한다.

현재 wrapper에는 control, status, ready, error, timestamp, sample counter register가 없다.

### 3.1 Write behavior

G-sensor function은 APB write를 구현하지 않는다. 선택된 slot에 write해도 `PREADY=1`로 transaction은 완료되지만 sensor state는 변하지 않고 error도 발생하지 않는다.

따라서 software contract는 **read-only**이다.

### 3.2 Register mirror

Local decode는 `PADDR[3:2]`만 보므로 16-byte마다 register pattern이 반복된다. 이 alias는 implementation artifact이며 canonical address가 아니다.

Normative access는 aligned 32-bit read만 허용한다.

## 4. Sample Format

```text
+0x00
31                    16 15                     0
+-----------------------+-----------------------+
|        X[15:0]        |        Y[15:0]        |
+-----------------------+-----------------------+

+0x04
31                    16 15                     0
+-----------------------+-----------------------+
|          0            |        Z[15:0]        |
+-----------------------+-----------------------+
```

RTL comment는 X/Y/Z를 signed 16-bit two's-complement 값으로 취급한다. Signed arithmetic에서는 각 16-bit field를 sign extension해서 사용해야 한다.

다만 현재 baseline spec은 mg/LSB 같은 physical-unit conversion을 normative contract로 정의하지 않는다. 해당 conversion은 ADXL345 configuration 및 datasheet contract를 검증한 뒤 별도 확정한다.

## 5. Fixed Hardware Initialization

Local reset release 후 `spi_ee_config`가 다음 11개의 고정 write를 수행한다.

| Index | Register | Address | Value |
|---:|---|---:|---:|
| 0 | `THRESH_ACT` | `0x24` | `0x20` |
| 1 | `THRESH_INACT` | `0x25` | `0x03` |
| 2 | `TIME_INACT` | `0x26` | `0x01` |
| 3 | `ACT_INACT_CTL` | `0x27` | `0x7F` |
| 4 | `THRESH_FF` | `0x28` | `0x09` |
| 5 | `TIME_FF` | `0x29` | `0x46` |
| 6 | `BW_RATE` | `0x2C` | `0x09` — RTL comment 기준 50 Hz |
| 7 | `INT_ENABLE` | `0x2E` | `0x00` |
| 8 | `INT_MAP` | `0x2F` | `0x00` |
| 9 | `DATA_FORMAT` | `0x31` | `0x00` |
| 10 | `POWER_CONTROL` | `0x2D` | `0x08` |

Software는 현재 APB interface로 이 설정을 변경할 수 없다.

## 6. Acquisition Trigger

초기화 완료 후 controller는 반복 read loop로 진입한다.

새 burst read 시작 조건은:

```text
GSENSOR_INT[1] high
또는
read_idle_count[14] == 1
```

이다.

내부 port 이름은 `iG_INT2`이지만 wrapper는 `GSENSOR_INT[1]`을 연결한다. 따라서 현재 이름만 보고 실제 ADXL INT2 pin 사용이라고 판단하면 안 된다. Pin mapping/naming은 cleanup에서 다시 검증해야 한다.

### 6.1 Periodic fallback

Active parameter:

```text
IDLE_MSB = 14
read_idle_count[14:0]
spi_clk = 2 MHz
```

bit 14는 zero start 기준 16,384 increment 후 1이 되므로 nominal fallback interval은:

```text
16,384 / 2 MHz
= 8.192 ms
```

이다.

RTL comment의 `16.384 ms`, bit 15 설명은 active implementation과 맞지 않는다. 현재 구현 기준 값은 약 **8.192 ms**이다.

한편 `BW_RATE=0x09`는 RTL comment상 50 Hz이므로 SPI polling이 sensor data update보다 빠를 수 있다. 같은 sample을 여러 번 읽는 것은 현재 구조상 가능하다.

### 6.2 Burst read

Read command는:

```text
{2'b11, X_LB}
X_LB = 0x32
```

즉 multi-byte read command를 만들고, `DATAX0`부터 6-byte를 읽는 56-bit transaction을 수행한다.

CPU가 SPI transaction을 직접 시작하지 않는다.

## 7. Private SPI

Dedicated interface:

```text
GSENSOR_CS_N  active-low chip select
GSENSOR_SCLK  serial clock
GSENSOR_SDI   FPGA -> sensor
GSENSOR_SDO   sensor -> FPGA
```

`spi_pll`은 50 MHz에서 nominal 2 MHz clock 두 개를 만든다. `spi_clk`은 controller/sampling logic에, phase-shifted `spi_clk_out`은 gated external SCLK 생성에 사용된다.

현재 SPI engine은 sensor initialization 16-bit write와 56-bit multi-byte read에 특화되어 있으며 generic APB SPI master가 아니다.

## 8. Reset / Startup

System `PRESETn` 이후 wrapper는 `reset_delay`를 추가한다.

```text
2^20 PCLK cycles
= 1,048,576 cycles
= 20.97152 ms @ 50 MHz
```

이 기간에는:

```text
spi_pll areset = 1
spi_ee_config iRSTN = 0
```

이다.

Delay 종료 시 PLL reset과 controller reset이 동시에 release된다. 현재 baseline은 PLL `locked` output을 사용하지 않으므로 controller start 전에 lock 확인을 하지 않는다.

### 8.1 Sample register reset 문제

`out_acc_x/y/z`는 `spi_ee_config` reset branch에서 명시적으로 초기화되지 않는다.

따라서 첫 burst read 완료 전 APB read 값은 valid architectural sample로 취급할 수 없다. 하지만 현재 APB에 VALID/READY bit가 없어서 software가 첫 valid sample 시점을 알 방법도 없다.

## 9. `gsensor_ready` 미노출

Controller 내부에는 `gsensor_ready` output이 존재하며 successful read completion 시 내부 SPI clock domain에서 assert된다.

하지만 `APB_GSENSOR_MB`는 이 signal을 연결하거나 APB status로 노출하지 않는다.

현재 software-visible interface에는:

```text
sample_ready     없음
sample_valid     없음
sample_sequence  없음
sample_timestamp 없음
```

이다.

향후에는 이 completion 정보를 PCLK-domain safe snapshot/valid handshake로 재설계해야 한다.

## 10. CDC / Sample Coherency

`out_acc_x/y/z`는 2 MHz `spi_clk` domain에서 update되며, APB wrapper는 이를 50 MHz `PCLK` domain에서 synchronizer 없이 직접 조합 read한다.

현재 없는 것:

- multi-bit CDC handshake
- destination snapshot register
- async FIFO
- sample version/sequence
- atomic XYZ capture

따라서 update 시점과 APB read가 겹치면 metastability 또는 torn multi-bit sample 가능성이 있다.

또한 X/Y는 한 word지만 Z는 다음 APB transaction에서 읽기 때문에, CDC를 고친 뒤에도 coherent XYZ를 보장하려면 snapshot contract가 필요하다.

## 11. Current Data Reconstruction

현재 controller의 active extraction은:

```text
X = {s2p_data[38:31], s2p_data[46:39]}
Y = {s2p_data[22:15], s2p_data[30:23]}
Z = {s2p_data[6:0], 1'b0, s2p_data[14:7]}
```

이다.

X/Y는 8+8 bit 조합이지만 Z는 7 bit + inserted zero + 8 bit로 비대칭이다. RTL comment 자체도 receive-shift indexing 확인 필요성을 적고 있으므로 이 mapping은 **directed verification이 필요한 현재 implementation behavior**로 취급한다.

Software에서 임의 보정하지 말고 known-pattern SPI test로 RTL mapping을 검증한 뒤 필요하면 RTL과 spec을 함께 수정한다.

## 12. Interrupt Architecture와의 관계

현재 G-sensor는 CPU/PLIC interrupt source가 아니다.

Board interrupt input은 private acquisition trigger로만 사용된다. 또한 initialization에서:

```text
INT_ENABLE = 0x00
```

을 쓰므로 current reconstructed baseline에서는 periodic fallback counter가 dependable acquisition trigger이다.

향후 G-sensor IRQ를 추가하려면 physical pin, event source, sync, level/edge, masking, PLIC ID, ack/clear, sample-ready relation을 새 spec으로 정의해야 한다.

## 13. APB Timing

`PREADY=1` 고정 zero-wait slave이며 `PRDATA`는 selected APB ACCESS read 동안 combinational이다.

SPI가 동작 중이어도 APB는 stall되지 않는다. 따라서 APB read completion은 새로운 sensor acquisition 완료를 의미하지 않는다.

## 14. Firmware Contract

현재 firmware는 다음 규칙을 따라야 한다.

1. `GSENSOR_BASE + 0x00`, `+0x04` aligned 32-bit read만 사용한다.
2. Register는 read-only로 취급한다.
3. Signed 사용 시 16-bit axis를 sign extension한다.
4. 매 read가 new sample이라고 가정하지 않는다.
5. X/Y와 Z가 atomic snapshot이라고 가정하지 않는다.
6. 첫 valid sample 이전 값을 measurement로 사용하지 않는다.
7. APB write로 sensor configuration이 바뀐다고 가정하지 않는다.
8. sensor interrupt pin을 CPU interrupt로 취급하지 않는다.
9. Canonical offset 외 alias를 사용하지 않는다.

현재 dedicated production firmware driver는 valid/snapshot contract를 따로 제공하지 않는다.

## 15. Verification Requirements

최소 검증 항목:

- `+0x00`, `+0x04` APB read
- wrapper packing
- write 무효 동작
- `PREADY=1`
- local reset delay
- 11개 initialization write 순서/값
- init -> repeated read 전이
- ~8.192 ms fallback trigger
- 56-bit burst command/length
- known-pattern X/Y/Z byte-order test
- asymmetric Z reconstruction
- first-sample validity
- APB read 중 sample update
- sensor interrupt input vs fallback
- CPU/PLIC interrupt 부재

Board acceptance에서는 여러 방향으로 보드를 두고 X/Y/Z polarity와 magnitude plausibility를 별도 확인해야 한다. Quartus build 성공만으로 sensor function을 입증할 수 없다.

## 16. Baseline Cleanup Targets

| Priority | Cleanup target | 방향 |
|---|---|---|
| High | `spi_clk -> PCLK` multi-bit CDC | handshake/snapshot/async FIFO 등 CDC-safe 구조 도입 |
| High | sample valid/ready 미노출 | synchronized VALID/READY 또는 sequence mechanism 추가 |
| High | X/Y/Z reconstruction 미검증 | known-pattern test 후 특히 Z extraction 수정 여부 결정 |
| High | atomic XYZ snapshot 없음 | coherent snapshot contract 설계 |
| High | PLL lock 미사용 | generated-clock/reset release policy 확정 |
| Medium | 16.384 ms stale comment | active bit14 / 8.192 ms 기준으로 정리 또는 rate generator 재설계 |
| Medium | 50 Hz ODR와 faster polling mismatch | intended acquisition rate 정의 |
| Medium | `GSENSOR_INT[1]` / `iG_INT2` naming mismatch | physical pin mapping 검증 및 naming 정리 |
| Medium | `INT_ENABLE=0`인데 interrupt-trigger path 존재 | timer/data-ready/hybrid policy 결정 |
| Medium | sample regs reset 안 됨 | deterministic reset 또는 VALID gating |
| Medium | software configuration interface 없음 | fixed init 유지 여부 결정 |
| Low | 16-byte register mirror | local decode 강화 |
| Low | unused APB write/debug interface | interface cleanup |

## 17. Baseline Invariants

1. G-sensor canonical base는 `0x4003_0000`, APB slot 3이다.
2. Software-visible G-sensor interface는 read-only다.
3. `+0x00`은 X[31:16], Y[15:0]이다.
4. `+0x04`는 Z[15:0], upper halfword 0이다.
5. Sensor initialization은 firmware가 아니라 hardware가 수행한다.
6. Private SPI는 generic software-visible APB SPI controller가 아니다.
7. 현재 sensor controller는 nominal 2 MHz generated clocks를 사용한다.
8. Fallback read trigger는 `read_idle_count[14]`, nominal ~8.192 ms이다.
9. APB에는 valid/ready/timestamp/sequence가 없다.
10. Active CPU에는 G-sensor interrupt source가 없다.
11. Direct multi-bit `spi_clk -> PCLK` crossing은 known cleanup item이다.
12. Sample reconstruction correction은 RTL verification과 spec update 없이 문서에서 임의로 바꾸지 않는다.

## Phase 4A-2 승인된 G-sensor clock 목표 (현행 RTL 아님)

A6은 private ADXL345 sequence와 software-visible APB contract를 유지하되 SPI FSM 전체가 50 MHz PCLK에서 clock-enable tick으로 동작하고 외부 SCLK는 registered logic으로 생성한다. 현행 dual-phase `spi_pll`은 cleanup 경로에서 비활성이나 역사적 private IP는 삭제하지 않는다. 4-wire, CS-low, MSB-first, mode 3(CPOL=1/CPHA=1), 약 2 MHz를 유지한다. 비동기 `GSENSOR_INT`는 PCLK 동기화가 필요하다. SPI domain 제거만으로 atomic XYZ/VALID/SEQ/GS-001/CDC-002가 검증 완료되는 것은 아니다. 위 PLL 설명은 현행 baseline 한정이다.
