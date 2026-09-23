# Baseline SoC HEX Display Specification — 한국어 Companion

> **상태:** VERIFIED / ACTIVE BASELINE — Issue #3 HEX cleanup target이 RTL/firmware에 구현되었으며, directed simulation, Quartus build 및 물리 FPGA board acceptance를 통해 검증 완료됨 (2026-09-24).
>
> **정본 언어:** 영어. 이 문서와 `spec/16_hex_display.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`.

## 1. 목적

이 문서는 active FPGA baseline의 6-digit seven-segment HEX display peripheral을 정의한다.

주요 범위는 다음과 같다.

- APB/MMIO register contract
- 6-digit VALUE packing
- hexadecimal decoder mode
- raw segment mode
- active-low segment encoding
- display enable behavior
- reset state
- firmware programming rule
- physical top-level integration
- 현재 verification evidence
- 향후 major feature integration 전 cleanup requirement

현재 블록은 단순한 synchronous APB output peripheral이다. scan engine, PWM brightness control, interrupt, DMA, decimal-point control은 없다.

## 2. Active Architecture

Canonical base address:

```text
HEX_DISPLAY_BASE = 0x4007_0000
APB slot         = PSEL[7]
```

Active RTL:

```text
rtl/peripherals/APB_HEX_display.v
```

구조:

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +-- PSEL[7]
      |
      v
APB_HEX_display                 PCLK = 50 MHz
      |
      +-- VALUE
      +-- CTRL
      +-- RAW_LOW
      +-- RAW_HIGH
      +-- hexadecimal decoder
      |
      +--> HEX0[6:0]
      +--> HEX1[6:0]
      +--> HEX2[6:0]
      +--> HEX3[6:0]
      +--> HEX4[6:0]
      +--> HEX5[6:0]
```

Baseline에서 `PCLK = HCLK = 50 MHz`이므로 이 peripheral 내부 CDC는 없다.

```text
PREADY = 1
IRQ    = none
```

## 3. Physical Display Contract

Active top-level은 각 display에 대해 7-bit만 노출한다.

```verilog
HEX0[6:0]
...
HEX5[6:0]
```

Segment bit order:

```text
[6:0] = {g, f, e, d, c, b, a}
```

Active-low이므로:

```text
0 -> segment ON
1 -> segment OFF
```

Decimal point는 active RTL contract에 포함되지 않는다.

### 3.1 과거 QSF 불일치와 승인된 pin 정책

Owner는 과거 로컬 QSF에 stale `HEXx[7]` assignment가 있었지만 실제 top-level
port는 7-bit였음을 확인했다. 이는 과거 소스에 대한 설명이며 현재 공개
constraint에 bit 7이 존재한다는 뜻이 아니다. Owner는
`fpga/quartus/constraints/de10_lite_pins.tcl`의 `HEX0..HEX5[6:0]` 구성을
검토하고 유지 승인했다. `scripts/wsl/private_quartus.py`는 private QSF를
생성하면서 이 공개 pin Tcl을 `source`한다.

공개 Tcl에 없는 `HEXx[7]` line의 추측성 삭제 patch를 만들거나 DP를
재도입하지 않는다. P10-HEX S6에서 최종 Quartus Fitter Pin 리포트를 통해
42개 유효 핀 `HEX0..HEX5[0:6]`과 0개의 `HEX[7]` 핀을 확인하였으며, 물리 보드
수락을 통해 정상적인 6자리 동작을 검증 완료했다 (`reports/evidence/p10-hex-s6/summary.md`, `P10-HEX-S6-EV-01`).

## 4. Register Map

| Offset | Register | Access | Active bits | 의미 |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | decoder mode용 6개 hex nibble |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` | enable / raw mode |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | HEX2..HEX0 raw segment |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | HEX5..HEX3 raw segment |

활성 RTL(`APB_HEX_display.v`)은 전체 16-bit 슬롯 오프셋에 대해 완전 일치 디코드를 수행한다:

```verilog
PADDR[15:0]
```

슬레이브는 `PADDR[15:0]`을 정확히 `16'h0000`, `16'h0004`, `16'h0008`, `16'h000C`와
비교한다. 비정렬 및 과거 미러 오프셋을 포함한 모든 비정규 로컬 오프셋은
읽기 시 0을 반환하고 쓰기 시 side effect가 없어 레지스터나 물리 출력을
변경하지 않는다. `PREADY=1`은 유지되며 `PSLVERR` 포트는 추가하지 않는다.

SoC 인터커넥트 레벨에서 AHB/APB 브리지의 슬롯 7 allowlist는 이 네 가지 정규
오프셋만 전달한다. 비정규 CPU 접근은 HEX `PSEL` 인가 없이 차단되어 브리지의
2사이클 AHB ERROR 경로(`HRESP=01`)를 따른다. 로컬 슬레이브 exact decode와
CPU 브리지 경유 ERROR 경로는 모두 검증 완료되었다 (S2, S5).

현재 APB에는 `PSTRB`가 없으므로 software contract는 32-bit MMIO access이다.

## 5. `HEX_VALUE` — Decoder Mode

Packing:

```text
VALUE[ 3: 0] -> HEX0
VALUE[ 7: 4] -> HEX1
VALUE[11: 8] -> HEX2
VALUE[15:12] -> HEX3
VALUE[19:16] -> HEX4
VALUE[23:20] -> HEX5
```

예를 들어:

```text
VALUE = 0xABCDEF
```

이면 물리 display는:

```text
HEX5 HEX4 HEX3 HEX2 HEX1 HEX0
 A    B    C    D    E    F
```

로 보인다.

Write `[31:24]`는 버려지고 read에서는 0으로 반환된다.

### 5.1 Hex Decoder

각 nibble은 `0..F` 전체를 지원한다.

| Hex | `{g,f,e,d,c,b,a}` |
|---:|---|
| `0` | `1000000` |
| `1` | `1111001` |
| `2` | `0100100` |
| `3` | `0110000` |
| `4` | `0011001` |
| `5` | `0010010` |
| `6` | `0000010` |
| `7` | `1111000` |
| `8` | `0000000` |
| `9` | `0010000` |
| `A` | `0001000` |
| `B` | `0000011` |
| `C` | `1000110` |
| `D` | `0100001` |
| `E` | `0000110` |
| `F` | `0001110` |

## 6. `HEX_CTRL`

| Bit | 이름 | 의미 |
|---:|---|---|
| 0 | `ENABLE` | `1`: display 출력, `0`: 6개 digit 모두 blank |
| 1 | `RAW_MODE` | `0`: decoder mode, `1`: raw segment mode |
| 31:2 | Reserved | Owner-approved RAZ/WI: 예약 bit는 write 무시·항상 0 read, 같은 valid write의 `[1:0]`은 정상 반영 |

활성 RTL은 2비트 기능 필드 `ctrl_reg[1:0]`만 저장한다.
예약 비트 `[31:2]`는 RAZ/WI (Read-As-Zero / Write-Ignored)이다: `HEX_CTRL` 쓰기 시
`PWDATA[1:0]`만 래치되고 `[31:2]`는 무시되며, 읽기 시 `{30'b0, ctrl_reg[1:0]}`을 반환한다.
상위 비트에 0이 아닌 값을 쓰는 경우에도 `[1:0]` 기능 비트는 정상 갱신되며 저장된 상태나
출력을 훼손하지 않는다. 펌웨어 드라이버 쓰기는 `& HEX_CTRL_MASK` (`0x3`)를 강제한다.

### 6.1 Disable

`ENABLE=0`이면 모든 digit은:

```text
7'b1111111
```

로 강제되어 blank가 된다.

Disable은 VALUE/RAW register나 RAW_MODE를 clear하지 않는다. 다시 enable하면 저장되어 있던 mode/data가 복구된다.

## 7. Raw Segment Mode

`RAW_MODE=1`일 때 hexadecimal decoder 대신 raw register가 직접 출력된다.

### `HEX_RAW_LOW`

```text
[ 6: 0] -> HEX0
[13: 7] -> HEX1
[20:14] -> HEX2
```

### `HEX_RAW_HIGH`

```text
[ 6: 0] -> HEX3
[13: 7] -> HEX4
[20:14] -> HEX5
```

각 7-bit field의 order는 동일하게:

```text
{g,f,e,d,c,b,a}
```

이다.

예:

```text
1111111 -> blank
0000000 -> 모든 segment ON
1000000 -> digit 0 pattern
```

Raw mode는 decimal point, brightness, blink, per-digit enable을 제공하지 않는다.

## 8. Reset Behavior

Reset 시:

```text
VALUE     = 0x000000
CTRL      = 0x00000001
RAW_LOW   = blank x3
RAW_HIGH  = blank x3
```

따라서 functional reset state는:

```text
ENABLE   = 1
RAW_MODE = 0
VALUE    = 000000
```

이다.

즉 reset 이후 의도된 visible state는 blank가 아니라 **`000000`**이다.

## 9. Update Timing

Register write는:

```text
PSEL && PENABLE && PWRITE
```

인 PCLK edge에서 반영된다.

HEX output은 register의 combinational decode/mux 결과다.

```text
APB write
  -> register
  -> decode/mux
  -> HEX0..HEX5
```

6개 digit을 multiplex scan하는 별도 FSM은 없다.

Decoder mode VALUE는 하나의 24-bit register라 한 write로 6개 digit이 함께 갱신된다.

Raw mode는 RAW_LOW/RAW_HIGH 두 번의 write가 필요하므로 두 write 사이에 old/new pattern이 섞여 보일 수 있다. 원자성이 필요하면 잠시 display를 disable하고 두 raw register를 쓴 후 enable하는 것이 안전하다.

## 10. Firmware Contract

Active driver:

```text
firmware/drivers/hex_display.c
firmware/include/hex_display.h
```

주요 API:

```text
hex_display_enable()
hex_display_set_raw_mode()
hex_display_write_value()
hex_display_write_raw()
hex_display_write_monitor()
hex_display_read_value()
hex_display_read_ctrl()
```

Decoder mode 권장 sequence:

```c
hex_display_enable(1);
hex_display_set_raw_mode(0);
hex_display_write_value(value & 0x00ffffffu);
```

Raw mode 권장 sequence:

```c
hex_display_write_raw(raw_low, raw_high);
hex_display_set_raw_mode(1);
hex_display_enable(1);
```

### 10.1 CTRL Shadow

현재 firmware driver는:

```c
static uint32_t hex_ctrl_shadow = HEX_CTRL_ENABLE;
```

를 유지한다.

펌웨어 드라이버(`hex_display.c`)는 `HEX_CTRL`의 단일 소프트웨어 작성자(sole software writer)이다.
애플리케이션 및 ISR의 직접 쓰기는 금지된다. 드라이버는 루틴 하드웨어 RMW 대신 Shadow 구조를
유지한다. Shadow 및 하드웨어 쓰기는 `& HEX_CTRL_MASK` (`0x3`)를 엄격히 적용한다.

초기화 및 재동기화 API가 공식 구현되었다:

```c
/* firmware/include/hex_display.h */
void hex_display_init(void);
void hex_display_resync(void);
```

- `hex_display_init()`: 부팅 Shadow(`0x1`)를 확립하고 하드웨어 `CTRL = 0x1`을 쓴다.
- `hex_display_resync()`: 실행 중 HEX 하드웨어 단독 리셋이 발생하거나 out-of-band 변경이
  의심되는 경우, 호출자는 다음 CTRL 갱신 전에 `hex_display_resync()`를 호출한다.
  하드웨어 `HEX_CTRL`을 읽어 `& HEX_CTRL_MASK`로 마스킹한 뒤 `hex_ctrl_shadow`를 갱신한다.

이는 자동 리셋 감지를 의미하지 않으며 드라이버 외 직접 쓰기를 허용하지 않는다. 향후
멀티 컨텍스트/ISR 사용 시에는 드라이버 접근을 직렬화해야 한다.

## 11. Monitor Packing

`hex_display_write_monitor()`의 firmware convention:

```text
HEX5 = mode
HEX4 = state
HEX3 = retry_count
HEX2 = err
HEX1 = rx_seq
HEX0 = tx_seq
```

즉:

```text
[23:20] mode
[19:16] state
[15:12] retry
[11: 8] error
[ 7: 4] rx sequence
[ 3: 0] tx sequence
```

이다.

이건 firmware convention일 뿐 RTL에 별도 monitor state가 있는 것은 아니다.

## 12. Readback Limitation

VALUE/CTRL/RAW register는 모두 read 가능하다.

하지만 register readback 성공은 다음을 증명하지 않는다.

```text
physical segment illumination
pin continuity
board polarity
stale DP constraint 동작
```

실제 물리 표시 검증에는 board observation 또는 pin-level measurement가 필요하다.

## 13. Validation Evidence

HEX display 주변장치는 S0부터 S6까지 전 계층에 걸쳐 완전한 검증 및 수락 체인을 갖추고 있다:

1. **S0 독립 APB 베이스라인 (`tb_hex_s0_apb.sv`):** 리셋 값, PREADY, 정규 레지스터 접근, ACCESS 전용 쓰기, ENABLE 블랭킹/복구, 의도적 오류 주입 거부를 포함한 71개 체크 검증 완료.
2. **S1 CTRL RAZ/WI (`tb_hex_s1_ctrl_razwi.sv`):** `[31:2]` 쓰기 무시 및 0 읽기 확인 (`[1:0]` 영향 없음).
3. **S2 Exact Offset Decode (`tb_hex_s2_exact_decode.sv`):** `PADDR[15:0]` 4개 오프셋(`0x0000`, `0x0004`, `0x0008`, `0x000C`) 완전 일치 디코드 및 모든 미매핑/비정렬/미러 오프셋의 읽기 0·쓰기 side effect 없음 확인.
4. **S3 펌웨어 Shadow 호스트 스위트 (`hex_s3_shadow_host.c`):** 부팅 초기화(`hex_display_init()`), 리셋 후 재동기화(`hex_display_resync()`), 마스크 강제(`& 0x3`), 단일 소유자 Shadow 무결성 검증.
5. **S4 디렉티드 기능 스위트 (`tb_hex_s4_functional.sv`):** 1,774개 체크를 통해 각 자리별 16개 16진수 패턴, active-low raw 극성, 단일/멀티 세그먼트 패킹, 블랭킹, 모드 전환 검증 및 3종 뮤테이션 스위트 100% 검출.
6. **S5 인터커넥트 및 CPU E2E 스위트 (`tb_hex_s5_*.sv`):**
   - Tier L1 (Bridge): 4개 정규 오프셋 zero-wait 전달, 비정규 오프셋 억제 및 2사이클 AHB ERROR 검증.
   - Tier L2 (SoC Bus): 버스 상호연결 및 타 슬레이브 트래픽 중 지속적 불변성 검증.
   - Tier L3 (CPU E2E): RV32I load/store 실행, 비정규 오프셋에 대한 사이클 단위 access fault 예외(cause 5/7) 및 정밀 MEPC 정렬 확인.
7. **S6 FPGA 빌드 및 물리 수락 (`P10-HEX-S6-EV-01`):**
   - Quartus Prime Lite 19.1 Fitter Pin 리포트: 42개 유효 핀 `HEX0..HEX5[0:6]`, 0개 `HEX[7]` 확인.
   - MAX 10 DE10-Lite 보드 수락 앱(`firmware/apps/s6_hex_board_acceptance.c`)을 통해 B0~B6 상태 및 반복 B1/B2 회귀 체크를 확인, 사진 시퀀스 B0~B8을 `reports/evidence/p10-hex-s6/summary.md`에 문서화 완료 (OWNER_CONFIRMED).

## 14. Interrupt / Error

현재 HEX peripheral:

```text
IRQ          none
error status none
PREADY       1
```

이다.

비정규 로컬 오프셋은 0을 반환하고 쓰기를 무시한다. 프로덕션 브리지는
HEX `PSEL` 인가 없이 비정규 CPU 요청을 차단하고 2사이클 AHB ERROR(`HRESP=01`)를
반환한다. HEX display에 IRQ를 추가하거나 버스 에러 토폴로지를 변경하지 않는다.

display는 polling/configuration 스타일의 출력 주변장치이며 베이스라인에서
PLIC 소스로 할당되지 않는다.

## 15. Owner-Approved Cleanup Scope (Issue #3) — 상태 종결

1. **HEX-001 (VERIFIED):** 승인된 공개 `[6:0]` pin Tcl 유지; 최종 Quartus Fitter Pin 리포트(42개 핀, `[7]` 없음) 및 물리 보드 수락 B0~B8 확인 완료.
2. **HEX-002 (VERIFIED):** RAW mode 유지; 6개 필드, active-low 극성, 패킹, 마스킹, 읽기, disable/enable, 리셋을 S0, S4, S5, S6에서 독립 검증 완료.
3. **HEX-003 (VERIFIED):** CTRL `[31:2]` RAZ/WI RTL 구현 완료; 리셋 decoded `000000` 확인; `hex_display_init()` 및 `hex_display_resync()`를 포함한 단일 소유자 펌웨어 Shadow 구현 및 검증 완료.
4. **Local decode / APB-005 (VERIFIED):** RTL `PADDR[15:0]` exact decode 완료; 내부 미러 제거; 브리지 AHB ERROR 검증 완료.
5. **HEX-004 (DEFERRED):** DP, PWM, blink, 자리별 제어, atomic-RAW 기능은 별도 규격 없이 계속 DEFERRED 상태를 유지함.

## 16. Directed Verification

최소 regression:

1. reset CTRL=`0x1`, VALUE=`0`, RAW blank 및 decoded `000000`
2. VALUE `000000`, `123456`, `ABCDEF`, `FFFFFF`
3. HEX0=LS nibble, HEX5=MS nibble
4. ENABLE=0 -> all `1111111`
5. CTRL `[31:2]` RAZ/WI와 의도하지 않은 output 변화 없음
6. 모든 RAW field의 mapping/polarity/packing/masking/readback/blank/all-on,
   disable/enable 보존
7. decoder/RAW 전환과 active operation 중 reset
8. HEX-alone 비정규/비정렬/mirror offset의 read-zero/write-no-side-effect
9. CPU-through-production-bridge 비정규 요청의 PSEL suppression/AHB ERROR
10. Shadow initialization, HEX-only reset 뒤 explicit resync, ENABLE/RAW_MODE 보존
11. independent expected-model, failing-case runner, 실행/미실행 evidence 기록
12. 승인 후 generated-QSF/Pin Report와 source-matched FPGA board 관찰;
    static Tcl review는 physical PASS가 아님

## 17. Baseline Invariants

향후 approved spec이 대체하기 전까지:

1. `HEX_DISPLAY_BASE = 0x4007_0000`.
2. APB `PSEL[7]` peripheral이다.
3. `PREADY=1`.
4. 6개의 independent 7-segment digit을 구동한다.
5. active RTL output width는 `[6:0]`이다.
6. segment order는 active-low `{g,f,e,d,c,b,a}`이다.
7. VALUE LSB nibble은 HEX0, MS nibble은 HEX5다.
8. decoder는 `0..F`를 지원한다.
9. CTRL[0]=enable.
10. CTRL[1]=raw mode.
11. RAW_LOW=HEX0..2, RAW_HIGH=HEX3..5.
12. reset은 enabled decoder mode + `000000`이다.
13. decimal-point control은 active RTL에 없다.
14. interrupt source는 없다.
15. 과거 local QSF의 `HEXx[7]` assignment는 architectural feature가 아니다.
    승인된 공개 `[6:0]` pin configuration은 유지한다.
16. exact local-offset decoding(`PADDR[15:0]`)과 명시적 펌웨어 Shadow
    재동기화(`hex_display_init()`, `hex_display_resync()`)는 검증된 활성
    베이스라인 불변조건(active baseline invariant)이다.
