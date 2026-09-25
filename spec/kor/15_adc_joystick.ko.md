# P11 ADC / 조이스틱 서브시스템 명세

> **상태:** P11 TARGET SPECIFICATION — 아키텍처/명세 동결 완료, RTL/FW/DV 구현 및 증적은 **(In-progress)**.
>
> **정본 언어:** 영어. 이 문서와 `../15_adc_joystick.md`가 충돌하면 영문 문서가 authoritative source이다.
>
> **소스 앵커:** P11 public worktree `P11-ADC-Cleanup`, HEAD `3be24514d87ed5d6e40361323e6ea8465a4645e6`.
>
> **Preflight:** Private Issue #4 `[P11A] ADC Cleanup Preflight`, report comment `issuecomment-5830820717`.

## 1. 목적과 범위

P11은 MAX 10 ADC 획득 기능과 보드/응용 수준의 조이스틱 해석을 분리한다.

```text
MAX 10 ADC / adc_qsys
        |
        v
ADC Acquisition Engine       재사용 가능한 획득/scan-frame owner
        |
        | coherent frame CDC
        v
APB_ADC_Controller           generic software-visible ADC peripheral
        |
        +--> raw ADC MMIO
        |
        +--> Joystick_Policy 단순 optional HW child
                  |
                  +--> FW에도 독립 policy/golden model 구현
```

P11 baseline은 polling 기반이며 ADC용 PLIC source/IRQ는 추가하지 않는다.

## 2. 최종 P11 구조

```text
                          KEY[0]
                             |
                             v
                system_reset_controller
                             |
                         HRESETn
                             |
          +------------------+----------------------+
          |                  |                      |
          v                  v                      v
      HCLK/PCLK          adc_qsys             reset_release_sync
       domain            vendor IP              adc_sys_clk
          |                  |                      |
          |          command / response             v
          |                  |                 adc_reset_n
          |                  |                      |
          |                  v                      v
          |        +-------------------------------------+
          |        | ADC Acquisition Engine              |
          |        |                                     |
          |        | sole command owner                  |
          |        | MAX_CHANNELS = 6                    |
          |        | baseline active = CH1 / CH2         |
          |        | sample[0..5]                        |
          |        | valid_mask[5:0]                     |
          |        | frame_seq[31:0]                     |
          |        | complete scan-frame assembly        |
          |        +------------------+------------------+
          |                           |
          |                   stable frame payload
          |                           |
          |                    req/ack mailbox
          |                           |
          |===========================|================ CDC
          |                           |
          |                          PCLK
          |                           |
          |                           v
          |                +--------------------+
          |                | ADC LIVE BANK      |
          |                +---------+----------+
          |                          | CAPTURE
          |                          v
          |                +--------------------+
          |                | ADC HOLD BANK      |
          |                +---------+----------+
          |                          |
          |              +-----------+--------------+
          |              |                          |
          |              v                          v
          |     Generic ADC MMIO             Joystick_Policy
          |                                  combinational
          |                                       |
          +---------------------------------------+
```

`ADC Acquisition Engine`은 Qsys command의 유일한 project-local owner, scan order, response 검증, partial frame, `frame_seq`, mailbox source를 담당한다.

`APB_ADC_Controller`는 slot-5 정확한 MMIO decode, ENABLE request/status, LIVE/HOLD, raw channel register, calibration, sticky error, `FRAME_COUNT`, APB error를 담당한다.

`Joystick_Policy`는 HOLD raw 값과 current calibration을 direction으로 변환하는 순수 combinational child이며 Qsys/APB/CDC를 알지 않는다.

## 3. Vendor 설정과 채널 매핑

P11A에서 확인된 현재 generated configuration:

```text
device                             = MAX 10 10M50DAF484C7G
Modular ADC mode                   = ADC control core only
board clk                          = 50 MHz
adc_sys_clk                        = 25 MHz
ADC hard-IP input                  = 10 MHz
sample width                       = 12 bit
channel width                      = 5 bit
analog input mask                  = 63 (CH1..CH6 enabled)
configured total sampling rate     = 1 MSPS
external reference                 = 2.5 V
TSD                                = disabled
```

1 MSPS는 실제 generated parameter에서 확인한 값이며 10 MHz clock으로부터 단순 추정한 값이 아니다.

Intel guide의 sample-rate/input-clock 조합 중 관련 항목:

| Total ADC rate | valid input clock |
|---:|---|
| 1 MSPS | 2 / 10 / 20 / 40 / 80 MHz |
| 500 kSPS | 10 / 20 / 40 MHz |
| 250 kSPS | 10 / 20 MHz |
| 200 kSPS | 2 MHz |
| 125 kSPS | 10 MHz |
| 100 / 50 / 25 kSPS | 2 MHz |

현재 P11 generated setting은 1 MSPS / 10 MHz이며 P11에서 vendor rate setting을 변경하지 않는다.

DE10-Lite 기준:

```text
CH1 -> ADC_IN0 -> JP8 A0
CH2 -> ADC_IN1 -> JP8 A1
CH3 -> ADC_IN2 -> JP8 A2
CH4 -> ADC_IN3 -> JP8 A3
CH5 -> ADC_IN4 -> JP8 A4
CH6 -> ADC_IN5 -> JP8 A5
```

Clean Baseline은 CH1/CH2만 활성화한다. 기본 logical joystick mapping은 CH1=X, CH2=Y이지만 실제 케이블/극성/방향은 board acceptance **(In-progress)**다.

## 4. ADC scan frame의 원자성

### 4.1 시간적으로 동시 샘플이 아니다

P11의 atomic scan frame은 모든 analog channel을 같은 시점에 샘플한다는 의미가 아니다.

```text
CH1 sample: t0
CH2 sample: t0 + Ts
...
CHN sample: t0 + (N-1)Ts
```

Atomicity는 다음만 보장한다.

- 하나의 HOLD에 서로 다른 scan generation이 섞이지 않는다.
- 완성된 scan frame 전체가 하나의 CDC payload로 이동한다.
- PCLK LIVE update는 한 frame 단위다.
- CAPTURE는 한 frame을 HOLD로 원자적으로 복사한다.

### 4.2 시간 관계

```text
Ts = 1 / Fs
first-to-last skew = (N - 1) * Ts
ideal N-channel frame sampling interval = N * Ts
```

| Intel sample-rate setting | Ts | 2ch skew | 2ch ideal interval | 6ch skew | 6ch ideal interval |
|---:|---:|---:|---:|---:|---:|
| 1 MSPS | 1 us | 1 us | 2 us | 5 us | 6 us |
| 500 kSPS | 2 us | 2 us | 4 us | 10 us | 12 us |
| 250 kSPS | 4 us | 4 us | 8 us | 20 us | 24 us |
| 200 kSPS | 5 us | 5 us | 10 us | 25 us | 30 us |
| 125 kSPS | 8 us | 8 us | 16 us | 40 us | 48 us |
| 100 kSPS | 10 us | 10 us | 20 us | 50 us | 60 us |
| 50 kSPS | 20 us | 20 us | 40 us | 100 us | 120 us |
| 25 kSPS | 40 us | 40 us | 80 us | 200 us | 240 us |

위 표는 Intel이 제공하는 predefined sample-rate 설정을 기준으로 한 skew 계산 예다. 각 rate가 현재 10 MHz ADC input과 모두 호환된다는 의미는 아니다. Intel guide에서 10 MHz input과 유효한 rate는 1 MSPS, 500 kSPS, 250 kSPS, 125 kSPS이고, 200/100/50/25 kSPS는 표의 2 MHz input 조합이다. 현재 실제 generated 조합은 **1 MSPS / 10 MHz**이다.

따라서 현재 ideal 값은:

```text
adjacent Ts = 1 us
CH1 -> CH2 ideal skew = 1 us
2ch ideal interval = 2 us
6ch first-last skew = 5 us
6ch ideal interval = 6 us
```

실제 P11 frame cadence는 command/response latency와 mailbox stall까지 측정한 뒤 확정하며 현재 **(In-progress)**다.

## 5. Acquisition Engine

```text
MAX_CHANNELS = 6
ACTIVE_MASK  = 6'b000011
scan order   = CH1 -> CH2
```

runtime channel programming은 P11 범위가 아니다.

완전한 baseline frame은 CH1과 CH2가 각각 한 번 정상 수집되고 `valid_mask=0x03`인 경우다. malformed/duplicate/unexpected/order/SOP-EOP error가 발생하면 partial frame을 폐기하고 SEQ를 증가시키지 않으며 error를 sticky로 남긴다.

`frame_seq`는 32-bit modulo counter이며 complete frame마다 정확히 한 번 증가한다.

## 6. ENABLE CDC

`ADC_CTRL.ENABLE`은 pulse가 아니라 PCLK의 stable persistent level이다.

채택 구조:

```text
ENABLE_REQ(PCLK)
  -> 2+FF level sync(adc_sys_clk)
  -> acquisition engine state
  -> ENGINE_ENABLED level sync back to PCLK
```

Enable 시 stale partial state를 버리고 CH1부터 새 scan을 시작한다.

Disable 인식 후에는 새 command를 발행하지 않고, 이미 accepted된 trailing response는 interface를 안전하게 정리하기 위해 받을 수 있으나 새로운 frame publication에 사용하지 않는다. partial frame을 폐기하고 LIVE eligibility를 무효화하며, 마지막 HOLD는 읽기 위해 보존한다.

## 7. ADC -> PCLK req/ack mailbox

완료 frame은 stable bundled-data req/ack toggle mailbox를 통과한다.

```text
source:
  frame payload write
  -> REQ toggle
  -> ACK까지 payload 고정

destination:
  REQ sync/detect
  -> LIVE one-edge capture
  -> FRAME_COUNT +1
  -> ACK return
```

P11에서는 mailbox busy 동안 source payload를 덮어쓰지 않으며 다음 frame publication을 진행하지 않는다. 필요하면 frame boundary에서 scan을 멈춘다.

Async FIFO가 필요한 경우:

- ACK 전에 여러 frame을 계속 생성해야 함,
- 모든 frame을 lossless하게 보존하면서 producer를 멈출 수 없음,
- destination stall이 길어도 acquisition 지속 필요,
- burst/high-throughput stream,
- DMA/SDRAM streaming,
- queue depth/overflow가 software-visible requirement가 됨.

현재 latest-state joystick/MMIO 용도에는 FIFO를 넣지 않는다.

## 8. LIVE / HOLD / CAPTURE-only

LIVE는 mailbox publication에서만 갱신된다. HOLD는 CAPTURE 또는 reset에서만 바뀐다.

```text
NEW_FRAME = LIVE_VALID && (!HOLD_VALID || LIVE_SEQ != HOLD_SEQ)
```

32-bit SEQ가 정확히 한 바퀴 돌아 동일 값이 되면 freshness를 구별할 수 없으므로 firmware는 하나의 HOLD를 2^32 published frame 동안 방치한 상태에서 이 predicate만 의존하지 않는다.

### CAPTURE 성공

`NEW_FRAME=1`이면 LIVE `{samples, mask, seq}` 전체를 HOLD로 한 PCLK edge에서 복사한다.

### 새 frame 없음

`NEW_FRAME=0`에서 CAPTURE는:

- 정상 OKAY,
- no-op,
- 기존 HOLD 보존,
- error bit set 없음.

새 sample 부재는 잘못된 MMIO가 아니라 정상 runtime state다. 따라서 `ERROR_STATUS`를 set하지 않고, 현재 HOLD를 consume/invalidate하지 않으며, `HOLD_SEQ`나 `FRAME_COUNT`를 변경하지 않는다. 이 정책은 firmware가 producer timing과 정확히 맞추지 못해도 CAPTURE polling을 bus fault로 바꾸지 않도록 한다.

| command 직전 상태 | CAPTURE 결과 | 완료 후 HOLD | bus/error |
|---|---|---|---|
| LIVE invalid, HOLD invalid | no-op | invalid/불변 | OKAY, error 없음 |
| LIVE invalid, HOLD valid | no-op | 이전 HOLD 유지 | OKAY, error 없음 |
| LIVE valid, HOLD invalid | LIVE copy | 새 valid HOLD | OKAY |
| LIVE valid, `LIVE_SEQ != HOLD_SEQ` | HOLD를 LIVE로 교체 | 더 최신 HOLD | OKAY |
| LIVE valid, `LIVE_SEQ == HOLD_SEQ` | no-op | 이전 HOLD 유지 | OKAY, error 없음 |

따라서 CAPTURE는 같은 LIVE generation에 대해 idempotent하다. Firmware는 `NEW_FRAME`을 먼저 확인한 뒤 CAPTURE하거나, 정상 polling 경로에서 CAPTURE를 직접 시도해도 같은 error semantics를 얻는다.

### G-sensor와 차이

```text
P09 G-sensor:
CAPTURE -> HOLD ownership -> RELEASE

P11 ADC:
CAPTURE -> HOLD
next CAPTURE -> HOLD replace
```

ADC는 latest analog-state snapshot이므로 RELEASE lifecycle을 두지 않는다.

## 9. Software-visible register map v2

```text
ADC_BASE = 0x4005_0000
32-bit aligned access only
```

| Offset | Register | Access | 의미 |
|---:|---|---|---|
| `0x00` | NAME0 | RO | `"apb-"` |
| `0x04` | NAME1 | RO | `"adc "` |
| `0x08` | VERSION | RO | `0x0002_0000` |
| `0x0C` | ADC_CTRL | RW/W1P | ENABLE/CAPTURE/CLEAR_ERROR |
| `0x10` | ADC_STATUS | RO | 상태 |
| `0x14` | FRAME_SEQ | RO | HOLD seq |
| `0x18` | VALID_MASK | RO | HOLD mask |
| `0x1C` | CH1_RAW | RO | HOLD CH1 |
| `0x20` | CH2_RAW | RO | HOLD CH2 |
| `0x24` | CH3_RAW | RO reserved | baseline 0 |
| `0x28` | CH4_RAW | RO reserved | baseline 0 |
| `0x2C` | CH5_RAW | RO reserved | baseline 0 |
| `0x30` | CH6_RAW | RO reserved | baseline 0 |
| `0x34` | LIVE_SEQ | RO | latest LIVE seq |
| `0x38` | LIVE_VALID_MASK | RO | latest LIVE mask |
| `0x3C` | ACTIVE_MASK | RO | baseline `0x03` |
| `0x40` | JOY_CENTER_X | RW | 2048 |
| `0x44` | JOY_CENTER_Y | RW | 2048 |
| `0x48` | JOY_DEADZONE | RW | 300 |
| `0x4C` | JOY_STATUS | RO | HW policy result |
| `0x50..0x5C` | reserved | none | ERROR |
| `0x60` | FRAME_COUNT | RO | PCLK LIVE publication count |
| `0x64` | ERROR_STATUS | RO | sticky error |
| `0x68..0xFC` | reserved | none | ERROR |

CH3~CH6 address는 지금부터 canonical하게 reserve한다.

### ADC_CTRL

```text
bit0 ENABLE       RW persistent level
bit1 CAPTURE      W1P
bit2 CLEAR_ERROR  W1P
```

### ADC_STATUS

```text
bit0 ENABLE_REQ
bit1 ENGINE_ENABLED
bit2 LIVE_VALID
bit3 HOLD_VALID
bit4 NEW_FRAME
bit5 MAILBOX_BUSY
bit6 ASSEMBLY_ACTIVE
bit7 ERROR_PENDING
```

### ERROR_STATUS

```text
bit0 UNEXPECTED_CHANNEL
bit1 DUPLICATE_CHANNEL
bit2 ORDER_ERROR
bit3 PACKET_ERROR
```

sticky이며 CLEAR_ERROR로 전체 clear한다. 같은 edge의 새 HW error는 set-dominant다.

`FRAME_COUNT`는 individual response나 CAPTURE 수가 아니라 **PCLK LIVE에 정상 publish된 complete frame** 수다.

## 10. APB error 정책

exact full local offset decode를 사용한다. `+0x100` 같은 mirror는 허용하지 않는다.

다음은 `PSLVERR` 및 bridge AHB ERROR로 연결되고 side effect가 없어야 한다.

- unsupported size/misalignment,
- RO write,
- reserved/unmapped offset,
- reserved bit를 포함한 malformed CTRL write.

반면 no-new CAPTURE는 OKAY/no-op이다.

## 11. Joystick_Policy HW child

개념 interface:

```text
hold_ch1[11:0]
hold_ch2[11:0]
hold_valid_mask[5:0]
center_x/y[11:0]
deadzone[11:0]
 -> forward/backward/left/right/x_valid/y_valid
```

순수 combinational이며 state/Qsys/APB/CDC를 갖지 않는다.

```text
JOY_STATUS = current policy parameters applied to current HOLD sample
```

따라서 HOLD가 그대로여도 center/deadzone write만으로 JOY_STATUS가 즉시 변할 수 있다.

Threshold는 13-bit widened arithmetic과 0..4095 clamp를 사용한다.

```text
RIGHT    = x_valid && x > min(4095, center_x + deadzone)
LEFT     = x_valid && x < max(0, center_x - deadzone)
FORWARD  = y_valid && y > min(4095, center_y + deadzone)
BACKWARD = y_valid && y < max(0, center_y - deadzone)
```

JOY_STATUS bit:

```text
0 FORWARD
1 BACKWARD
2 LEFT
3 RIGHT
4 X_VALID
5 Y_VALID
```

실제 physical polarity는 board evidence 전까지 **(In-progress)**다.

## 12. Firmware policy / golden model

FW에서도 raw HOLD + same calibration으로 독립적으로 policy를 계산한다.

```text
adc driver -> adc_frame_t -> joystick_policy_eval()
                           -> HW JOY_STATUS 비교 가능
```

FW expected result를 HW JOY_STATUS에서 역으로 만들면 안 된다. 두 구현은 독립 oracle 관계여야 한다.

ASCII/WASD 등 application mapping은 generic policy 위 계층에서 처리하며 historical LEFT->`d`, RIGHT->`a` mapping을 architectural invariant로 보존하지 않는다.

## 13. Reset architecture

```text
                             KEY[0]
                               |
                               v
                    +---------------------+
                    | System Reset        |
                    | Controller          |
                    | ~20 ms qualification|
                    +----------+----------+
                               |
                            HRESETn
                               |
             +-----------------+------------------+
             |                                    |
             v                                    v
        HCLK / PCLK                        generated domains
  이미 HCLK 기준 release                    ADC 예시
                                                  |
                                                  v
                                      reset_release_sync
                                          adc_sys_clk
                                                  |
                                                  v
                                            adc_reset_n
```

HCLK/PCLK는 이미 HCLK 기준 release이므로 별도 redundant reset synchronizer를 추가하지 않는다.

Project-owned ADC engine은 `adc_sys_clk` 기준 async-assert/sync-deassert `adc_reset_n`을 사용한다. Qsys 자체는 `HRESETn`을 vendor reset port로 받으며 내부 generated reset/PLL lock은 vendor boundary다.

PLL `locked`는 현재 project top으로 export되지 않는다. generated HDL을 hand edit해 export하지 않는다. Qsys lock-loss/ready behavior는 P11 verification **(In-progress)**다.

## 14. Verification / acceptance

P11 구현 후 최소 다음을 증명한다.

- sole command owner, CH1->CH2 order,
- ENABLE request/ack 및 disable partial-frame discard,
- 실제 vendor command->response cadence,
- unrelated clock phase에서 mailbox payload stability와 no torn frame,
- exact APB offset/PSLVERR/no mirror,
- CAPTURE success/no-new/back-to-back semantics,
- HW/FW policy equivalence,
- reset 중 partial/mailbox stale publication 금지,
- Quartus/TimeQuest generated-clock/reset review,
- JP8 center/X-Y polarity/direction board acceptance,
- VGA 동작 시 ADC plausibility 및 관련 warning disposition.

이 명세 동결만으로 어떤 항목도 Verified로 승격하지 않는다.

## 15. Tracker 연계

`ADC-001..006`, `CDC-003`, `FW-009`, `APB-005` ADC sub-scope는 모두 P11 implementation/evidence 전까지 **(In-progress)**다.

## 16. P11 완료 후 invariant

```text
slot/base                    = PSEL[5] / 0x4005_0000
peripheral identity          = generic ADC + optional joystick policy
sole command owner           = ADC Acquisition Engine
MAX_CHANNELS                 = 6
baseline active              = CH1, CH2
sample width                 = 12 bit
configured sample rate       = 1 MSPS
adc_sys_clk / ADC clock      = 25 MHz / 10 MHz
frame atomicity              = coherent publication, not simultaneous analog sample
ADC->PCLK CDC                = req/ack stable-payload mailbox
snapshot                     = LIVE + CAPTURE-only HOLD
RELEASE                      = none
ENABLE                       = stable level request + ack
CH3..CH6 MMIO                = reserved canonical raw offsets
HW policy                    = combinational child over HOLD
FW policy                    = independent golden/reference
IRQ                          = none
```

## 17. Historical / Pre-P11 Baseline

P11 이전에는:

- top scanner가 실제 CH1/CH2 command를 소유했고 APB wrapper에는 disconnected command generator가 중복 존재,
- `CTRL.ENABLE`이 실제 scan을 제어하지 않음,
- writable X/Y channel register가 실제 ADC conversion channel을 바꾸지 않음,
- response valid/channel/data/SOP/EOP가 `adc_sys_clk -> PCLK`로 직접 연결,
- X/Y가 독립 갱신되어 mixed generation 가능,
- live async response/debug field가 APB에 노출,
- software atomic frame/SEQ 없음,
- ADC acquisition과 joystick policy가 하나의 wrapper에 결합,
- LEFT/RIGHT ASCII mapping이 물리 polarity 확인 없이 뒤집힌 상태.

이 항목들은 provenance를 위한 historical note이며 P11 target을 제한하지 않는다.

## 18. 관련 문서

- `../00_soc_architecture.md`
- `../01_memory_map.md`
- `../05_apb_subsystem.md`
- `../06_reset_clock.md`
- `../19_firmware_contract.md`
- `../baseline_cleanup.md`
