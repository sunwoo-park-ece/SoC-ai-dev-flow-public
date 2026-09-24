# Baseline SoC 전용 SPI 엔진 명세

> **상태:** ACTIVE SPECIFICATION — 현재 통합된 P09B 베이스라인 정본.
>
> **정본 언어:** 영어. 이 문서와 `13_spi.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `reset_clock.md`, `gsensor.md`.

## 1. 목적

이 문서는 활성 FPGA 베이스라인에 존재하는 전용 SPI 엔진을 정의한다.

베이스라인에는 소프트웨어 가시적인 범용 APB SPI 컨트롤러가 **존재하지 않는다**. 유일한 활성 SPI 데이터 경로는 온보드 ADXL345 가속도계를 구성하고 샘플링하는 G-sensor 서브시스템 내부의 전용 고정 기능 엔진이다.

이 명세가 소유하는 범위:

- 전용 SPI 엔진의 아키텍처 경계
- 활성 RTL 소스
- SPI 클록 및 리셋 생성
- 칩 선택(CS) 및 직렬 라인 동작
- 16-bit 초기화 쓰기 트랜잭션 형식 및 12-write 구성 시퀀스
- 56-bit 멀티바이트 가속도계 읽기 트랜잭션 형식
- 획득 스케줄링 (INT1 주 트리거 및 30 ms watchdog 폴백)
- 컨트롤러 시퀀싱 및 완료 핸드셰이크 동작
- 현재 한계 및 비프로그래머블 특성
- 검증 상태 및 잔여 물리 타이밍 종결 항목
- 출처 보존을 위해 유지되는 역사적 pre-P09 동작

소프트웨어 가시적 가속도계 레지스터 및 코히어런트 샘플 발행 ABI는 `12_gsensor.ko.md`에서 정의한다.

## 2. 아키텍처 역할

활성 데이터 경로는 다음과 같다:

```text
CPU
 |
 | 코히어런트 샘플 스냅샷의 APB 읽기 (HOLD bank)
 v
APB_GSENSOR_MB                 PCLK = 50 MHz, 공통 PRESETn
 |
 +-- LIVE / HOLD 샘플 bank + VALID / SEQ / SNAP_CTRL
 |
 +-- spi_ee_config             고정 기능 ADXL345 컨트롤러, 50 MHz PCLK
      |
      +-- 12개 순차 초기화 쓰기 (POWER_CTL 마지막 실행)
      +-- INT1 트리거 / 30 ms watchdog 폴백 획득
      |
      +-- SPI 엔진             registered mode-3 SCLK, ~2 MHz
            |
            +--> G_SENSOR_CS_N
            +--> G_SENSOR_SCLK
            +--> G_SENSOR_SDI   (FPGA -> ADXL345, MOSI)
            +<-- G_SENSOR_SDO   (ADXL345 -> FPGA, MISO)
```

현재 베이스라인에는 다음이 존재하지 않는다:

```text
SPI_BASE
APB_SPI
소프트웨어 TX/RX FIFO
소프트웨어 프로그래머블 CPOL/CPHA
소프트웨어 프로그래머블 칩 선택
소프트웨어 프로그래머블 워드 길이
소프트웨어 프로그래머블 클록 분주기
```

향후 별도의 명세가 범용 SPI 컨트롤러를 도입하지 않는 한, 본 프로젝트의 "SPI"는 이 전용 센서 전송 계층만을 의미한다.

## 3. 활성 RTL 소스

활성 구현은 다음으로 구성된다:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
rtl/peripherals/gsensor/spi_ee_config.v
```

모듈 관계:

```text
APB_GSENSOR_MB
  |
  +-- LIVE 및 HOLD 샘플 bank + APB 레지스터 인터페이스
  +-- spi_ee_config
```

과거 모듈 `reset_delay.v`, `adxl345_controller.v`, `SPI_MASTER.v`, `spi_param.h` 및 비공개 IP `spi_pll`은 현재 P09B 베이스라인에서 비활성이다.

## 4. 클록 및 리셋 계약

### 4.1 소스 클록

`APB_GSENSOR_MB`와 `spi_ee_config`는 50 MHz APB/시스템 클록 도메인에서 완전히 동작한다:

```text
PCLK = 50 MHz
```

내부 SPI 생성 클록 도메인이나 PLL은 존재하지 않는다.

### 4.2 리셋 분배

G-sensor 컨트롤러는 공통 `PRESETn`에 직접 연결된다:

```text
spi_ee_config.iRSTN = PRESETn
```

과거 wrapper의 `reset_delay` 인스턴스는 활성 경로에서 제거되었다.

- **비동기 Assertion:** `PRESETn`이 low로 assert되면 진행 중인 SPI 전송은 즉시 중단되고 직렬 핀은 안전한 유휴 값으로 복귀하며 컨트롤러/스케줄러 상태는 클리어된다.
- **동기 Release:** 리셋 해제는 시스템 리셋 검증(~20 ms)을 통해 PCLK에 동기화된다. 해제 즉시 컨트롤러는 12개의 순차 초기화 쓰기를 시작한다.

### 4.3 직렬 클록 생성

외부 직렬 클록 `G_SENSOR_SCLK`는 50 MHz PCLK 도메인의 레지스터 출력 플립플롭에 의해 직접 구동된다.

컨트롤러는 12 및 13 PCLK 반주기를 번갈아 가며 공칭 2 MHz SCLK를 생성한다:

```text
12 PCLKs (240 ns) + 13 PCLKs (260 ns) = 25 PCLKs (500 ns = 2.0 MHz)
```

이 registered 클록 출력은 보드 인터페이스 핀에만 존재하며, 내부 클록 도메인이 아니므로 내부 레지스터를 클록킹하지 않는다.

## 5. 물리 직렬 인터페이스

활성 보드 인터페이스는 전용 4선식 SPI 연결이다:

| 신호 | 방향 | 베이스라인 동작 |
|---|---|---|
| `G_SENSOR_CS_N` | FPGA -> 센서 | active-low 칩 선택 |
| `G_SENSOR_SCLK` | FPGA -> 센서 | 유휴 시 high; 활성 시 registered 2 MHz mode-3 클록 |
| `G_SENSOR_SDI` | FPGA -> 센서 | 명령/주소/쓰기 데이터 출력 (MOSI) |
| `G_SENSOR_SDO` | 센서 -> FPGA | 읽기 데이터 입력 (MISO) |

활성 설계는 분리된 MOSI 및 MISO 라인을 사용한다. 트랜잭션의 읽기 데이터 단계 동안 `G_SENSOR_SDI`는 low로 구동된다.

## 6. 직렬 프로토콜 및 Mode-3 타이밍

전용 SPI 엔진은 **SPI Mode 3** (`CPOL = 1, CPHA = 1`)으로 동작한다:

- `G_SENSOR_SCLK`는 유휴 시 high이다.
- `G_SENSOR_CS_N`은 SCLK가 high인 상태에서 low로 assert된다.
- MOSI 데이터(`G_SENSOR_SDI`)는 SCLK의 하강 에지에서 변경된다.
- MISO 데이터(`G_SENSOR_SDO`)는 SCLK의 상승 에지에서 샘플링된다.
- CS는 전체 트랜잭션 동안 low를 유지하며 마지막 샘플링 비트 이후 high로 복귀한다.

## 7. 초기화 쓰기 트랜잭션

### 7.1 트랜잭션 형식

각 초기화 트랜잭션은 16-bit 직렬 쓰기다:

```text
[15:14] WRITE_MODE = 2'b00
[13: 8] ADXL345 레지스터 주소[5:0]
[ 7: 0] 레지스터 쓰기 데이터
```

비트 15부터 비트 0까지 MSB 우선으로 전송된다.

### 7.2 12-Write 초기화 시퀀스

리셋 해제 시 `spi_ee_config`는 정확히 12개의 순차 레지스터 쓰기를 수행한다:

| 순번 | ADXL345 레지스터 | 주소 | 기록 값 | 동작 목적 |
|---:|---|---:|---:|---|
| 0 | `THRESH_ACT` | `0x24` | `0x20` | 활동 임계값 |
| 1 | `THRESH_INACT` | `0x25` | `0x03` | 비활동 임계값 |
| 2 | `TIME_INACT` | `0x26` | `0x01` | 비활동 시간 |
| 3 | `ACT_INACT_CTL` | `0x27` | `0x7F` | 활동/비활동 제어 |
| 4 | `THRESH_FF` | `0x28` | `0x09` | 자유 낙하 임계값 |
| 5 | `TIME_FF` | `0x29` | `0x46` | 자유 낙하 시간 |
| 6 | `BW_RATE` | `0x2C` | `0x09` | 50 Hz 출력 데이터 레이트, 정상 전력 |
| 7 | `INT_MAP` | `0x2F` | `0x00` | DATA_READY를 INT1 핀에 매핑 |
| 8 | `INT_ENABLE` | `0x2E` | `0x80` | DATA_READY 인터럽트 출력 활성화 |
| 9 | `DATA_FORMAT` | `0x31` | `0x00` | 기본 ±2g 범위, 10-bit 우측 정렬 |
| 10 | `OFSZ` | `0x20` | `0x07` | Z축 오프셋 보정 (~ +109 mg) |
| 11 | `POWER_CTL` | `0x2D` | `0x08` | 측정 모드 활성화 (**마지막 실행**) |

`POWER_CTL`을 마지막에 실행함으로써 측정이 시작되기 전에 ADXL345가 대기 모드에서 완전히 구성되도록 보장한다.

12번째 쓰기가 완료되고 CS가 high로 복귀한 후 획득 스케줄러가 활성화(arm)되어 INT1 인식과 30 ms watchdog이 동작한다.

## 8. 멀티바이트 가속도계 읽기 (56-Bit Burst)

### 8.1 명령 및 구조

각 가속도계 획득은 56-bit SPI 트랜잭션을 수행한다:

```text
8-bit 명령/주소 단계: {1'b1 (읽기), 1'b1 (멀티바이트), 6'h32 (DATAX0)} = 0xF2
48-bit 읽기 데이터 단계: ADXL345가 연속 반환하는 6바이트
```

반환되는 6바이트 데이터:

```text
DATAX0, DATAX1 (X축 하위/상위)
DATAY0, DATAY1 (Y축 하위/상위)
DATAZ0, DATAZ1 (Z축 하위/상위)
```

컨트롤러는 세 축 모두에 대해 완전한 16-bit 값을 추출한다.

### 8.2 내부 핸드셰이크

하위 레벨 전송 완료는 `spi_end` / `sample_complete` 신호로 내부에 전달된다. 완료 시 샘플은 `APB_GSENSOR_MB`의 LIVE bank로 원자적으로 발행된다.

## 9. 획득 스케줄러 및 Watchdog

### 9.1 주 트리거: INT1

- 외부 핀 `GSENSOR_INT[1]`(DE10-Lite 핀 `Y14`, ADXL345 INT1에 연결됨)은 2단 플립플롭을 통해 PCLK로 동기화된다.
- 활성화 상태에서 동기화된 INT1의 상승 에지가 감지되면 획득 읽기가 트리거된다.
- 축 데이터 레지스터를 읽으면 ADXL345 내부의 DATA_READY가 자동으로 클리어된다.

### 9.2 폴백 트리거: 30 ms Watchdog

- 마지막으로 인식된 획득 이후 경과된 PCLK 사이클을 50 MHz 카운터로 측정한다.
- 1,500,000 사이클(정확히 30 ms)에 도달하면 INT1 트리거가 발생하지 않은 경우 폴백 획득을 요청한다.
- 정상 50 Hz 동작 시 DATA_READY는 약 20 ms마다 도착하여 30 ms 데드라인 전에 watchdog을 리셋한다.

### 9.3 대기 요청 중재

스케줄러는 단일 슬롯 대기 요청 열거형을 유지한다:

```text
NONE / FALLBACK / IRQ
```

- 우선순위: `IRQ > FALLBACK > NONE`.
- SPI 엔진이 바쁜 동안 발생하는 트리거는 단일 대기 슬롯으로 병합(coalesce)되며 중복 읽기가 큐잉되지 않는다.
- SPI 엔진이 유휴 상태로 돌아오면 대기 요청이 즉시 시작된다.

## 10. 소프트웨어 가시성 및 상태

전용 SPI 엔진에 대한 직접적인 펌웨어 인터페이스는 없다:

- 소프트웨어는 SPI 클록 레이트, 모드, 칩 선택을 구성할 수 없다.
- 소프트웨어는 수동 SPI 쓰기나 읽기를 트리거할 수 없다.
- 모든 소프트웨어 상호작용은 `12_gsensor.ko.md` 및 `19_firmware_contract.ko.md`에 정의된 `gsensor_read_sample()` API를 통해 APB G-sensor 레지스터 맵(`HOLD_XY`, `HOLD_Z`, `STATUS`, `HOLD_SEQ`, `SNAP_CTRL`)으로 수행된다.

## 11. 검증 상태 및 잔여 종결 갭

### 11.1 검증 상태

- **SPI-001 (디지털 트랜잭션 검증):** `VERIFIED`. Scoped 디지털 테스트벤치(`tb_gsensor_single_pclk.sv`)를 통해 Mode 3 SCLK 타이밍, 12/13-PCLK 반주기, 전체 초기화 쓰기, 56-bit burst 읽기, MSB 우선 비트 순서, 상승 에지 MISO 샘플링, 정확한 CS assertion 기간 및 리셋 중단 동작을 검증함.
- **내부 타이밍 종결:** Quartus TimeQuest에서 slow/fast 코너 전반에 걸쳐 모든 내부 G-sensor 경로에 대해 양의 50 MHz setup/hold 마진을 확인함.

### 11.2 잔여 종결 갭 (IN_PROGRESS / BLOCKED 사유)

- **SPI-002 (물리 ADXL345 핀 타이밍):** `IN_PROGRESS`. 보드 인터페이스 SPI 핀 타이밍(ADXL345 데이터시트 제한값 대비 외부 setup/hold, PCB 트레이스 지연, 핀 커패시턴스)이 오실로스코프로 물리 특성화되지 않음.
- **STA-002 (외부 I/O 타이밍 / 전기적 종결):** `BLOCKED`. 모든 보드 I/O 인터페이스 전반의 물리 보드 레벨 타이밍 측정 및 전기적 sign-off 대기 중.

## 12. 역사적 베이스라인 / Pre-P09 노트

다음 내용은 G-sensor SPI 서브시스템의 이전 세대를 설명하며 출처 보존 및 역사적 해석을 위해서만 유지된다:

1. **역사적 Dual-Phase `spi_pll` (Pre-A6):**
   초기 서브시스템은 50 MHz로부터 ~80도 위상차를 갖는 공칭 2 MHz 클록 2개(`spi_clk` 컨트롤러 상태용, `spi_clk_out` 외부 SCLK용)를 생성하는 Altera `spi_pll` IP를 사용했다. 이는 안전하지 않은 내부 `spi_clk -> PCLK` 클록 도메인 크로싱을 유발하고 별도의 PLL lock 대기를 요구했다. A6는 `spi_pll`을 완전히 제거하고 컨트롤러를 단일 50 MHz PCLK 동작으로 변환했다.
2. **역사적 로컬 리셋 지연 (`reset_delay.v`):**
   A6 wrapper는 시스템 리셋 해제 후 ~20.97 ms의 추가 지연을 더하는 `reset_delay.v`(20-bit counter, 총 기동 지연 약 41 ms) 인스턴스를 유지했다. P09B는 이 인스턴스를 제거하고 `spi_ee_config`를 공통 `PRESETn`에 직접 연결했다.
3. **역사적 11-Write 시퀀스:**
   Pre-P09 베이스라인은 `INT_ENABLE = 0x00`(인터럽트 비활성화) 상태로 11개 초기화 쓰기를 수행했고 측정 모드(`POWER_CTL = 0x08`)를 마지막이 아닌 10번째 쓰기에서 활성화했다. P09B는 이를 12개 순차 쓰기로 확장하여 INT1의 DATA_READY를 활성화하고 `POWER_CTL`을 마지막에 배치했다.
4. **역사적 ~8.192 ms 폴링 폴백:**
   Pre-P09 컨트롤러는 유휴 카운터 비트 14(`POLL_BITS = 14`, 공칭 16,384 × 25 / 50 MHz ≈ 8.192 ms)를 기반으로 데이터를 폴링했으나, 이는 센서 ODR과 비동기적이어서 중복 샘플을 생성했다. P09B는 이를 INT1 트리거 획득 및 30 ms watchdog으로 대체했다.
5. **역사적 2-레지스터 APB 인터페이스:**
   Pre-P09 APB wrapper는 `VALID`, `SEQ` 또는 원자적 스냅샷 기능 없이 2개의 읽기 전용 레지스터(`GSENSOR_XY_DATA`, `GSENSOR_Z_DATA`)만 노출하여 분리된 버스 트랜잭션 간 torn read 위험이 있었다. P09B는 코히어런트 LIVE/HOLD 아키텍처를 도입했다.
