# Baseline SoC G-Sensor Subsystem Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/12_gsensor.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

> **현행 A6 clocking:** 현재 G-sensor RTL에는 `spi_pll` instance나 내부 SPI clock domain이 없다. Controller·sample register·APB wrapper는 50 MHz PCLK를 사용하고 외부 mode-3 SCLK는 registered output이다. 아래의 과거 PLL/CDC 설명은 현행 결함이 아니다. 별도 APB read 사이의 atomic XYZ snapshot과 software-visible VALID/SEQ는 아직 없다.

> **P09B Public 통합 상태:** Public P09B 구현은 마지막 절의 LIVE/HOLD/VALID/SEQ ABI, 12회 초기화, INT1/30 ms scheduler 및 direct shared reset을 제공한다. Focused/CPU/host evidence, fresh private fit/STA 및 한 건의 board display 관측은 있으나 외부 timing/electrical, 물리 INT1/orientation, calibration 및 명시적으로 남긴 NOT_RUN 항목은 열려 있다.

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

현행 project-owned 구현:

```text
rtl/peripherals/gsensor/reset_delay.v
rtl/peripherals/gsensor/spi_ee_config.v
```

과거 `adxl345_controller.v`, `SPI_MASTER.v`, `spi_param.h` 및 private vault의 `spi_pll`은 현행 public G-sensor source/FPGA binding에 속하지 않는다.

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
       +--> spi_ee_config             PCLK 기반 고정형 ADXL345 controller
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
poll_div_count = poll_count 증가당 25 PCLK (과거 11-write acquisition policy)
```

bit 14는 zero start 기준 16,384 increment 후 1이 되므로 nominal fallback interval은:

```text
16,384 × 25 / 50 MHz
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

현행 controller와 sample register는 50 MHz PCLK만 사용한다. Registered mode-3 `GSENSOR_SCLK`의 high/low 반주기는 각각 12/13 PCLK로, nominal 2 MHz 외부 serial clock을 만든다. 이는 내부 clock이 아니다. 과거 dual-phase `spi_pll`은 현행 wrapper instance나 Quartus binding에 없다.

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
spi_ee_config iRSTN = 0
```

이다.

Delay 종료 시 controller reset만 release된다. 현행 경로에는 G-sensor PLL reset이나 `locked` signal이 없다.

### 8.1 Sample register reset 문제

현행 `spi_ee_config`는 reset branch에서 `out_acc_x/y/z`를 명시적으로 0으로 초기화한다.

따라서 첫 burst 완료 전 APB read는 결정적인 0을 반환하지만 valid sensor sample은 아니다. 현재 APB에는 VALID/READY bit가 없어 software가 첫 valid sample을 판별할 수 없다.

## 9. `gsensor_ready` 미노출

Controller의 registered `gsensor_ready`는 전체 read transaction 완료 시 PCLK domain에서 assert된다.

하지만 `APB_GSENSOR_MB`는 이 signal을 연결하거나 APB status로 노출하지 않는다.

현재 software-visible interface에는:

```text
sample_ready     없음
sample_valid     없음
sample_sequence  없음
sample_timestamp 없음
```

이다.

P09B는 이 PCLK-domain completion을 한 edge 뒤에 받아 coherent LIVE publish와 software-visible snapshot/valid 계약에 사용한다.

## 10. Sample Coherency (현행 내부 SPI-to-PCLK CDC 없음)

과거 multi-bit `spi_clk`→PCLK crossing은 A6에서 제거됐다. 현행 `out_acc_x/y/z`는 완료 burst 후 50 MHz PCLK domain에서 함께 갱신되고 APB wrapper는 이를 조합 read한다. 남은 문제는 내부 CDC가 아니라 software-visible snapshot 경계다.

현재 없는 것:

- destination snapshot register
- sample version/sequence
- atomic XYZ capture

내부 SPI-to-PCLK crossing에 따른 multi-bit metastability 주장은 현행 RTL에 해당하지 않는다. 하지만 update 경계의 read와 별도 APB word read에는 coherent CPU snapshot 계약이 없다.

X/Y는 한 word지만 Z는 다음 APB transaction에서 읽고 그 사이 LIVE가 refresh될 수 있다. 한 세대 XYZ 보장에는 명시적인 HOLD snapshot이 필요하다.

## 11. Current Data Reconstruction

현재 A6 controller는 전체 56-bit burst 후 완료된 6-byte data에서 다음 full-byte extraction을 등록한다:

```text
X = {completed_rx[39:32], completed_rx[47:40]}
Y = {completed_rx[23:16], completed_rx[31:24]}
Z = {completed_rx[7:0], completed_rx[15:8]}
```

이다.

세 축 모두 ADXL345 low-byte-first의 완전한 두 byte를 사용하며 project-owned `spi_ee_config.v`가 완료 시 XYZ를 함께 등록한다. 기존 `GS-002`의 `X=0x1234, Y=0x5678, Z=0x9ABC` known-pattern digital 증거는 byte reconstruction에 한정되며 물리 orientation이나 별도 APB read의 원자성을 입증하지 않는다.

**과거 pre-A6 reference 한정:** `Z={s2p_data[6:0],1'b0,s2p_data[14:7]}`의 inserted-zero Z 알고리즘은 현행 A6 RTL이나 현재의 미해결 Z-bit 결함이 아니다. Software bit 보정은 필요 없으며 P09B 변경 후 실제 full-byte reconstruction을 독립적으로 재검증해야 한다.

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
- full-byte signed/asymmetric known-pattern XYZ reconstruction (과거 inserted-zero Z는 비활성)
- first-sample validity
- APB read 중 sample update
- sensor interrupt input vs fallback
- CPU/PLIC interrupt 부재

Board acceptance에서는 여러 방향으로 보드를 두고 X/Y/Z polarity와 magnitude plausibility를 별도 확인해야 한다. Quartus build 성공만으로 sensor function을 입증할 수 없다.

## 16. Baseline Cleanup Targets

| Priority | Cleanup target | 방향 |
|---|---|---|
| 과거, A6 해결 | `spi_clk -> PCLK` multi-bit CDC | PCLK-only controller로 제거; 별도 LIVE/HOLD coherency 목표는 유지 |
| High | sample valid/ready 미노출 | synchronized VALID/READY 또는 sequence mechanism 추가 |
| 과거, GS-002 VERIFIED | X/Y/Z byte reconstruction | A6 full-byte extraction의 제한된 known-pattern digital 검증 완료; P09B 회귀에서 보존, 물리 정확성 주장은 금지 |
| High | atomic XYZ snapshot 없음 | coherent snapshot contract 설계 |
| 과거, A6 해결 | G-sensor PLL lock 미사용 | 현행 G-sensor PLL 및 generated-clock reset/lock 경로 없음 |
| Medium | 16.384 ms stale comment | active bit14 / 8.192 ms 기준으로 정리 또는 rate generator 재설계 |
| Medium | 50 Hz ODR와 faster polling mismatch | intended acquisition rate 정의 |
| Medium | `GSENSOR_INT[1]` / `iG_INT2` naming mismatch | physical pin mapping 검증 및 naming 정리 |
| Medium | `INT_ENABLE=0`인데 interrupt-trigger path 존재 | timer/data-ready/hybrid policy 결정 |
| Medium | reset 0과 validity 구분 불가 | A6에서 sample regs는 0으로 reset; P09B에서 VALID 노출 필요 |
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
7. 현행 sensor controller는 50 MHz PCLK만 사용하고 nominal 2 MHz 외부 SCLK를 registered logic으로 생성한다.
8. Fallback read trigger는 `read_idle_count[14]`, nominal ~8.192 ms이다.
9. APB에는 valid/ready/timestamp/sequence가 없다.
10. Active CPU에는 G-sensor interrupt source가 없다.
11. 현행 내부 `spi_clk -> PCLK` crossing은 없고, XY/Z의 coherent CPU readout은 남은 cleanup item이다.
12. 현행 `completed_rx` full-byte reconstruction은 실제 source 계약이며 RTL 수정에는 새 검증과 명세 갱신이 필요하다.

## Historical A6 구현/증거 현황

A6 증거 시점에는 fixed-function ADXL345 FSM과 X/Y/Z 결과 register가 모두 50 MHz PCLK에서 동작하고 외부 SCLK는 registered mode-3 logic으로 생성됐다(12/13-PCLK half-period, 25 PCLK/SCLK cycle). 과거 dual-phase `spi_pll`은 private vault에 남지만 당시 wrapper instance와 Quartus binding에는 없었다. `GSENSOR_INT[1]`은 2-flop PCLK synchronizer를 통과했다. 기존 11-write 초기화, 56-bit read, APB packing과 `PREADY=1`은 유지됐다. 이 문단은 pinned A6 사실을 보존하는 것이며 아래 P09B 후보 계약을 뜻하지 않는다.

## P09B 최종 구현 및 제한된 증거 — source/documentation 동시 게시 갱신

> **현행 Public 통합:** 이 구현은 P09B source/documentation 동시 commit과 함께 현행 상태가 된다. 이전 후보 표현은 게시 전 provenance 기록일 뿐이며 제한된 증거는 물리 acceptance나 남은 NOT_RUN을 승격하지 않는다.

> **게시 정합성:** 아래 구현은 source/documentation 동시 commit이 게시될 때만 Public 계약이 된다. 제한된 증거는 물리 acceptance나 남은 NOT_RUN을 승격하지 않는다.

P09B Public 구현은 이 문서의 최종 P09B 계약, 즉
direct shared `PRESETn`, 순서 있는 12회 초기화, INT1-trigger/30 ms fallback
acquisition 및 LIVE/HOLD/VALID/SEQ APB ABI를 구현한다. 이 후보에 대해서는
focused/host/CPU checker 증거, fit/STA 검토 및 한 건의 board-display 관측이
있다. 이는 Public `main` 구현 주장이 아니며, 물리 INT1/orientation/calibration,
외부 timing 또는 남겨진 NOT_RUN 음성 검사를 PASS/종료로 바꾸지 않는다.

## Historical Stage 1 목표/증거 (당시 기준) — 현 후보 상태와 분리

### Reset 소유권과 중단된 transaction 경계

Stage 1 당시 pinned A6 source에는 reset qualification이 두 단계였고, 당시
P09B 목표에는 공통 system qualification만 있었다. 아래 절은 그 당시의
명세/증거 경계를 보존한 것이며, 위 P09B 후보가 미구현이었다는 뜻이 아니다.

| 경로/소유자 | 현행 pinned A6 | 별도 RTL 승인 후 P09B 목표 |
|---|---|---|
| `KEY[0]` → system | LOW에서 `system_reset_controller` 비동기 assert; 2개 HCLK flop 후 1,000,000개 qualified 50 MHz edge(~20 ms)로 release | 변경 없음 |
| SoC/bridge/APB | top `HRESETn=PRESETN_SYS`; bridge `PCLK=HCLK`, `PRESETn=HRESETn` | 변경 없음 |
| G-sensor controller | wrapper `reset_delay(PRESETn,PCLK)`가 `iRSTN=!dly_rst`를 추가 2^20 PCLK(~20.97152 ms) 유지; 버튼 해제 후 약 41 ms+동기화에 초기화 시작 | `spi_ee_config.iRSTN`을 wrapper `PRESETn`에 **직접 연결**; 두 번째 timer/generated reset/새 clock domain 없음 |
| LIVE/HOLD/scheduler | 미구현 | XYZ/SEQ/VALID, IRQ synchronizer/history, pending request, watchdog 모두 같은 `PRESETn` 사용 |

Stage 2 승인 시 `reset_delay` **instance**와 obsolete wrapper `RESET_DELAY_BITS` parameter를 제거하는 목표이며 Stage 1에서 `reset_delay.v`는 수정·삭제하지 않는다. 공통 system reset controller, bridge, 다른 consumer는 바꾸지 않는다. 공통 reset release 후 controller는 정확히 12개의 순서 있는 SPI 초기화 write를 시작하고, 11번 `POWER_CTL` write 완료와 CS HIGH 이후에만 acquisition/IRQ 인식·watchdog을 arm한다. 이는 측정된 기동 시간이 아닌 목표 순서다. [ADXL345 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adxl345.pdf)는 두 supply가 있어야 bus 사용이 가능하고 standby에서 configuration 후 measurement enable을 권장한다. POWER_CTL-last는 그 권고를 따른다. 공통 reset만으로 20 ms 안에 sensor rail이 준비됐다고 **입증할 수 없으므로** ramp, bus electrical availability, 초기화 및 첫 DATA_READY 동작은 별도 물리 검증이 필요하다.

정상 APB transaction은 공통 reset이 deassert된 동안만 유효하다. **비동기 assertion은** SETUP, ACCESS, CAPTURE, E0/E1, SPI shift와 겹칠 수 있다. Assertion은 진행 중 bus/sensor operation을 중단하고 bank/command state보다 우선한다. Reset 전에 완료되지 않은 read는 **유효 반환값·완료 보장이 없고 accepted transfer로 세지 않는다**. 이미 완료된 read는 과거 완료로 남는다. 중단된 transfer에 대해 실제 bridge/CPU reset 동작 이상의 특정 AHB ERROR/OKAY를 약속하지 않는다. Assert 중 LIVE/HOLD는 zero/invalid이고 초기화·acquisition은 중단된다. 동기 release 후 APB 접근은 가능하지만 첫 새 digital burst 완료 전 두 VALID는 0이고, HOLD는 이후 성공 CAPTURE 전까지 invalid다. Clock edge와 겹친 reset assert는 비동기 경계이며 평상시 pre-edge STATUS/HOLD read linearization 규칙이 아니다.

| Reset/transaction 순서 | 계약 / 독립 확인 |
|---|---|
| Read 완료 후 reset assert | 이전 값은 유효한 과거 완료이며 이후 두 bank clear |
| Read 완료 전 reset assert (SETUP/ACCESS 포함) | 중단; accepted read/command 없음, read 값·완료 보장 없음 |
| CAPTURE/RELEASE 또는 E0/E1에 reset 겹침 | reset 우선; 과거 HOLD ownership, LIVE generation, old burst의 release 후 publish 없음 |
| 56-bit SPI 중 reset | transfer 중단, pin safe idle, scheduler clear, 공통 release 후 12-write 초기화 재시작 |
| HOLD 점유 중 reset | HOLD XYZ/SEQ/VALID와 LIVE clear; 기존 owner가 stale data 반환하거나 무소유 RELEASE 실행 금지 |

### Bank 소유권, digital sample identity, 이벤트 우선순위

P09 목표는 단일 50 MHz PCLK와 고정 역할 bank 두 개다. LIVE `{x,y,z,seq[31:0],valid}`는 생산자 소유로 HOLD 상태와 무관하게 계속 갱신된다. HOLD `{x,y,z,seq[31:0],valid}`는 CPU 소유이며 성공한 CAPTURE부터 RELEASE 또는 reset까지 변하지 않는다. FIFO 및 중간 모든 burst 세대의 보존 보장은 없다. 로컬에서 56-bit SPI read가 끝난 것이 **digital burst 완료**이며 sensor ACK/CRC/device ID나 새로운 물리 변환의 증거는 아니다.

E0에서 controller는 마지막 rising sample edge에 NBA로 X/Y/Z와 `gsensor_ready=1`을 함께 등록한다. 별도 wrapper 순차 블록은 E0에서 이전 ready를 보고, E1에서 ready=1과 안정된 XYZ를 본다. **E1의 단일 `sample_complete`**에서 LIVE XYZ 복사, SEQ 증가, VALID set을 함께 한다. E0의 별도 controller SEQ는 금지한다. Reset에서 양쪽 bank의 XYZ/SEQ/VALID는 모두 0이다. 첫 완료 seq=1, 이후 digital burst마다 값이 같거나 watchdog 재읽기라도 modulo 2^32로 1 증가한다. wrap된 seq=0도 valid일 수 있다.

STATUS bit0 LIVE_VALID는 “마지막 **성공 CAPTURE 이후 미소비 digital 완료 burst가 있음**”이고 lifetime initialization flag가 아니다. bit1 HOLD_VALID는 HOLD가 점유됐다는 뜻이다. `C = legal CAPTURE ACCESS 완료 && pre-edge LIVE_VALID && !pre-edge HOLD_VALID`, `E = E1 sample_complete`로 정의한다. reset 외에는 `live_valid_next = (pre_live_valid && !C) || E`이다. C 성공 시 **pre-edge** LIVE XYZ+SEQ를 HOLD에 원자 복사하고 HOLD_VALID를 set한다. LIVE invalid 또는 HOLD 점유 상태의 CAPTURE는 OKAY/no-op이며 LIVE pending도 지우지 않는다. E+C 동시에는 이전 LIVE를 HOLD에 담고 새 burst를 LIVE에 게시하며 LIVE_VALID=1로 남긴다. pre-edge LIVE invalid면 CAPTURE는 no-op이고 E가 pending을 set한다. RELEASE는 HOLD XYZ/SEQ/VALID를 모두 0으로 만들고 LIVE는 건드리지 않는다. E+RELEASE에서는 독립적으로 LIVE가 게시된다. Reset이 모든 이벤트와 세션보다 우선한다.

| edge/전송 | 다음 LIVE | 다음 HOLD | 관측 결과 |
|---|---|---|---|
| reset assert | XYZ=0, seq=0, valid=0 | XYZ=0, seq=0, valid=0 | pending/소유권 취소 |
| E 단독 | source XYZ, seq+1, valid=1 | 불변 | digital 세대 1회 |
| 적격 C 단독 | XYZ/seq 불변, valid=0 | pre-edge LIVE XYZ/seq, valid=1 | 원자 snapshot |
| 부적격 C | 불변 | 불변 | OKAY/no-op |
| E+C, 이전 LIVE valid/HOLD empty | source XYZ, seq+1, valid=1 | 이전 LIVE XYZ/seq, valid=1 | pending clear보다 event 우선 |
| E+C, 이전 LIVE invalid 또는 HOLD occupied | source XYZ, seq+1, valid=1 | 불변 | C no-op, event 보존 |
| RELEASE, E 유무 무관 | E가 있으면 게시, 없으면 불변 | XYZ=0, seq=0, valid=0 | 멱등 OKAY |
| 잘못된 SNAP_CTRL, E 유무 무관 | E가 있으면 게시, 없으면 불변 | 불변 | ERROR, command 효과 없음 |
| E와 동시 STATUS read | edge 후 E 게시 | 불변 | read는 **pre-edge** state, 다음 read부터 E 관측 |

STATUS read는 side effect가 없고 동시 E를 즉시 forwarding/bypass하지 않는다. Reset이 deassert된 정상 ACCESS 종료 edge의 조합 PRDATA는 pre-edge 등록 상태이므로 동시 E에서 0을 반환해도 edge 후 LIVE_VALID=1이다. 이후 read가 이를 본다. same-edge forwarding은 추후 미구현 engineering optimization일 뿐 AC가 아니다. HOLD read 역시 정상 command collision에는 pre-edge state를 관측하지만, 비동기 reset assertion은 위의 중단 transaction 규칙을 따른다.

### APB ABI 및 오류

base `0x4003_0000`, `PSEL[3]`, 정확한 offset의 정렬된 32-bit 접근만 허용한다. Bridge의 slot-3 full-offset allowlist를 기존 `+0x00/+0x04`에서 다음 다섯 offset으로 넓히되 mirror/alias/다른 offset/unsupported size/reserved slot은 real PSEL 이전에 계속 차단한다. 정상 selected transfer는 zero-wait `PREADY=1`이다. Command는 수락된 APB ACCESS 완료에서 정확히 1회 실행하며 SETUP 또는 ACCESS wait 동안 반복되지 않는다. back-to-back ACCESS 완료는 서로 다른 command다.

| Offset | 이름 | Read | Write | invalid/효과 |
|---:|---|---|---|---|
| `+0x00` | HOLD_XY | HOLD_VALID ? `{X[15:0],Y[15:0]}` : `0` | ERROR | read 효과 없음 |
| `+0x04` | HOLD_Z | HOLD_VALID ? `{16'b0,Z[15:0]}` : `0` | ERROR | read 효과 없음 |
| `+0x08` | STATUS | `{30'b0,HOLD_VALID,LIVE_VALID}` | ERROR | side-effect-free, pre-edge |
| `+0x0C` | HOLD_SEQ | HOLD_VALID ? HOLD_SEQ : `0` | ERROR | seq=0도 valid 가능 |
| `+0x10` | SNAP_CTRL | ERROR | 정확히 `32'h1` CAPTURE, `32'h2` RELEASE | 0, 3, reserved bit: ERROR/command 효과 없음 |
| 그 외/noncanonical | 없음 | ERROR | ERROR | bank/command 효과 없음 |

표에 있는 RO write/WO read와 잘못된 command encoding은 wrapper `PSLVERR`를 completing ACCESS에서 내고, top이 현재 low로 tie한 bridge `PSLVERR` 입력까지 연결해야 한다. Bridge는 이를 2-cycle AHB ERROR(`HRESP=01,HREADY=0` 후 `HRESP=01,HREADY=1`)로 바꾼다. 이는 현재 G-sensor end-to-end 구현이 아니라 **목표**다. 부적격이나 empty HOLD에 대한 올바른 command는 ERROR가 아닌 OKAY/no-op이다. invalid HOLD readback은 0이지만 0 data/seq만으로 invalid를 판정하면 안 된다. Generic SPI/config write, CPU/PLIC IRQ는 추가하지 않는다. 앞의 “G-sensor read-only/write no-op OKAY” 문구는 P09 이전 source 기록이며 P09 ABI로 쓰지 않는다.

### 고정 sensor 초기화 및 trigger scheduler

역사적 재배포 제한 `spi_param.h`를 복사하지 않고 project-owned 상수로 다음 **12개** 16-bit SPI write를 순서대로 정확히 1회 수행한다. INT_MAP을 INT_ENABLE보다 앞에, OFSZ를 POWER_CTL보다 앞에 두고 POWER_CTL을 **마지막**으로 한다. `BW_RATE=0x09`는 nominal 50 Hz normal-power ODR, `INT_MAP=0`은 DATA_READY→INT1, `INT_ENABLE=0x80`은 해당 출력 enable, `DATA_FORMAT=0`은 기본 ±2 g/right-justified다. `OFSZ=+7`은 약 **+109 mg**(7 × 15.6 mg), 기본 ±2 g 출력에서 약 28 count에 해당하며 +28 mg이 아니다. 보드별 calibration 적합성은 별도 검증한다.

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

현재 top `G_SENSOR_INT[1]`→wrapper `GSENSOR_INT[1]`→controller `iG_INT2`로 연결된다. 마지막 포트명은 오해를 부른다. Public pin assignment에서 index 1은 `PIN_Y14`이고 DE10-Lite manual에서 Y14는 **INT1**(index 2/Y13은 INT2)이다. source/document 일치가 보드 전기/파형 시험을 대신하지 않는다. ADXL345 DATA_READY는 축 데이터 레지스터 읽기로 clear되며 기존 DATAX0..DATAZ1 56-bit burst가 의도된 clear 경로다. 동기화된 HIGH level을 매 PCLK 새 이벤트로 취급하면 안 되고 2FF에 들어오지 못하는 짧은 pulse는 검출 보장이 없다.

목표 scheduler(단일 pending slot, FIFO 아님): 12번째 초기화 write가 완전히 끝나 CS high가 된 edge에서 acquisition arm 및 elapsed-PCLK count=0. **다음** PCLK edge에 동기화 INT1이 이미 high이면 1회 인정한다. arm 상태에서 synchronized high를 IRQ로 인정하면 synchronized LOW가 보일 때까지 재인정을 금지하고, LOW 뒤 rearm한다. SPI busy 중 새로운 LOW→HIGH를 인정하면 단일 pending slot으로 합치며 추가 이벤트도 coalesce한다. 이는 물리 DATA_READY pulse마다 burst 1회 보장이 아니다. 인정된 IRQ는 busy 중에도 그 edge에서 watchdog을 재시작하지만 붙들린 HIGH는 반복 재시작하지 않는다.

Watchdog은 SPI busy 시간도 포함해 독립적으로 PCLK edge를 센다. arm/restart edge에서 elapsed=0, 그 후 **1,500,000번째 rising edge**가 30 ms threshold(50 MHz)이고 1,499,999번째는 아니다. 그때 eligible IRQ가 없으면 fallback read 한 건을 요청한다. busy라면 FALLBACK 한 건만 유지하고 deadline을 포화시켜 매 edge 재발화하지 않는다. Fallback 실제 수락/start에서 elapsed=0으로 재시작한다. IRQ와 timeout이 같은 edge면 IRQ가 우선해 요청 하나와 timer restart 한 번만 생긴다. deferred fallback 실행 전 IRQ가 오면 IRQ로 승격한다. Init/read/CS-hold 전송이 끝난 idle에서만 pending request를 시작하고 전송 중단/중복은 없다. Reset은 sync history, arm, timer, pending, transfer를 모두 지운다. 이 계약은 queue 1칸의 상한이지 interrupt 무손실이나 정확한 20 ms burst cadence 보장이 아니다. 정상 50 Hz DATA_READY는 30 ms 전에 watchdog을 restart해야 하고, IRQ 부재/stuck에서 fallback은 이전 physical data를 재읽을 수 있지만 완료 digital burst SEQ는 증가한다.

Pending request는 독립된 두 bit가 아니라 **단일 enum `NONE / FALLBACK / IRQ`**다. 우선순위는 `IRQ > FALLBACK > NONE`이며 아래 표는 reset 이후, 동일 edge의 launch 전 arbitration이다. 인정 IRQ마다 watchdog은 한 번 restart하고 fallback start에서도 한 번 restart한다. 계속 HIGH인 INT나 포화된 timeout 자체는 재시작하지 않는다. Idle launch 1회는 pending slot을 소비한다.

| edge 전 pending | 인정 IRQ | watchdog deadline | arbitration 후, idle launch 전 pending |
|---|---|---|---|
| 임의 | 예 | 무관 | IRQ; 기존 FALLBACK을 승격/취소, 추가 생성 금지 |
| IRQ | 아니오 | 무관 | IRQ; timeout이 두 번째 fallback을 넣지 못함 |
| FALLBACK | 아니오 | 무관 | FALLBACK; 반복 deadline coalesce |
| NONE | 아니오 | 예 | FALLBACK |
| NONE | 아니오 | 아니오 | NONE |

SPI engine이 idle이면 선택된 요청 최대 1개를 시작하고 pending을 clear한다. Busy면 그 1개 state만 defer한다. 이미 IRQ가 pending이어도 busy 중 새 IRQ를 인정하면 elapsed를 재시작한다. IRQ pending 중 도달한 deadline은 queue에 추가하지 않고 suppress한다. 지연된 IRQ launch 전에 deadline이 포화됐다면 eventual IRQ launch가 이 억제된 deadline을 소비하고 elapsed=0으로 한 번 재시작한다. 포화되지 않았다면 마지막 인정 IRQ의 timer 기준을 유지한다. 그러므로 긴 busy 이후 IRQ read 직후 즉시 중복 fallback이 생기지 않는다. Busy 또는 pending IRQ의 IRQ+deadline collision은 **eventual read 한 번만** 만들고 추가 fallback read를 만들면 안 된다. 동기화 LOW가 IRQ rearm을 허용하고 계속 HIGH인 pin은 새 IRQ를 만들지 못하지만 이후 30 ms watchdog은 별도 fallback을 요청할 수 있다.

과거 `POLL_BITS=14`는 25 PCLK마다 idle counter 1회 증가하고 bit14 검사하므로 nominal 16,384 × 25 / 50 MHz = **8.192 ms의 idle-count 시간**이다. 정확한 전체 sampling period가 아니며 P09 이후 역사 서술이다. P09의 30 ms는 마지막 인정 IRQ 또는 수락된 fallback start 기준 threshold로서 SPI completion 기준이 아니다. Digital 계약만으로 ADXL345 물리 update atomicity, SPI peer setup/hold, ODR 1:1, orientation/calibration 또는 board acceptance를 선언하지 않는다.

### Firmware와 수락 경계

단일 소유 firmware 수명주기/오류는 `19_firmware_contract.md` 및 국문 대응본을 따른다. 아래 acceptance 목록은 Historical Stage 1의 planned-check 목록이다. 그 `NOT_RUN` 표시는 당시 gate에 관한 것이며 이후 Public 구현 증거를 뜻하지 않는다. 독립적으로 남겨진 음성·물리 범위는 closure packet에 명시한다.

| 수락 ID | 독립 oracle / 관측 조건 | Stage 1 실행 |
|---|---|---|
| AC-01..04 | 독립 reset/pre-edge generation reference와 56-bit 비대칭 byte, LIVE refresh 동안 HOLD tuple 고정 | NOT_RUN |
| AC-05..08 | APB command ledger/pre-edge state model; 자격 없는·malformed control, release/recapture, E+C/E+RELEASE/pre-edge STATUS, valid seq0 wrap | NOT_RUN |
| AC-09..10 | 전체 주소/size/direction ACCESS ledger와 2-cycle fault; SETUP/ACCESS/CAPTURE/56-bit SPI/E0/E1/HOLD ownership 중 reset, stale command/sample 없음 | NOT_RUN |
| AC-11..12 | Driver 결과에서 유도하지 않은 scripted firmware MMIO 및 실제 CPU/AHB/APB 결과·fault signature | NOT_RUN |
| AC-13..15 | 실제 compile 경로의 HOLD_Z-from-LIVE_Z mutation 거부, 고정 regression exit chain, 별도 외부 timing/pin/orientation gate | NOT_RUN |
| AC-16 (P09B) | INT_MAP→INT_ENABLE, POWER_CTL 마지막을 포함한 독립 12-write 주소·값·횟수·순서 oracle | NOT_RUN |
| AC-17 (P09B) | 독립 50 MHz edge counter의 1,499,999/1,500,000/1,500,001 및 initial-high/stuck-high/LOW rearm/busy IRQ/IRQ+deadline/pending 우선순위·restart | NOT_RUN |
| AC-18 (P09B) | 단일 slot 부정 oracle: busy/IRQ pending 및 >30 ms 지연의 IRQ+deadline 주입 후 두 번째/즉시 fallback read 거부; launch 수·원인·포화 deadline 재시작 확인 | NOT_RUN |
| AC-19 (P09B) | 독립 reset/accepted-transfer ledger: 공통 release 초기화와 모든 abort 창; 중단 APB read 완료 주장 금지, 재초기화 후 old sample 없음 | NOT_RUN |

P09A AC-01..15는 승인된 P09B 계약으로 갱신한 예정 검사로 유지한다. 과거 `NO_SAMPLE` 표기는 네 결과 firmware API로 대체한다. 이 gate에서는 checker·runner·mutation을 구현하지 않았다.

| 요구사항 | pinned source 근거 → 목표 명세 | 예정 독립 AC |
|---|---|---|
| 공통 async-assert/sync-release 경로 | `rtl/soc/system_reset_controller.v`, `rtl/soc/AMBA_SoC_TOP.v`, `rtl/bus/AHB_APB_bridge.v` → 이 문서 reset 소유권 표와 `06_reset_clock.ko.md` | AC-01, AC-10, AC-19 |
| G-sensor local delay만 제거, reset abort 의미 유지 | `rtl/peripherals/gsensor/APB_GSENSOR_MB.v`, `reset_delay.v`, `spi_ee_config.v` → 이 문서 reset/transaction 표 | AC-09, AC-10, AC-19 |
| Full-byte XYZ, E0/E1 publish, 원자 HOLD | `rtl/peripherals/gsensor/spi_ee_config.v` → §11 및 위 bank 소유권 | AC-02..04, AC-07, AC-13 |
| 정확한 12-write startup, INT1, 단일 slot IRQ/watchdog | 현행 11-write `spi_ee_config.v`, pin assignment → 위 초기화/scheduler 표 | AC-16..18, AC-15 물리 gate |
| APB 오류 및 단일 소유 firmware 수명주기 | `rtl/bus/AHB_APB_bridge.v`, `rtl/soc/AMBA_SoC_TOP.v`, 현행 wrapper → 위 ABI와 `19_firmware_contract.ko.md` | AC-05, AC-09, AC-11..12, AC-19 |
