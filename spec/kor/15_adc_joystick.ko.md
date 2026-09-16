# Baseline SoC ADC Joystick Subsystem Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/15_adc_joystick.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. 목적

이 문서는 active FPGA baseline의 MAX10 ADC / joystick subsystem을 정의한다.

주요 범위는 다음과 같다.

- Intel/Qsys ADC IP와 project-local joystick logic의 경계
- 실제 top-level ADC command path
- APB-visible register contract
- ADC channel 및 12-bit sample semantics
- joystick center / dead-zone / direction 처리
- reset / clock / CDC behavior
- firmware 사용 규칙
- verification requirement
- 향후 PLIC/AXI 이전 baseline cleanup target

현재 구현에는 중요한 구조적 분리가 있다. `APB_ADC_Joystick_Controller` 내부의 ADC command generator는 **실제 ADC command interface에 연결되어 있지 않다.** 실제 Qsys ADC command stream은 SoC top-level의 별도 sequencer가 생성한다. 따라서 software-visible register 이름만 보고 command ownership을 판단하면 안 된다.

## 2. Active Architecture

Canonical base address:

```text
JOYSTICK_BASE = 0x4005_0000
APB slot      = PSEL[5]
```

Project-local RTL:

```text
rtl/peripherals/APB_ADC_Joystick_Controller.v
rtl/soc/AMBA_SoC_TOP.v
```

Vendor/Qsys implementation:

```text
비공개 vendor-project vault: adc_qsys generated IP (public tree에 없음)
```

Active datapath:

```text
                            board clk = 50 MHz
                                  |
                                  v
                             adc_qsys PLL
                            /            \
                           /              \
                adc_sys_clk = 25 MHz     ADC PLL clock = 10 MHz
                       |                         |
                       |                         v
                       |                    MAX10 ADC hard IP
                       |
      top-level fixed channel sequencer
      channel 1 <-> channel 2
                       |
                       v
                 Qsys command stream
                       |
                       v
                    adc_qsys
                       |
                Qsys response stream
                       |
                       |  project RTL에 explicit CDC 없음
                       v
PCLK = 50 MHz --> APB_ADC_Joystick_Controller --> CPU/APB
                       |
                       +-- X/Y raw registers
                       +-- center/dead-zone compare
                       +-- direction status
```

APB controller 내부 command output은 top에서 `*_unused` wire에만 연결되며 `adc_qsys`를 구동하지 않는다.

## 3. Clock / Reset Domain

### 3.1 PCLK domain

`APB_ADC_Joystick_Controller`:

```text
PCLK = 50 MHz
PRESETn = active-low
```

이 domain이 software-visible register, X/Y sample storage, valid flag, direction logic, sample counter를 소유한다.

### 3.2 Qsys ADC domain

Generated Qsys PLL configuration:

```text
c0 = 50 MHz / 2 = 25 MHz
c1 = 50 MHz / 5 = 10 MHz
```

Top-level은 c0를 `adc_sys_clk`로 사용하고, fixed channel sequencer도 이 clock에서 동작한다.

Qsys modular ADC의 command/response interface는 이 generated clock domain에 연결된다. Generated Qsys 내부에서는 PLL `locked`가 ADC control block에 연결되고 reset deassertion synchronizer도 생성되어 있다.

단, software-visible sample rate를 단순히 25 MHz에서 계산해서 contract로 사용하면 안 된다. conversion latency와 `command_ready` cadence는 vendor ADC subsystem behavior이다.

## 4. 실제 ADC Command Path

Active top-level command generation:

```verilog
assign adc_command_valid = HRESETn;
assign adc_command_startofpacket = 1'b1;
assign adc_command_endofpacket = 1'b1;

always @(posedge adc_sys_clk or negedge HRESETn) begin
    if (!HRESETn)
        adc_command_channel <= 5'd1;
    else if (adc_command_ready)
        adc_command_channel <=
            (adc_command_channel == 5'd1) ? 5'd2 : 5'd1;
end
```

따라서 reset release 이후:

```text
command_valid = 계속 1
SOP/EOP       = 계속 1
channel       = accepted command마다 1,2,1,2,...
```

즉 실제 ADC scan channel은 top RTL에서 **1과 2로 고정**되어 있다.

### 4.1 Software-visible channel register의 실제 의미

`APB_ADC_Joystick_Controller`에는:

```text
X_CHANNEL
Y_CHANNEL
CTRL.ENABLE
scan_axis
local adc_command_* outputs
```

이 존재하지만 local command output은 Qsys에 연결되지 않는다.

따라서 현재 baseline에서:

- `CTRL.ENABLE`은 실제 ADC conversion을 start/stop하지 않는다.
- `X_CHANNEL`, `Y_CHANNEL` write는 실제 scan channel을 바꾸지 않는다.
- 두 channel register는 Qsys response channel을 X/Y sample register 중 어디에 넣을지 분류하는 용도일 뿐이다.
- 1/2가 아닌 값으로 변경하면 실제 channel 1/2 response가 unexpected로 처리될 수 있다.

현재 firmware가 X=1, Y=2를 사용하기 때문에 top-level fixed scan과 우연이 아니라 현재 코드상 일치한다.

## 5. Vendor ADC Configuration

Generated MAX10 modular ADC interface:

```text
command channel width  = 5 bits
response channel width = 5 bits
response data width    = 12 bits
```

Generated configuration의 analog input mask는 `63`이며 active SoC는 그중 channel 1,2만 command한다.

현재 APB interface에는 general ADC channel scan list, reference, sample timing, conversion control register가 없다.

## 6. APB Interface

Peripheral은:

```text
PREADY = 1
```

이며 interrupt output이 없다.

Register decode는:

```text
PADDR[7:2]
```

를 사용한다.

Read-only/unimplemented offset write는 무시되고 APB error는 발생하지 않는다.

## 7. Register Map

| Offset | Register | Access | Reset | 의미 |
|---:|---|---|---:|---|
| `0x00` | `NAME0` | R | `"apb-"` | identification |
| `0x04` | `NAME1` | R | `"joy "` | identification |
| `0x08` | `VERSION` | R | `"0.01"` | wrapper version |
| `0x0C` | `CTRL` | R/W | `0` | local enable / clear command |
| `0x10` | `STATUS` | R | dynamic | local status + live ADC handshake |
| `0x14` | `X_CHANNEL` | R/W | `1` | X response classifier |
| `0x18` | `Y_CHANNEL` | R/W | `2` | Y response classifier |
| `0x1C` | `X_RAW` | R | 0 / invalid | X sample |
| `0x20` | `Y_RAW` | R | 0 / invalid | Y sample |
| `0x24` | `CENTER_X` | R/W | `2048` | X center |
| `0x28` | `CENTER_Y` | R/W | `2048` | Y center |
| `0x2C` | `DEADZONE` | R/W | `300` | common dead-zone |
| `0x30` | `DIR_STATUS` | R | dynamic | direction / valid |
| `0x34` | `SAMPLE_COUNT` | R | `0` | 모든 response-valid event 수 |
| `0x38` | `RESP_INFO` | R | dynamic | debug/live response info |

## 8. CTRL Register

Defined write bits:

```text
bit0 ENABLE
bit1 CLEAR_FLAGS
bit2 CLEAR_COUNT
```

### ENABLE

현재 `ENABLE`은 controller 내부의 **unused local command generator만** 제어한다.

다음을 제어하지 않는다.

```text
real Qsys command stream
ADC conversion
response capture
```

따라서 `ENABLE=0`을 ADC stop/power-down으로 해석하면 안 된다.

### CLEAR_FLAGS

`1` write 시:

```text
X_VALID
Y_VALID
unexpected_channel
```

을 clear한다.

### CLEAR_COUNT

`SAMPLE_COUNT`를 0으로 clear한다.

현재 `joystick_clear_flags()`는:

```text
ENABLE | CLEAR_FLAGS | CLEAR_COUNT
```

를 write하므로 local enable bit도 1로 만든다.

## 9. Response Capture

PCLK edge에서 `adc_response_valid`를 관측하면:

```text
last_response_channel <- response_channel
sample_sop/eop        <- response SOP/EOP
SAMPLE_COUNT          <- +1
```

그리고:

```text
response_channel == X_CHANNEL
→ X_RAW update, X_VALID=1

response_channel == Y_CHANNEL
→ Y_RAW update, Y_VALID=1

else
→ unexpected_channel=1
```

`SAMPLE_COUNT`는 X/Y pair 수가 아니라 **response beat 수**이다. unexpected response도 증가시킨다.

Timestamp나 pair sequence number는 없다.

## 10. X_RAW / Y_RAW

각 register:

```text
bit12    VALID
bits11:0 12-bit raw ADC
```

raw range:

```text
0..4095
```

Hardware는 voltage 변환이나 signed normalization을 수행하지 않는다.

X와 Y는 서로 다른 response event에서 update되므로 atomic pair가 아니다.

## 11. Center / Dead-Zone

Reset calibration:

```text
CENTER_X = 2048
CENTER_Y = 2048
DEADZONE = 300
```

현재 logic은 의미상:

```text
RIGHT    = X_VALID && X_RAW > CENTER_X + DEADZONE
LEFT     = X_VALID && X_RAW < CENTER_X - DEADZONE
FORWARD  = Y_VALID && Y_RAW > CENTER_Y + DEADZONE
BACKWARD = Y_VALID && Y_RAW < CENTER_Y - DEADZONE
```

이다.

RTL은 low-side compare를 `raw + deadzone < center`로 구현하여 unsigned subtraction underflow를 피한다.

Hysteresis, filtering, averaging, calibration routine은 없다.

## 12. DIR_STATUS

| Bit | Name | 의미 |
|---:|---|---|
| 0 | `FORWARD` | Y high |
| 1 | `BACKWARD` | Y low |
| 2 | `LEFT` | X low |
| 3 | `RIGHT` | X high |
| 4 | `X_VALID` | X sample 존재 |
| 5 | `Y_VALID` | Y sample 존재 |
| 31:6 | reserved | 0 |

Direction은 가장 최근에 저장된 독립적인 X/Y sample 조합으로 combinational하게 계산된다.

### Firmware mapping quirk

현재 firmware:

```text
FORWARD  -> 'w'
BACKWARD -> 's'
LEFT     -> 'd'
RIGHT    -> 'a'
```

이다.

일반적인 WASD 의미 기준으로 X축 LEFT/RIGHT 이름과 `a`/`d` mapping이 반대로 되어 있다. 실제 joystick physical orientation 때문에 의도한 것일 수도 있으나 현재 repository에서는 이것이 architectural invariant인지 검증되지 않았다.

향후 board polarity를 실제 측정해 naming과 firmware mapping을 정리해야 한다.

## 13. STATUS

Useful field:

| Bits | Field |
|---:|---|
| 0 | local `ENABLE` |
| 1 | local `scan_axis` |
| 2 | `X_VALID` |
| 3 | `Y_VALID` |
| 4 | unexpected-channel |
| 5 | live `adc_command_ready` |
| 6 | local `command_fire` |
| 7 | live `adc_response_valid` |
| 12:8 | last response channel |
| 17:13 | X classifier channel |
| 22:18 | Y classifier channel |
| 31:23 | zero/reserved |

`scan_axis`와 `command_fire`는 실제 top-level command path가 아니라 **unused local command generator의 state**다. 실제 ADC channel 진행상태로 사용하면 안 된다.

## 14. RESP_INFO

```text
bits11:0   live response_data
bits16:12  live response_channel
bit17      live SOP
bit18      live EOP
bit19      sampled SOP
bit20      sampled EOP
bits31:21  0
```

Live field는 coherent software snapshot이 아니다.

## 15. CDC Limitation

Qsys command/response interface는 `adc_sys_clk` domain이고 APB controller는 PCLK=50 MHz domain이다.

현재 top은 다음 신호를 explicit synchronizer/handshake/FIFO 없이 직접 연결한다.

```text
adc_command_ready
adc_response_valid
adc_response_channel[4:0]
adc_response_data[11:0]
adc_response_startofpacket
adc_response_endofpacket
```

따라서:

- response_valid pulse miss 가능
- channel/data multi-bit atomic capture 보장 없음
- local command logic의 ready sampling도 async
- RESP_INFO가 async live signal을 APB combinational read에 직접 노출

한다.

즉 현재 baseline에는 **ADC -> PCLK unresolved CDC defect**가 존재한다.

향후 ADC domain에서 complete response record를 capture한 뒤 handshake/toggle bridge 또는 small async FIFO로 PCLK에 넘기는 구조가 필요하다.

## 16. X/Y Coherency Limitation

현재 firmware `joystick_read()`는:

```text
DIR_STATUS read
X_RAW read
Y_RAW read
```

를 순차적으로 수행한다.

그 사이 ADC가 register를 update할 수 있으므로 한 함수 호출에서 서로 다른 시점의 값이 섞일 수 있다.

예:

```text
DIR_STATUS = sample A 기반
X_RAW      = sample B
Y_RAW      = sample C
```

Atomic X/Y snapshot이 없다.

향후 sequence number가 포함된 atomic pair publication 또는 capture/commit 구조가 필요하다.

## 17. Reset Behavior

APB controller reset:

```text
ENABLE             = 0
scan_axis          = X
X_VALID/Y_VALID    = 0
unexpected_channel = 0
X_CHANNEL          = 1
Y_CHANNEL          = 2
X_RAW/Y_RAW        = 0
CENTER_X/Y         = 2048
DEADZONE           = 300
SAMPLE_COUNT       = 0
```

그러나 top-level actual ADC command stream은 `adc_command_valid = HRESETn`이므로 reset release 즉시 자동 시작한다.

즉 reset 직후:

```text
APB ENABLE = 0
실제 ADC scan = 이미 동작
```

이라는 semantic mismatch가 있다.

## 18. Interrupt

현재 interrupt output과 PLIC connection은 없다.

CPU는 polling 방식이다.

향후 interrupt 도입 전 다음을 명세해야 한다.

```text
individual response IRQ vs X/Y pair-ready IRQ
sample overflow/loss
unexpected-channel/error
IRQ enable/status/clear
PLIC source ID
```

## 19. Firmware Contract

현재 firmware initialization:

```text
X channel = 1
Y channel = 2
CENTER_X/Y = 2048
DEADZONE = 300
```

Baseline firmware rule:

- aligned 32-bit MMIO 사용
- top-level scan 구조를 바꾸기 전에는 X/Y channel classifier를 1/2로 유지
- X_VALID와 Y_VALID 둘 다 확인한 뒤 direction command 사용
- `CTRL.ENABLE`이 ADC conversion을 stop한다고 가정하지 않음
- SAMPLE_COUNT 한 번 증가를 complete joystick sample 한 개로 해석하지 않음
- `STATUS.scan_axis`, `command_fire`, live RESP_INFO를 real command path indicator로 사용하지 않음

## 20. Verification Requirement

최소 directed regression:

1. reset register values
2. center/deadzone/channel APB R/W
3. response channel X/Y/unexpected classification
4. valid flag set/clear
5. sample count increment/clear
6. exact dead-zone boundaries
7. DIR_STATUS bit ordering
8. top-level command channel 1->2->1->2
9. APB controller command output이 Qsys에 연결되지 않았음을 integration-level check
10. 실제 board X/Y polarity
11. cleanup 후 asynchronous-clock CDC test/assertion
12. cleanup 후 atomic X/Y publication test

Quartus compile PASS나 일반 board demo만으로 현재 CDC safety가 입증된 것은 아니다.

## 21. Baseline Cleanup Targets

### High priority

1. **ADC command owner 단일화** — disconnected duplicate generator 제거
2. **ADC/Qsys -> PCLK CDC 수정** — valid/channel/data/SOP/EOP coherent transfer
3. command generation이 ADC domain 밖에 남으면 `command_ready` CDC 수정
4. **atomic X/Y sample + validity/sequence 추가**
5. **ENABLE semantics 실제화** 또는 register 제거/rename
6. **channel programming semantics 정리** — 실제 conversion channel을 제어하거나 read-only fixed config로 변경
7. **physical X/Y polarity 검증** 및 LEFT/RIGHT vs `a`/`d` mapping 수정

### Medium priority

8. ADC acquisition과 joystick policy 분리
9. sample-ready / overflow / error status 추가
10. calibration policy 정의
11. STATUS/RESP_INFO의 live async field 제거
12. PLIC 전 IRQ policy 정의
13. APB register alias/decode 정리
14. `reset_clock.md`와 일치하는 generated-clock/CDC timing constraint 추가

## 22. Recommended Future Architecture

```text
MAX10 ADC / Qsys
      |
      v
ADC acquisition engine (adc_sys_clk)
      |
      | coherent CDC record
      v
APB ADC peripheral (PCLK)
      |
      +-- raw samples
      +-- valid/sequence/error
      +-- channel configuration
      |
      +--> joystick policy block / firmware
```

즉 reusable ADC acquisition과 board-specific joystick interpretation을 분리하는 것이 적합하다.

## 23. Baseline Invariants

```text
APB base                     = 0x4005_0000
APB slot                     = 5
ADC response width           = 12 bits
real Qsys scan channels      = fixed 1 and 2
real command valid           = reset 후 계속 high
APB X/Y channel registers    = response classifier only
APB ENABLE                   = real scan control 아님
X/Y storage                  = independent / non-atomic
ADC/Qsys -> PCLK CDC         = unresolved
interrupt                    = 없음
software                     = polling
```

## 24. Related Specifications

- `soc_architecture.md`
- `memory_map.md`
- `apb_subsystem.md`
- `reset_clock.md`
- `interrupt_architecture.md`
- `firmware_contract.md` (planned)

## Phase 4A-2 승인된 external-I/O closure 목표 (board signoff 전)

STA-002에서 ADC top port를 실제 analog/digital 역할로 분류한다. Analog ADC pin에 가짜 digital `set_input_delay`를 주지 않는다. Generated ADC clock/reset 관계는 STA-001 소유다. ADC voltage/standard 및 VGA 인접 package placement critical warning을 검토하고 관련 VGA 동작 중 ADC 거동을 측정/정량화하며 잔여 warning risk를 명시적으로 처분한다. 양의 내부 slack은 ADC/board acceptance evidence가 아니다.
