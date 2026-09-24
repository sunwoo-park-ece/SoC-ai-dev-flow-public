# Baseline SoC G-Sensor Subsystem 명세

> **상태:** ACTIVE SPECIFICATION — 현재 통합된 P09B 베이스라인 정본.
>
> **정본 언어:** 영어. 이 문서와 `12_gsensor.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. 목적

이 문서는 활성 DE10-Lite FPGA 베이스라인의 온보드 ADXL345 가속도계 / G-sensor 서브시스템을 정의한다.

서브시스템은 전용 하드웨어 컨트롤러 및 코히어런트 샘플 발행 인터페이스로 동작한다. 주요 명세 범위는 다음과 같다:

- 최상위 통합 및 APB 슬롯 할당
- 단일 50 MHz PCLK 도메인 및 공통 `PRESETn` 리셋 아키텍처
- 고정 기능 12-write ADXL345 하드웨어 초기화 시퀀스
- 30 ms watchdog 폴백을 갖춘 INT1 트리거 획득 스케줄러
- 전용 4선식 SPI Mode 3 트랜잭션 엔진
- 생성자(LIVE) 및 스냅샷(HOLD) bank를 사용한 코히어런트 샘플 발행
- 원자적 CAPTURE 및 RELEASE 시맨틱을 갖춘 5개 APB 레지스터 맵
- 동시 이벤트 우선순위 및 비동기 리셋 중단 규칙
- 프로덕션 펌웨어 드라이버 계약 (`gsensor_read_sample()`)
- 현재 검증 상태 및 잔여 엔지니어링 종결 갭
- 출처 보존을 위해 유지되는 역사적 pre-P09 동작

본 서브시스템은 전용 센서 전송 및 발행 인터페이스이며 소프트웨어 프로그래머블 범용 SPI 컨트롤러가 아니다.

## 2. 현재 아키텍처

G-sensor 서브시스템은 표준 베이스 주소의 APB 슬롯 3을 점유한다:

```text
GSENSOR_BASE = 0x4003_0000
APB slot     = PSEL[3]
```

최상위 통합 구조:

```text
CPU (RV32I)
 |
 | AHB
 v
AHB-to-APB 브리지
 |
 +--> PSEL[3]
       |
       v
 APB_GSENSOR_MB                       50 MHz PCLK, 공통 PRESETn
       |
       +-- LIVE bank                  생성자 페이로드 {X, Y, Z, SEQ, VALID}
       +-- HOLD bank                  CPU 스냅샷 {X, Y, Z, SEQ, VALID}
       +-- APB 레지스터 디코드         HOLD_XY, HOLD_Z, STATUS, HOLD_SEQ, SNAP_CTRL
       |
       +-- spi_ee_config              PCLK 단일 도메인 ADXL345 FSM
             |
             +-- 12개 순차 초기화 테이블
             +-- INT1 / 30 ms watchdog 스케줄러 (1개 대기 슬롯)
             +-- registered mode-3 SPI 마스터 (~2 MHz)
                   |
                   +--> G_SENSOR_CS_N
                   +--> G_SENSOR_SCLK (~2 MHz registered 출력)
                   +--> G_SENSOR_SDI  (MOSI)
                   +<-- G_SENSOR_SDO  (MISO)
                   +<-- GSENSOR_INT[1] (센서의 INT1 입력)
```

활성 RTL 소스:

```text
rtl/peripherals/gsensor/APB_GSENSOR_MB.v
rtl/peripherals/gsensor/spi_ee_config.v
```

과거 모듈 `reset_delay.v`, `adxl345_controller.v`, `SPI_MASTER.v`, `spi_param.h` 및 비공개 `spi_pll`은 현재 P09B 베이스라인에서 비활성이다.

APB wrapper는 표준 오프셋에서 0-wait 전송(`PREADY = 1`)을 제공한다. APB wrapper는 유효하지 않은 접근(미매핑 오프셋, 잘못된 접근 방향, 또는 비정상 명령)에 대해 완료 ACCESS에서 `PSLVERR`을 assert한다. AHB-to-APB bridge는 이 슬레이브 에러를 프로젝트의 2-사이클 AHB ERROR 응답(`HRESP=01`)으로 변환한다.

## 3. 클록 / 리셋

### 3.1 클록 아키텍처

G-sensor 컨트롤러, 샘플 bank 및 APB 인터페이스는 단일 50 MHz APB 클록에서 동기식으로 동작한다:

```text
PCLK = 50 MHz
```

- 내부 SPI 생성 클록 도메인이나 PLL은 존재하지 않는다.
- 외부 직렬 클록 `G_SENSOR_SCLK`는 12/13 PCLK 반주기(공칭 2 MHz)를 번갈아 구동하는 registered 플립플롭에 의해 구동된다. SCLK는 외부 핀 출력일 뿐 내부 클록 도메인이 아니다.

### 3.2 리셋 아키텍처

전체 서브시스템은 공통 시스템 주변장치 리셋에 직접 연결된다:

```text
spi_ee_config.iRSTN = PRESETn
```

- **공통 리셋 검증:** 시스템 리셋 해제는 2단 HCLK 동기화 및 1,000,000 PCLK 사이클(~20 ms) 후에 발생한다.
- **로컬 리셋 지연 제거:** 과거 wrapper의 `reset_delay` 인스턴스(~20.97 ms)는 활성 경로에서 제거되었다.
- **비동기 Assertion:** `PRESETn`의 low assertion은 진행 중인 SPI 트랜잭션이나 APB 접근을 즉시 중단하고 직렬 라인을 안전한 유휴 상태로 구동하며 LIVE/HOLD bank, SEQ, VALID 및 스케줄러 상태를 클리어한다.
- **동기 Release:** 해제 시 컨트롤러는 즉시 12개의 순차 ADXL345 초기화 쓰기를 시작한다.

## 4. 초기화

리셋 해제 후 `spi_ee_config`는 SPI를 통해 정확히 12개의 순차 16-bit 레지스터 쓰기를 수행한다:

| 순번 | ADXL345 레지스터 | 주소 | 기록 값 | 동작 목적 |
|---:|---|---:|---:|---|
| 0 | `THRESH_ACT` | `0x24` | `0x20` | 활동 임계값 |
| 1 | `THRESH_INACT` | `0x25` | `0x03` | 비활동 임계값 |
| 2 | `TIME_INACT` | `0x26` | `0x01` | 비활동 시간 |
| 3 | `ACT_INACT_CTL` | `0x27` | `0x7F` | 활동/비활동 제어 |
| 4 | `THRESH_FF` | `0x28` | `0x09` | 자유 낙하 임계값 |
| 5 | `TIME_FF` | `0x29` | `0x46` | 자유 낙하 시간 |
| 6 | `BW_RATE` | `0x2C` | `0x09` | 50 Hz 정상 전력 출력 데이터 레이트 |
| 7 | `INT_MAP` | `0x2F` | `0x00` | DATA_READY를 INT1 핀에 매핑 |
| 8 | `INT_ENABLE` | `0x2E` | `0x80` | DATA_READY 인터럽트 출력 활성화 |
| 9 | `DATA_FORMAT` | `0x31` | `0x00` | 기본 ±2g 범위, 10-bit 우측 정렬 |
| 10 | `OFSZ` | `0x20` | `0x07` | Z축 오프셋 보정 (~ +109 mg) |
| 11 | `POWER_CTL` | `0x2D` | `0x08` | 측정 모드 활성화 (**마지막 실행**) |

`POWER_CTL`을 마지막에 실행함으로써 측정이 시작되기 전에 센서가 완전히 구성되도록 보장한다. 획득 스케줄러는 11번 쓰기가 완료되고 CS가 high로 복귀한 후에만 활성화된다.

## 5. 획득 스케줄러

스케줄러는 물리 센서 인터럽트와 폴백 타이머 사이를 중재한다:

### 5.1 주 트리거: INT1

- 보드 핀 `G_SENSOR_INT[1]`(DE10-Lite 핀 `Y14`, ADXL345 INT1)은 2단 플립플롭을 통해 PCLK로 동기화된다.
- 활성화 상태에서 감지된 동기 상승 에지는 획득 버스트를 트리거한다.
- SPI를 통해 축 데이터 레지스터를 읽으면 센서 내부의 DATA_READY 상태가 자동으로 클리어된다.

### 5.2 폴백 트리거: 30 ms Watchdog

- 내부 50 MHz 카운터가 마지막으로 인식된 획득 이후 경과된 PCLK 사이클을 측정한다.
- 1,500,000 사이클(30 ms)에 도달하면 INT1 트리거가 발생하지 않은 경우 폴백 획득을 요청한다.
- 정상 50 Hz DATA_READY 펄스는 약 20 ms마다 도착하여 30 ms 데드라인 전에 watchdog을 리셋한다.

### 5.3 요청 중재

스케줄러는 단일 슬롯 대기 요청 열거형을 유지한다:

```text
NONE / FALLBACK / IRQ
```

- 우선순위: `IRQ > FALLBACK > NONE`.
- SPI 전송 중에 발생하는 트리거는 단일 대기 슬롯으로 병합되며 중복 읽기가 큐잉되지 않는다.
- SPI 마스터가 유휴 상태로 돌아오면 대기 요청이 즉시 시작된다.

## 6. SPI 트랜잭션 계약

- **Mode 3 타이밍:** `CPOL = 1, CPHA = 1`. SCLK는 유휴 시 high; SCLK가 high인 상태에서 CS assert; 하강 에지에서 MOSI 변경; 상승 에지에서 MISO 샘플링; 마지막 샘플링 비트 이후 CS deassert.
- **초기화 쓰기 (16 bits):** 8-bit 명령/주소(`{2'b00, addr[5:0]}`) 및 8-bit 데이터.
- **버스트 읽기 (56 bits):** 8-bit 명령 `0xF2`(`{1'b1 (읽기), 1'b1 (멀티바이트), 6'h32 (DATAX0)}`) 및 연속 48 bits (6 bytes) 축 데이터:
  ```text
  DATAX0, DATAX1 (X축)
  DATAY0, DATAY1 (Y축)
  DATAZ0, DATAZ1 (Z축)
  ```
  컨트롤러는 X, Y, Z 세 축 모두에 대해 완전한 16-bit 값을 추출한다.

## 7. LIVE/HOLD 샘플 발행

APB wrapper는 2개의 내부 bank를 통해 코히어런트 발행을 제공한다:

- **LIVE Bank:** `{x[15:0], y[15:0], z[15:0], seq[31:0], valid}`. 지속적으로 갱신되는 생성자 bank.
- **HOLD Bank:** `{x[15:0], y[15:0], z[15:0], seq[31:0], valid}`. CPU가 소유하는 스냅샷 bank.

### 7.1 샘플 완료 경계 (E0 / E1)

1. SPI 비트 카운터 완료 시점(**E0**)에 축 레지스터 및 `gsensor_ready = 1`이 등록된다.
2. 다음 PCLK 에지(**E1**, `sample_complete`)에서 wrapper는 원자적으로:
   - 새 X/Y/Z 데이터를 LIVE bank로 복사하고,
   - `LIVE_SEQ`를 modulo 2^32로 증가시키며 (첫 완료 샘플은 `seq = 1` 발행),
   - `LIVE_VALID = 1`로 설정한다.

### 7.2 캡처 및 해제 시맨틱

- **CAPTURE (`SNAP_CTRL = 1`):** `LIVE_VALID == 1`이고 `HOLD_VALID == 0`인 경우, pre-edge LIVE 데이터와 시퀀스를 HOLD로 원자적 복사하고 `HOLD_VALID = 1`을 설정하며 `LIVE_VALID = 0`으로 클리어한다. 자격 없는 CAPTURE는 APB OKAY no-op으로 완료된다.
- **RELEASE (`SNAP_CTRL = 2`):** HOLD 데이터와 시퀀스를 0으로 클리어하고 `HOLD_VALID = 0`으로 설정한다. LIVE bank는 변경하지 않는다.

## 8. APB 레지스터 맵

표준 베이스 주소는 `0x4003_0000`이다. 정렬된 32-bit 접근만 지원한다:

| 오프셋 | 이름 | 접근 | 읽기 데이터 | 쓰기 효과 |
|---:|---|---|---|---|
| `0x00` | `HOLD_XY` | R | `HOLD_VALID ? {X[15:0], Y[15:0]} : 0` | ERROR (`PSLVERR`) |
| `0x04` | `HOLD_Z` | R | `HOLD_VALID ? {16'b0, Z[15:0]} : 0` | ERROR (`PSLVERR`) |
| `0x08` | `STATUS` | R | `{30'b0, HOLD_VALID, LIVE_VALID}` | ERROR (`PSLVERR`) |
| `0x0C` | `HOLD_SEQ` | R | `HOLD_VALID ? HOLD_SEQ : 0` | ERROR (`PSLVERR`) |
| `0x10` | `SNAP_CTRL` | W | ERROR (`PSLVERR`) | `32'h1` = CAPTURE, `32'h2` = RELEASE; 기타 ERROR |

- 미매핑 오프셋(`> 0x10`), 잘못된 접근 방향, 또는 `SNAP_CTRL`에 대한 잘못된 쓰기 값은 완료 ACCESS에서 `PSLVERR`을 assert하며, AHB-to-APB bridge는 이를 프로젝트의 2-사이클 AHB ERROR 응답으로 변환한다.
- `STATUS` 읽기는 side-effect가 없으며 pre-edge 등록 상태를 반환한다.

## 9. 이벤트 우선순위 / 리셋 시맨틱

### 9.1 동시 이벤트 우선순위

| 이벤트 조건 | LIVE Next | HOLD Next | 관측 가능한 동작 |
|---|---|---|---|
| 리셋 Assertion | 모두 0, valid = 0 | 모두 0, valid = 0 | 모든 작업 중단, 소유권 취소 |
| E만 발생 | 새 XYZ, seq+1, valid = 1 | 변경 없음 | LIVE에 새 샘플 발행 |
| 유효한 C만 발생 | 변경 없음, valid = 0 | Pre-edge LIVE, valid = 1 | HOLD에 원자적 스냅샷 획득 |
| 자격 없는 C | 변경 없음 | 변경 없음 | APB OKAY no-op |
| E + C (LIVE 유효, HOLD 빈 상태) | 새 XYZ, seq+1, valid = 1 | Pre-edge LIVE, valid = 1 | HOLD는 이전 샘플, LIVE는 새 샘플 |
| E + C (LIVE 무효 또는 HOLD 점유) | 새 XYZ, seq+1, valid = 1 | 변경 없음 | C no-op, E는 LIVE에 새 샘플 발행 |
| RELEASE (E 유무 무관) | E 존재 시 LIVE 발행 | 모두 0, valid = 0 | HOLD 스냅샷 클리어 |
| STATUS 읽기와 E가 같은 edge | 에지 후 E 발행 | 변경 없음 | 완전한 pre-edge STATUS 값을 반환; E에 의한 갱신은 다음 읽기부터 관측 |

### 9.2 리셋 중단 규칙

- 비동기 리셋 assertion은 모든 버스 및 컨트롤러 동작을 즉시 중단한다.
- 리셋에 의해 중단된 APB 읽기/쓰기는 완료나 반환 값을 보장하지 않는다.
- 리셋 해제 후 초기화가 완료되고 첫 완전 디지털 버스트가 끝날 때까지 `LIVE_VALID`와 `HOLD_VALID`는 0을 유지한다.

## 10. 펌웨어 가시 동작

펌웨어는 표준 C 드라이버 API를 통해 G-sensor와 상호작용한다:

```c
gsensor_status_t gsensor_read_sample(gsensor_sample_t *out);
```

### 10.1 폴링 프로토콜

1. `STATUS` 읽기:
   - `HOLD_VALID == 1`이면 `GSENSOR_BUSY` 반환.
   - `LIVE_VALID == 0`이면 `GSENSOR_NO_NEW` 반환.
2. `SNAP_CTRL = 1` 쓰기 (CAPTURE).
3. `STATUS` 읽고 `HOLD_VALID == 1` 확인. 실패 시 `GSENSOR_NO_NEW` 반환.
4. `HOLD_SEQ`, `HOLD_XY`, `HOLD_Z` 순차 읽기.
5. `SNAP_CTRL = 2` 쓰기 (RELEASE).
6. 채워진 `*out`과 함께 `GSENSOR_OK` 반환.

### 10.2 반환 코드

- `GSENSOR_OK`: 새 코히어런트 샘플 획득 성공.
- `GSENSOR_NO_NEW`: 마지막 캡처 이후 새 샘플 없음.
- `GSENSOR_BUSY`: 스냅샷 점유 중 또는 경합 감지.
- `GSENSOR_ERROR`: null 포인터 또는 드라이버 결함.

드라이버는 단일 소유자 전용이며 재진입할 수 없다.

## 11. 검증 상태

P09B 기능 구현, 디지털 검증, 실제 RV32I CPU 통합, Quartus/TimeQuest 타이밍 및 실질적인 FPGA 보드 동작은 **완료 및 통합됨**:

- **디지털 검증:** Mode 3 SPI 파형, 12-write 초기화 시퀀스, 56-bit 버스트 읽기, LIVE/HOLD 원자성, 단일 대기 스케줄러 슬롯, APB 레지스터 디코드 및 오류 처리가 모든 자체 검증 회귀 테스트를 통과함.
- **CPU 통합:** RV32I CPU 하네스 및 드라이버 mock-MMIO 테스트에서 엔드투엔드 CAPTURE/RELEASE 폴링 및 트랩 처리를 검증함.
- **타이밍 종결:** slow/fast 온도 코너 전반에서 내부 50 MHz PCLK 타이밍이 양의 setup/hold 마진으로 통과함.
- **보드 동작 확인:** 디스플레이 애플리케이션을 통해 실질적인 FPGA 보드 동작 확인 (사진 `SEQ=0x1450`, 사용자 관측 `SEQ≈0x7C00`, 동적 기울임 반응).

## 12. 잔여 종결 갭

트래커는 좁게 정의된 잔여 종결 증거 갭으로 인해 보수적인 `IN_PROGRESS` (및 `STA-002` `BLOCKED`) 상태를 유지한다:

1. **GS-001 (코히어런트 XYZ / VALID / SEQ):** 정상/CPU 경로에서 기능 검증 완료. 잔여 갭은 비동기 리셋의 APB SETUP/ACCESS 중첩, CAPTURE/RELEASE 대비 리셋, 샘플 완료 경계 에지 케이스 등 견고성 증거임.
2. **GS-003 (획득 정책):** 12-write 초기화 및 INT1/watchdog 스케줄러의 디지털 검증 완료. 잔여 갭은 물리 INT1 오실로스코프 파형/핀 매핑, 센서 ODR 대 IRQ 동작 분석 등 물리 특성화임.
3. **GS-004 (첫 샘플 유효성 / 리셋 시맨틱):** 정상 리셋 동작 검증 완료. 잔여 갭은 활성 SPI 트랜잭션, APB 단계, HOLD 소유권 전반의 완전한 리셋-abort 코너 커버리지임.
4. **GS-005 (전체 G-sensor 클린업/수락):** 베이스라인 개발을 위한 보드 기능 동작 확인. 완전한 sign-off는 정량적 캘리브레이션, 체계적 방향 매트릭스, 물리 INT1 파형 증거, 장시간 SEQ 무결성 스트레스 및 외부 SPI 타이밍 종결(`STA-002`)을 요구함.
5. **CDC-002:** 과거 안전하지 않은 `spi_clk -> PCLK` 크로싱은 이미 제거됨; P09B는 LIVE/HOLD 발행을 통해 소프트웨어 가시 torn read를 해결함. 비-VERIFIED 상태는 보수적 증거 범위 때문이며 활성 비안전 크로싱 때문이 아님.
6. **FW-008 (펌웨어 API):** 드라이버가 기능적이며 검증됨. 잔여 갭은 완전한 리셋-negative 커버리지 및 동시 호출자 오용 처리임.
7. **STA-002:** 외부 ADXL345 SPI 타이밍 및 보드 레벨 전기적 sign-off는 물리 측정 대기로 BLOCKED 유지.

## 13. 역사적 A6 / Pre-P09 노트

다음 내용은 이전 세대를 설명하며 출처 보존을 위해서만 유지된다:

1. **A6 PCLK 변환 및 `spi_pll` 제거:**
   초기 설계는 Altera `spi_pll`을 사용하여 위상 지연된 2 MHz 클록(`spi_clk`, `spi_clk_out`)을 생성하여 제약되지 않은 `spi_clk -> PCLK` CDC를 유발했다. A6는 모든 내부 로직을 단일 50 MHz PCLK로 변환하고 registered 플립플롭에서 외부 SCLK를 구동하도록 수정했다.
2. **역사적 로컬 `reset_delay`:**
   A6 wrapper는 시스템 리셋 해제 후 추가로 2^20 PCLK 사이클(~20.97 ms) 동안 컨트롤러를 리셋 상태로 유지하는 `reset_delay.v`를 인스턴스화했다. P09B는 이 지연을 제거하고 공통 `PRESETn`에 직접 연결했다.
3. **역사적 11-Write 시퀀스:**
   Pre-P09 시퀀스는 `INT_ENABLE = 0x00`(인터럽트 비활성화) 상태로 11회 쓰기를 수행했고 10번째 쓰기에서 측정 모드(`POWER_CTL = 0x08`)를 활성화했다. P09B는 이를 12회 쓰기로 확장하여 DATA_READY를 INT1에 라우팅하고(`INT_ENABLE = 0x80`), `POWER_CTL`을 마지막에 실행하도록 수정했다.
4. **역사적 ~8.192 ms 폴링 폴백:**
   Pre-P09 컨트롤러는 유휴 카운터 비트 14(`POLL_BITS = 14`, ~8.192 ms)를 기반으로 폴링하여 비동기 중복 샘플을 생성했다. P09B는 이를 INT1 트리거 획득 및 30 ms watchdog으로 대체했다.
5. **역사적 2-레지스터 APB 맵:**
   Pre-P09 APB 인터페이스는 `VALID`, `SEQ` 또는 원자적 스냅샷 기능 없이 `GSENSOR_XY_DATA`(`+0x00`) 및 `GSENSOR_Z_DATA`(`+0x04`)만 읽기 전용으로 노출했다. P09B는 이를 5개 레지스터의 LIVE/HOLD ABI로 대체했다.
