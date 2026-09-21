# Baseline SoC HEX Display Specification — 한국어 Companion

> **상태:** DRAFT — 현재 RTL 동작과 Owner가 2026-09-21 Private Issue #3에서 승인한 HEX Cleanup 목표를 구분한다. 목표 계약은 구현·검증 증거가 아니다.
>
> **정본:** `spec/16_hex_display.md` 영문 명세. 충돌 시 영문 정본을 따른다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`.

## 1. 목적

이 문서는 활성 FPGA Baseline의 6자리 7-segment HEX peripheral과 승인된 Cleanup 계약을 정의한다. APB/MMIO, VALUE 및 RAW packing, active-low 출력, reset, FW 소유권, 보드 연결, 현재 증거의 한계와 검증 요구사항을 포함한다.

HEX Cleanup에서는 scan engine, PWM 밝기 제어, interrupt, DMA, decimal-point 제어를 추가하지 않는다.

## 2. Active Architecture

```text
HEX_DISPLAY_BASE = 0x4007_0000
APB slot         = PSEL[7]
CPU -> AHB -> AHB/APB bridge -> APB_HEX_display -> HEX0..HEX5[6:0]
```

활성 RTL은 `rtl/peripherals/APB_HEX_display.v`이며 VALUE, CTRL, RAW_LOW, RAW_HIGH, decoder/raw mux를 포함한다. `PCLK=HCLK=50 MHz`, 내부 CDC·IRQ 없음, `PREADY=1`이다.

## 3. Physical Display Contract

Top은 `HEX0[6:0]`부터 `HEX5[6:0]`까지 7비트씩 노출하고 decimal-point `[7]`은 노출하지 않는다. 비트 순서는 `{g,f,e,d,c,b,a}`이며 active-low로 `0`은 segment ON, `1`은 OFF다.

### 3.1 과거 QSF 불일치 및 승인된 현재 Pin 정책

Owner 확인에 따르면 **과거 로컬 QSF**에는 불필요한 `HEXx[7]` 할당이 있었으나, 이는 현재 공개 제약에도 남아 있다는 뜻이 아니다. 현재 공개 `fpga/quartus/constraints/de10_lite_pins.tcl`은 `HEX0..HEX5[6:0]`만 할당한다. Owner는 이 설정을 검토·승인했으며 **그대로 유지**한다.

`scripts/wsl/private_quartus.py`는 Private Quartus QSF를 생성하면서 공개 pin Tcl을 `source` 경로로 포함한다. 공개 Tcl에 존재하지 않는 `[7]`을 가정한 삭제 패치를 만들거나 DP 기능을 임의로 추가하지 않는다. 위 승인은 Pin 폭과 공개 설정에 대한 결정이다. 생성 QSF·Pin Report와 해당 소스에 연결된 실제 보드 HEX 검증은 아직 이번 Cleanup의 수행 증거가 아니다.

## 4. Register Map 및 주소 디코딩

유효한 정규 Offset은 네 개뿐이다.

| Offset | Register | Access | 기능 비트 | 설명 |
|---:|---|---|---|---|
| `0x00` | `HEX_VALUE` | R/W | `[23:0]` | 6개 decoder nibble |
| `0x04` | `HEX_CTRL` | R/W | `[1:0]` | ENABLE/RAW_MODE |
| `0x08` | `HEX_RAW_LOW` | R/W | `[20:0]` | HEX0..2 RAW |
| `0x0C` | `HEX_RAW_HIGH` | R/W | `[20:0]` | HEX3..5 RAW |

**현재 RTL:** 내부에서 `PADDR[3:2]`만 검사하므로 HEX 슬레이브에 직접 PSEL을 넣으면 16-byte 간격의 Mirror가 발생한다. **현재 생산 CPU 경로:** AHB/APB Bridge slot7 allowlist는 정규 네 Offset만 전달하며, 비정규 접근 시 HEX PSEL을 막고 기존 AHB ERROR 경로를 사용한다. 따라서 CPU가 Mirror를 정상 사용 가능한 것은 아니다.

**승인된 목표:** HEX 모듈 자체가 `PADDR[15:0]` **전체 Offset**을 `0x0000`, `0x0004`, `0x0008`, `0x000C`와 정확히 비교한다. 그 밖의 주소(비정렬 또는 과거 Mirror 포함)는 직접 PSEL을 받더라도 읽기 `0`, 쓰기 무부작용이어야 하며 모든 레지스터와 HEX 출력은 변하지 않는다. 기존 `PREADY=1`을 유지하고 새 `PSLVERR` 포트를 만들지 않는다. 생산 Bridge의 allowlist, PSEL 차단, AHB ERROR 경로는 변경하지 않는다. HEX 로컬 주소 거부 테스트와 CPU→Bridge 오류 테스트는 별도로 수행한다.

현재 APB에는 `PSTRB`가 없으므로 FW에서는 정렬된 32비트 MMIO만 지원한다.

## 5. `HEX_VALUE` — Decoder Mode

```text
VALUE[ 3: 0] -> HEX0
VALUE[ 7: 4] -> HEX1
VALUE[11: 8] -> HEX2
VALUE[15:12] -> HEX3
VALUE[19:16] -> HEX4
VALUE[23:20] -> HEX5
```

예를 들어 `0xABCDEF`를 쓰면 ENABLE=1·decoder mode에서 HEX5부터 HEX0까지 `ABCDEF`가 나타난다. 쓰기 상위 `[31:24]`는 버리고 읽을 때는 0을 반환한다.

### 5.1 Hex Decoder

각 nibble은 다음 active-low `{g,f,e,d,c,b,a}` 표의 `0..F` 전체를 지원한다.

| Hex | 패턴 |
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
| 0 | `ENABLE` | 1: 선택한 패턴 출력, 0: 여섯 자리 blank |
| 1 | `RAW_MODE` | 0: decoder, 1: RAW |
| 31:2 | Reserved | 승인된 **RAZ/WI**: 쓰기 무시, 읽기 항상 0 |

**현재 RTL:** 32비트 전체를 저장·재읽기하나 `[1:0]`만 출력에 사용한다. **Cleanup 목표:** 유효한 CTRL write에서 `PWDATA[1:0]`만 저장하고 `{30'b0,CTRL[1:0]}`으로 읽는다. 예약 비트에 1을 기록해도 내부 상태나 출력·향후 읽기값에 영향이 없어야 한다. FW는 예약 비트를 0으로 쓴다. 이 RAZ/WI 동작은 아직 구현·검증 완료 판정이 아니다.

### 6.1 Disable

`ENABLE=0`이면 각 출력은 `7'b1111111`로 blank가 된다. VALUE, RAW_LOW, RAW_HIGH, RAW_MODE는 보존되며 ENABLE을 다시 1로 하면 저장된 선택 패턴이 복구된다.

## 7. RAW Mode

RAW 모드는 이번 Cleanup에서도 **정식 지원을 유지**한다.

```text
RAW_LOW [ 6: 0] -> HEX0[6:0]
RAW_LOW [13: 7] -> HEX1[6:0]
RAW_LOW [20:14] -> HEX2[6:0]
RAW_HIGH[ 6: 0] -> HEX3[6:0]
RAW_HIGH[13: 7] -> HEX4[6:0]
RAW_HIGH[20:14] -> HEX5[6:0]
```

동일하게 `{g,f,e,d,c,b,a}` active-low이며 `1111111`=blank, `0000000`=전부 ON, `1000000`=숫자 0이다. RAW 쓰기 `[31:21]`은 무시하고 읽을 때 0이다. DP, brightness, blink, per-digit enable은 없다.

## 8. Reset Behavior

Owner가 기존 Reset 동작 유지를 명시적으로 승인했다.

```text
VALUE     = 0x000000
CTRL      = 0x00000001
RAW_LOW   = {3{7'b1111111}}
RAW_HIGH  = {3{7'b1111111}}
ENABLE    = 1
RAW_MODE  = 0
```

Reset 해제 후 표시는 blank가 아니라 decoder의 **`000000`**이다. RAW는 blank로 초기화되지만 RAW_MODE=0이므로 보이지 않는다. 목표 CTRL 예약 비트는 reset 및 readback에서 0이다.

## 9. Update Timing

유효한 쓰기는 PCLK edge의 `PSEL && PENABLE && PWRITE`에서 처리한다. Cleanup에서는 전체 Offset 일치 조건이 추가되어 비정규 쓰기는 반영되지 않는다. HEX 출력은 저장 레지스터의 조합 decode/mux 결과이며 scan FSM은 없다.

RAW_LOW/HIGH는 두 번의 독립된 write이므로 그 사이 구/신 패턴이 혼합될 수 있고 HW 원자성은 없다. VALUE는 한 번의 write로 6개 decoder nibble을 갱신한다.

## 10. Firmware Contract

기존 드라이버: `firmware/drivers/hex_display.c`, 헤더: `firmware/include/hex_display.h`.

현재 API: `hex_display_enable()`, `hex_display_set_raw_mode()`, `hex_display_write_value()`, `hex_display_write_raw()`, `hex_display_write_monitor()`, `hex_display_read_value()`, `hex_display_read_ctrl()`.

### 10.1 Decoder sequence

```c
hex_display_enable(1);
hex_display_set_raw_mode(0);
hex_display_write_value(value & 0x00ffffffu);
```

### 10.2 RAW sequence

```c
hex_display_write_raw(raw_low, raw_high);
hex_display_set_raw_mode(1);
hex_display_enable(1);
```

시각적으로 중간 패턴이 나타나지 않게 하려면 화면을 disable한 뒤 RAW_LOW/HIGH를 기록하고 mode 전환 후 다시 enable할 수 있지만 두 HW 쓰기가 원자적인 것은 아니다.

### 10.3 CTRL 단일 Owner, Shadow 및 명시적 재동기화

**현재:** `hex_display.c`는 `static uint32_t hex_ctrl_shadow = HEX_CTRL_ENABLE`을 유지한다. 다른 코드의 직접 CTRL write나 FW 실행 중 HEX 단독 HW reset은 Shadow와 실제 CTRL을 불일치시킬 수 있다.

**승인된 목표:** `hex_display.c`만 `HEX_CTRL`에 쓰는 **유일한 SW Owner**다. Application/ISR의 직접 CTRL 쓰기와 통제 없는 병행 writer를 금지한다. 정상 helper를 매 호출마다 HW RMW로 변경하지 않고 기존 Shadow를 유지한다. Shadow와 CTRL write는 기능 비트 `[1:0]`만 사용한다(`& 0x3`). 정상 시스템 HW reset 및 FW 초기화 후 HW CTRL과 Shadow의 값은 모두 `0x1`이다.

Driver 초기화·재동기화 시점과 명시적 절차/API를 제공해야 한다. FW 실행 중 HEX HW만 reset되었거나 외부 변경이 의심되면 **다음 CTRL 변경 전에** HW CTRL을 read하고 `& 0x3`으로 Shadow를 갱신한다. 자동 HW reset 감지 기능을 가정하지 않으며, 재동기화 절차가 외부 직접 쓰기를 허용하는 것은 아니다. API 명칭·실제 구현은 아직 확정/구현 완료로 간주하지 않는다. 초기화, 별도 reset 후 명시적 재동기화, ENABLE/RAW_MODE 보존을 테스트한다. 향후 ISR/멀티 컨텍스트 사용 시 Driver 접근을 직렬화해야 한다.

## 11. Monitor Packing

`hex_display_write_monitor()`의 FW convention:

```text
HEX5 = mode
HEX4 = state
HEX3 = retry_count
HEX2 = err
HEX1 = rx_seq
HEX0 = tx_seq
```

VALUE packing은 `[23:20] mode`, `[19:16] state`, `[15:12] retry`, `[11:8] err`, `[7:4] rx_seq`, `[3:0] tx_seq`. RTL의 별도 Monitor 상태가 아니다.

## 12. Readback Limitation

네 개 정규 레지스터를 읽을 수 있다. VALUE `[31:24]`와 RAW `[31:21]`은 읽기 0이며, 목표에서는 CTRL `[31:2]` 및 비정규 로컬 Offset도 읽기 0이다. 레지스터 readback만으로 물리 segment 점등, Pin continuity, 보드 극성을 증명할 수 없으므로 별도 보드 관찰/Pin 측정이 필요하다.

## 13. Validation Evidence 및 한계

과거 `display_smoke` FW는 decoder mode에서 `b00701`을 출력하고 `000000`부터 `FFFFFF`까지 순회하면서 VALUE readback을 검사했다. 과거 보드 결과 문구에는 diagnostic SOF의 물리 동작 성공이 기록되어 있지만, 공개 Snapshot에는 이번 HEX Cleanup 후보의 소스·SOF와 연결할 충분한 보드 원본 증거가 없다.

과거 기록만으로 RAW 6개 필드, disable, CTRL RAZ/WI, 로컬 Mirror 제거, 생성 Pin Report 또는 현재 후보의 보드 동작을 PASS로 인정하지 않는다. 설계 승인과 정적 코드 검토 역시 시뮬레이션/보드 PASS가 아니다.

## 14. Interrupt / Error

HEX 모듈은 IRQ·로컬 ERROR status가 없고 `PREADY=1`이며 `PSLVERR` 출력도 없다. 목표 로컬 비정규 Offset은 read-zero/write-ignore로 처리한다. CPU 비정규 접근은 **생산 Bridge**가 차단해 기존 AHB ERROR를 반환한다. HEX Cleanup에서 IRQ 또는 새로운 버스 오류 인터페이스를 추가하지 않는다.

## 15. Owner 승인 Cleanup 범위 (Issue #3, 2026-09-21)

1. **HEX-001:** 과거 로컬 QSF의 stale `[7]`은 역사적 문제. 현재 공개 `[6:0]` pin Tcl 승인·유지와 `private_quartus.py`의 source 경로 명시. 공개 Tcl에 허구의 수정은 금지. 생성 QSF/Pin Report·보드는 별도 미검증 증거.
2. **HEX-002:** RAW 모드 유지. 여섯 필드 개별값, 매핑, active-low, 상위 비트, readback, disable/enable, reset 독립 검증.
3. **HEX-003:** CTRL `[31:2]` RAZ/WI, reset 표시 `000000` 유지, FW 단일 Owner Shadow + 초기화·명시적 재동기화; 정상 helper의 HW RMW 전환은 하지 않음.
4. **HEX 로컬 디코딩/APB-005 일부:** 전체 Offset 정확 비교, 비정규 읽기 0·쓰기 무부작용, PSLVERR 추가 금지, 생산 Bridge ERROR 계약 보존.
5. **HEX-004 DEFERRED:** DP/PWM/blink/per-digit/atomic RAW 신규 기능 없음.

이는 승인된 **요구사항**이며 구현·검증 완료 표시가 아니다. Tracker 상태는 독립 증거에 근거해 판단한다.

## 16. Directed Verification

Cleanup 회귀에서 독립적으로 확인할 항목:

1. Reset CTRL=`0x1`, VALUE=`0`, RAW blank 및 6자리 `000000`.
2. VALUE `000000`, `123456`, `ABCDEF`, `FFFFFF`; HEX0 LSB·HEX5 MSB와 decoder 전체 `0..F` 패턴.
3. ENABLE=0 전체 blank, 재활성 후 VALUE/RAW/Mode 보존.
4. RAW 여섯 필드에 상이한 패턴을 적용한 매핑·active-low, blank/all-on, readback 및 상위 비트 masking.
5. CTRL 예약 `[31:2]`에 1을 써도 RAZ/WI, 기능 비트만 readback, 무관한 출력 변화 없음.
6. decoder/RAW 전환 및 동작 중 reset 후 정상 상태.
7. HEX 모듈 단독 비정규/비정렬/Mirror 주소: 읽기 0·쓰기 무부작용·출력과 상태 보존, 정규 주소는 동작.
8. CPU→생산 Bridge 비정규 주소: PSEL 차단과 기존 AHB ERROR. 로컬 테스트와 별개로 확인.
9. FW 단일 Writer Shadow 기본 초기화, 모의 HEX 단독 reset 이후 명시적 resync, ENABLE/RAW_MODE 보존, 비인가 앱 직접 쓰기 금지.
10. 독립 Reference와 실제 출력 비교, 의도된 오류 사례로 checker 실패 검증, 실패 시 상위 Runner 비영 종료, 실행 커맨드와 소스 식별 및 미실행 항목 기록.
11. 별도 승인 후 생성 QSF/Pin Report와 소스 일치 FPGA 보드 decoder/RAW 관찰. 정적 Tcl 검토를 물리 PASS로 기록하지 않음.

## 17. Baseline Invariants

1. `HEX_DISPLAY_BASE=0x4007_0000`, `PSEL[7]`, `PREADY=1`.
2. 여섯 자리 `HEX0..HEX5[6:0]`, `{g,f,e,d,c,b,a}` active-low, DP 없음.
3. Decoder VALUE 최하위 nibble→HEX0, 최상위→HEX5, `0..F` 지원.
4. CTRL bit0 ENABLE, bit1 RAW_MODE, Cleanup 목표 `[31:2]` RAZ/WI.
5. RAW_LOW→HEX0..2, RAW_HIGH→HEX3..5, RAW 지원 유지.
6. Reset은 enabled decoder·표시 `000000`.
7. IRQ 없음, 생산 Bridge의 기존 비정규 AHB ERROR 보존.
8. 공개 Pin은 `[6:0]` 승인; 과거 로컬 QSF `[7]`은 현재 기능이 아님.
9. 모듈 내부 전체 Offset 정확 디코딩과 FW Shadow 명시적 재동기화는 RTL/FW 검증 전까지 **Cleanup 목표**다.
