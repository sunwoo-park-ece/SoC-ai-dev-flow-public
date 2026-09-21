# SoC Firmware Contract — 한국어 Companion

> **P07 종결 주석(2026-09-16):** §38이 현행 UART/LoRa firmware 계약이며
> §§7–8의 과거 UART 관련 설명을 대체한다. User/Chat은 P07B를 Open
> Verification으로 승인했다. UART/LoRa sub-scope는 global `FW-002` 근거에
> 추가되지만 다른 peripheral wait가 남아 `FW-002`는 `OPEN`이다.

> **P06 종결 주석(2026-09-16):** 공개 Timer driver와 active application은 A5 command 계약을 사용한다. 아래 §37이 현재 public candidate의 Timer sequence이며 §9의 과거 sequence를 대체한다. User/Chat이 P06B evidence를 승인하여 `FW-004`는 VERIFIED이며 `FW-002`는 OPEN이다.

> **P04 종결 주석(2026-09-15):** 공개 펌웨어는 독립 GPIO(JP1), SW(슬롯 8), LED(슬롯 9) 드라이버를 사용한다. 과거 결합 사용은 이력이다. 공개 FW 빌드/호스트 스모크와 대응 구조 Quartus 피팅이 통과했다. User/Chat은 `FW-006/FW-011`을 `VERIFIED`로 승인했고, 명시적 보드 시험이 없는 `FW-005/FW-007`은 non-verified다.

> **상태:** DRAFT — 현재 baseline software contract와 baseline-cleanup 이후 적용할 승인된 target contract를 함께 정의한다.
>
> **정본 언어:** 영어. 이 문서와 `spec/19_firmware_contract.md`가 충돌하면 영문 canonical specification이 authoritative source이다.
>
> **관련 명세:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`, 각 peripheral spec, `board_io_architecture.md`.

## 1. 목적

Peripheral spec이 hardware register/signal의 동작을 정의한다면, 이 문서는 firmware가 SoC를 어떤 규칙으로 사용해야 하는지를 정의한다.

범위는 다음과 같다.

- startup / linker assumption
- MMIO access rule
- driver ownership
- peripheral initialization / service ordering
- polling / timeout
- current polling-only model
- target IRQ/PLIC 준비
- AES-GCM sequencing/authentication
- board-I/O migration
- error handling
- firmware verification

문서는 두 부분으로 구분한다.

```text
CURRENT BASELINE
    = 현재 FPGA/firmware가 실제로 따라야 하는 규칙

APPROVED TARGET
    = baseline cleanup 이후 적용할 승인된 규칙
```

Target rule은 현재 FPGA에 이미 구현됐다는 증거로 사용하면 안 된다.

---

# Part I — Current Baseline Firmware Contract

## 2. 실행 환경

현재 firmware는 bare-metal RV32I 환경이다.

Startup sequence:

```text
reset
  |
  v
_start
  |
  +--> sp = __stack_top
  +--> .bss를 32-bit store로 clear
  +--> main 호출
  |
  v
main return 시 infinite loop
```

현재 startup은 OS, thread/process, dynamic interrupt dispatch, 자동 peripheral initialization을 제공하지 않는다.

따라서 application이 사용하는 peripheral은 firmware가 명시적으로 초기화해야 한다.

## 3. Linker / Memory Contract

현재 linker memory는:

```text
IMEM  0x0000_0000 .. 0x0000_3FFF   16 KiB
DMEM  0x1000_0000 .. 0x1000_7FFF   32 KiB
```

Section 배치는:

```text
.start / .text / .init / .fini -> IMEM
.rodata / .data / .sdata       -> initialized DMEM image
.bss / .sbss / COMMON          -> startup이 clear
stack                           -> DMEM 상단
```

현재 구조에서는 initialized data를 IMEM에서 DMEM으로 runtime copy하지 않는다. 초기 DMEM 값은 FPGA memory image의 일부다.

따라서 firmware source/ELF와 선택된 IMEM/DMEM MIF는 하나의 firmware artifact로 취급해야 한다.

System reset이 DMEM 전체를 architectural하게 clear한다고 가정하면 안 된다. Firmware가 보장받는 것은 startup이 `.bss`를 clear한다는 것과 선택된 memory image에 포함된 initialized section뿐이다.

## 4. 현재 Canonical MMIO Map

```text
UART0_BASE       = 0x4000_0000
GPIO_BASE        = 0x4001_0000
TIMER_BASE       = 0x4002_0000
GSENSOR_BASE     = 0x4003_0000
AES_GCM_BASE     = 0x4004_0000
JOYSTICK_BASE    = 0x4005_0000
UART1_BASE       = 0x4006_0000
HEX_DISPLAY_BASE = 0x4007_0000
```

현재 APB는 `PSEL[7:0]`만 active하다. `0x4008_0000` 이후는 현재 FPGA baseline에서 SW/LED peripheral이 아니다.

Software는 `memory_map.md`와 각 peripheral spec이 정의한 canonical address만 사용해야 한다. RTL alias/register mirror는 software interface가 아니다.

## 5. MMIO Access Rule

### 5.1 APB peripheral

현재 normative rule:

> **APB peripheral register는 naturally aligned 32-bit read/write로 접근한다.**

현재 AHB-to-APB bridge는 `HSIZE`를 전달하지 않고 `PSTRB`도 없다. 따라서 byte/halfword store를 APB partial register write로 사용하면 안 된다.

`soc_mmio.h`에 `mmio_read8()` / `mmio_write8()`가 존재하지만 이것이 8-bit APB access를 architectural하게 만드는 것은 아니다.

### 5.2 VRAM byte-write caveat

VRAM은 APB가 아니라 AHB-side block이지만, active VGA write path 역시 일반적인 byte-enable contract를 제공하지 않는다.

P08B local candidate는 legacy `vram_write_byte()` helper를 제거한다. 신규 firmware는 aligned 32-bit framebuffer write와 software packing만 사용하며 byte-write/readback API는 지원하지 않는다.

### 5.3 Volatile

MMIO는 volatile semantics를 유지해야 한다. Application은 project MMIO helper 또는 peripheral driver를 사용하고 reserved/alias address를 임의 pointer로 접근하지 않는다.

## 6. Current Driver Ownership

현재 repo에는 이미 다음 driver가 있다.

```text
UART0/UART1   -> uart
GPIO          -> gpio
Timer         -> timer
VGA/VRAM      -> vram/display
AES-GCM       -> aes_gcm
ADC Joystick  -> joystick
HEX Display   -> hex_display
```

현재 baseline에서 모든 direct MMIO를 전면 금지하는 것은 아니지만, private software state를 갖는 driver와 application direct write를 섞으면 안 된다.

특히 HEX driver는 `hex_ctrl_shadow`를 유지한다. HEX driver를 사용하는 application이 `HEX_CTRL`을 직접 write하면 software shadow와 hardware state가 불일치할 수 있다.

## 7. Current Polling Model

현재 CPU에는 active external interrupt path와 PLIC이 없다. Peripheral service는 polling 기반이다.

현재 UART/LoRa sub-scope 밖에는 다음과 같은 unbounded wait가 남아 있다.

```text
Timer READY
VGA VSYNC
VGA clear busy
AES-GCM DONE
```

P07B는 normal UART TX와 LoRa AUX/TX entry point를 finite caller budget 또는
문서화된 finite default와 explicit result로 이관했다. 위의 남은 항목은 현재
구현 behavior이지 reliability 목표가 아니며 peripheral이 응답하지 않으면 CPU가
영구적으로 멈출 수 있다.

Forward progress가 필요한 diagnostic/application은 target bounded API가 도입되기 전까지 가능한 경우 status API를 이용해 자체 polling budget을 둔다.

## 8. UART0 / UART1

UART0는 baseline에서 LoRa-facing, UART1은 PC-facing이다.

TX 규칙:

```text
bounded TX_READY poll
-> UART_DATA write
```

Busy DATA write는 APB `PREADY` backpressure로 보호되며 TX가 가능할 때 정확히
한 번 수락된다. Firmware는 unbounded bus stall 대신 software timeout을 제공하기
위해 bounded ready check를 유지한다.

RX는 `RX_READY` 확인 후 `UART_DATA`를 읽는다. 현재 driver는 non-blocking RX와
bounded/status-returning TX helper를 제공하며 combined sticky RX error query와
`UART_STATUS[2]` W1C acknowledge API를 제공한다.

`UART_CONTROL`은 RAZ/WI이며 interrupt enable 기능으로 해석하면 안 된다.

## 9. Timer

현재 timer는 polling-only다.

새 interval을 시작할 때 안전한 software sequence는:

```text
1. stale READY clear
2. COMPARE program
3. enable
4. READY poll
5. 재사용 전 READY clear
```

새 compare를 쓰는 것만으로 기존 READY가 자동 clear된다고 가정하면 안 된다.

`timer_delay_cycles()`는 CPU nop loop이며 정확한 wall-clock API가 아니다.

## 10. VGA / VRAM

CPU-visible framebuffer는 back buffer다.

Normative access:

```text
0x2000_0000 .. 0x2000_95FF
aligned 32-bit write
```

Framebuffer readback을 지원한다고 가정하지 않는다.

일반 publish sequence는:

```text
back buffer draw 완료
-> VSYNC policy 확인/wait
-> SWAP request
```

HW clear 사용 시 `CLEAR_BUSY` / `CLEAR_DONE` contract를 따라야 하며 clear와 concurrent framebuffer write가 안전하다고 가정하면 안 된다.

VSYNC/clear infinite wait는 hang 가능성이 있으므로 fault-tolerant diagnostic에서는 bounded poll을 사용한다.

## 11. Legacy GPIO

현재 GPIO는 true bidirectional GPIO가 아니다.

```text
GPIO_DATA write -> output latch
GPIO_DIR=0 bit  -> DATA read에서 SW input 선택
GPIO_DIR=1 bit  -> DATA read에서 output latch 선택
```

현재 physical mapping:

```text
SW[9:0]       -> GPIO input
GPIO out[8:0] -> LEDR[8:0]
LEDR[9]       -> reset indicator
```

`gpio_led_write()`는 legacy pseudo-GPIO용 helper이지 generic GPIO API가 아니다.

GPIO register readback은 physical LED 동작을 증명하지 않는다.

## 12. G-sensor / Private SPI

현재 G-sensor는 hardware가 ADXL345 configuration과 private SPI acquisition을 수행한다. Firmware가 SPI transaction을 직접 시작하지 않는다.

Firmware는 canonical sensor data register를 aligned 32-bit로 읽는다.

현재 limitation:

- first-sample VALID 없음
- reset 직후 sample validity 보장 없음
- SPI→PCLK multi-bit CDC가 target coherent snapshot 구조가 아님
- X/Y와 Z가 별도 APB read
- sensor ODR보다 polling이 빠르면 repeated sample 가능

따라서 current firmware는 G-sensor 값을 best-effort telemetry로 다루며 atomic XYZ, sequence, timestamp를 주장하면 안 된다.

## 13. ADC / Joystick

현재 실제 ADC command owner는 top-level scanner이며 channel 1과 2를 반복 스캔한다.

따라서 current firmware는 board integration을:

```text
X = channel 1
Y = channel 2
```

로 사용한다.

`JOY_X_CHANNEL`/`JOY_Y_CHANNEL`을 다른 값으로 설정해도 실제 Qsys scanner channel이 바뀌는 것은 아니다. `JOY_CTRL.ENABLE=0`도 underlying scanner 자체를 멈추지 않는다.

`joystick_read()`는 direction/X/Y를 별도 APB read로 읽으므로 atomic sample이라고 주장하면 안 된다.

LEFT/RIGHT ASCII mapping은 physical polarity 확인 전까지 board/application convention으로 본다.

## 14. HEX Display

HEX driver를 사용할 때 driver가 CTRL shadow ownership을 갖는다. Owner-approved
cleanup target에서 `hex_display.c`는 `HEX_CTRL`의 단일 software writer이며
application/ISR direct write와 무단 concurrent writer는 금지한다. Shadow와
CTRL write는 `[1:0]`만 (`& 0x3`) 유지하고 normal helper는 hardware RMW가
아닌 Shadow 방식을 유지한다. 정상 system reset과 firmware initialization 후
hardware CTRL/Shadow는 `0x1`이다.

HEX-only reset 또는 out-of-band change가 의심되면 **다음 CTRL update 전**
hardware CTRL을 읽고 `& 0x3`으로 Shadow를 명시적으로 resynchronize하는
절차/API를 사용한다. 자동 reset detection, direct write의 허용, API 구현
완료를 뜻하지 않으며 future ISR/multi-context는 driver access를 직렬화한다.

Decoded mode packing:

```text
VALUE[3:0]   -> HEX0
...
VALUE[23:20] -> HEX5
```

`hex_display_write_monitor()`의 six-nibble layout은 firmware convention이지 hardware architecture가 아니다.

현재 decimal point는 firmware-visible 기능이 아니다.

## 15. AES-GCM

Current wrapper는 AES-128 + single 16-byte payload-window accelerator다.

### Length

Firmware가 반드시:

```text
0 <= LEN <= 16
```

을 enforce해야 한다. Hardware가 `LEN > 16`을 안전하게 reject한다고 가정하면 안 된다.

### Operation state

START 전에 KEY/IV/SEQ/LEN/PAYLOAD/TAG_IN(decrypt)을 모두 program한다.

`BUSY=1` 동안 operation input을 바꾸거나 START를 다시 issue하면 안 된다.

### Decrypt authentication

> `PAYLOAD_OUT`은 `DONE && TAG_OK && !ERROR`가 확인되기 전에는 authenticated plaintext로 사용하면 안 된다.

### IV uniqueness

Firmware/protocol이 sequence를 관리하며 동일 key 아래 동일 effective IV 재사용을 방지해야 한다.

### Key limitation

현재 accelerator는 secure key vault가 아니다. Key register는 software-visible이며 overwrite/reset 전까지 남을 수 있다.

## 16. Current Error Handling Limitation

현재 unmapped access는 경우에 따라 zero/OKAY로 완료될 수 있고 CPU access-fault path도 완전하지 않다.

따라서 runtime MMIO probing이 아니라 compile-time canonical map을 사용해야 한다.

AES ERROR, UART RX error 등은 peripheral status level에서 처리한다.

---

# Part II — Approved Target Firmware Contract

## 17. Target Principles

Cleanup 이후 firmware 공통 규칙:

1. canonical MMIO only
2. peripheral MMIO는 기본 32-bit aligned access
3. stateful register set은 한 driver가 ownership
4. application은 driver shadow/sequencing을 우회하지 않음
5. normal hardware-completion wait는 bounded
6. 실패 가능한 driver API는 explicit status/error return
7. interrupt peripheral은 local source를 resolve한 뒤 PLIC complete
8. authenticated crypto output만 consume
9. source/ELF/MIF/SOF를 reproducible artifact로 추적
10. RTL/DV/FPGA evidence가 생긴 target behavior만 active로 승격

## 18. Target APB / Board-I/O Map

Board-I/O migration 이후:

```text
0x4000_0000 UART0 / LoRa
0x4001_0000 GPIO
0x4002_0000 Timer
0x4003_0000 G-sensor
0x4004_0000 AES-GCM
0x4005_0000 ADC Joystick
0x4006_0000 UART1 / PC
0x4007_0000 HEX Display
0x4008_0000 SW
0x4009_0000 LED
0x400A_0000 .. 0x400F_FFFF Reserved
```

Target APB는 `PSEL[15:0]`이고 기존 slot 0~7 주소는 유지한다.

SW/LED constant는 해당 RTL integration과 같은 migration milestone에서 firmware에 추가한다.

## 19. Target Driver Ownership

```text
uart.*          -> UART0/UART1
 timer.*         -> Timer
 vram/display.*  -> VGA/VRAM
 gpio.*          -> external generic GPIO only
 sw.*            -> board SW + IRQ
 led.*           -> board LED
 gsensor.*       -> coherent sample API
 adc/joystick.*  -> coherent ADC/joystick API
 aes_gcm.*       -> validated crypto transaction
 hex_display.*   -> HEX + control shadow
```

Application은 stateful driver-owned register를 직접 write하지 않는다. Raw register definition은 bring-up/verification용으로 남길 수 있지만 normal app path는 driver를 사용한다.

## 20. Bounded Wait Policy

다음 operation은 normal API에서 bounded form 또는 non-blocking status API를 제공해야 한다.

```text
UART TX ready
Timer completion
VGA VSYNC
VGA clear
AES-GCM completion
future ready handshake
```

Timeout은 success처럼 넘어가지 않고 explicit error를 반환한다.

의도적으로 영구 block하는 함수가 필요하다면 debug/boot primitive라는 점을 이름/contract에서 명확히 한다.

## 21. Target GPIO / SW / LED

### GPIO

`GPIO_BASE = 0x4001_0000` 유지.

Target register:

```text
GPIO_DATA_IN
GPIO_DATA_OUT
GPIO_DIR
GPIO_IRQ_ENABLE
GPIO_IRQ_TYPE
GPIO_IRQ_POLARITY
GPIO_IRQ_BOTH_EDGE
GPIO_IRQ_PENDING
```

Target GPIO driver는 legacy `gpio_led_write()` semantics를 제공하지 않는다.

### SW

```text
SW_BASE = 0x4008_0000
```

`SW_DATA`, `SW_IRQ_ENABLE`, W1C `SW_IRQ_PENDING`를 사용한다.

Polling-only는 IRQ enable 0 + `SW_DATA` read로 충분하다.

### LED

```text
LED_BASE = 0x4009_0000
```

10-bit `LED_DATA` 전용 latch를 사용한다. Target에서는 `LEDR[9:0]` 전체가 LED driver 소유다.

## 22. Target Interrupt / PLIC Preparation

Local future IRQ:

```text
gpio_irq
sw_irq
```

PLIC integration 후 level source ISR ordering:

```text
1. PLIC claim
2. peripheral local pending/cause read
3. service
4. local source clear/resolve
5. local IRQ deassert 가능 상태 확인
6. PLIC complete
```

Local level이 계속 active인데 PLIC complete하면 즉시 재-pending될 수 있다.

PLIC source ID/MMIO/CSR/mcause는 future PLIC spec이 소유한다.

## 23. Target UART

TX-ready-before-write는 유지한다.

Forward progress가 필요한 caller를 위해 bounded TX API를 제공한다.

향후 IRQ 기반 UART가 추가되더라도 matching RTL/PLIC contract 검증 전에는 interrupt field를 firmware에서 사용하지 않는다.

## 24. Target Timer

Target timer driver가 stale READY/restart sequencing을 내부에서 책임진다.

Timing accuracy가 필요한 deadline/timeout은 CPU nop loop보다 검증된 timer-based budget을 우선한다.

Timer IRQ는 local IRQ + PLIC mapping이 별도 승인되기 전까지 추가하지 않는다.

## 25. Target VGA

Byte-write helper는 future bus/VGA가 실제 byte strobe를 지원하지 않는 한 remove/deprecate한다.

VSYNC/clear wait는 bounded API를 제공한다.

Application이 hardware-specific ordering을 중복 구현하지 않도록 publish helper가 draw/sync/swap/clear sequencing을 숨기는 방향을 권장한다.

## 26. Target G-sensor

RTL cleanup 후 firmware는 coherent PCLK-domain sample publication을 사용한다.

권장 abstraction:

```text
x
y
z
valid
sequence
```

첫 valid sample 전에는 no-sample/error semantics를 사용한다.

RTL reconstruction bug가 발견되면 software 보정이 아니라 RTL+spec을 수정한다.

Private ADXL345 SPI는 별도 generic SPI가 승인되기 전까지 hardware-owned다.

## 27. Target ADC / Joystick

Cleanup 후 software-visible channel/ENABLE semantics와 실제 ADC command owner가 일치해야 한다.

Target driver는 coherent X/Y + valid/sequence contract를 사용한다.

Board axis polarity/WASD mapping은 generic ADC acquisition과 가능하면 분리한다.

## 28. Target HEX

HEX driver가 CTRL의 단일 state owner다. application/ISR direct `HEX_CTRL`
write는 금지한다. 승인된 target은 routine hardware RMW 대신 Shadow를
유지하고 `[1:0]`만 보존하며, HEX-only reset 또는 out-of-band change 후
명시적 resynchronization을 요구한다. future multi-context에서는 이 단일
owner의 access를 직렬화해야 한다.

DP는 RTL/top/QSF가 명시적으로 확장되기 전까지 unavailable이다.

## 29. Target AES-GCM

Target driver는 다음을 직접 enforce한다.

```text
LEN <= 16
BUSY 중 START 금지
BUSY 중 input mutation 금지
bounded wait
decrypt는 DONE && TAG_OK && !ERROR 후에만 success
```

최소 error status:

```text
success
timeout
invalid length
hardware error
authentication failure
busy / invalid state
```

Sequence/IV uniqueness는 별도 HW allocator가 생기지 않는 한 firmware/protocol 책임이다.

Key zeroize hardware가 추가되면 driver가 해당 기능을 expose하고 key lifetime boundary에서 사용한다.

## 30. Target Error Handling

Firmware는 최소 다음을 구분해야 한다.

```text
invalid argument
busy/not-ready
timeout
peripheral error
auth failure
future bus/access fault
```

Valid data 0과 error 0을 혼동하는 generic zero return은 피한다.

Future fabric access-fault가 구현되기 전까지 reserved address를 probe하지 않는 원칙은 유지한다.

## 31. Build / Image Reproducibility

Firmware milestone은 최소 다음을 식별해야 한다.

```text
source commit
application
compiler/toolchain configuration
ELF
IMEM image
DMEM image
해당 image를 포함한 FPGA SOF
verification evidence
```

같은 RTL revision이라도 memory image가 다른 SOF에 test result를 자동 이식하면 안 된다.

## 32. Firmware Verification

Host/mock MMIO test에서 가능한 항목:

- address/order
- bit mask
- timeout
- error propagation
- software shadow
- GPIO/SW W1C
- AES validation/auth-failure

RTL/integration test는 실제 compiled MMIO sequence와 RTL behavior의 일치를 확인해야 한다.

FPGA board에서는 register readback만으로 증명할 수 없는 physical behavior를 별도로 확인한다.

예:

- external UART peer
- LED 10개
- SW 10개
- external GPIO pin
- HEX
- VGA
- sensor/ADC plausibility
- PLIC integration 후 IRQ

## 33. Migration Rules

```text
legacy GPIO SW read        -> sw driver
legacy gpio_led_write      -> led driver
legacy GPIO API            -> true external GPIO driver
PSEL[8]/[9] constants      -> matching RTL migration과 함께 추가
unbounded wait             -> bounded/status API
vram_write_byte            -> 승인된 A3에 따라 deprecate/remove
ADC fixed-scan assumption  -> coherent configured acquisition
G-sensor raw unsafe read   -> coherent valid sample API
AES caller assumption      -> driver-enforced validation
```

Transition compatibility wrapper는 허용할 수 있지만 cleanup milestone 종료 전에 제거하거나 명확히 isolate한다.

## 34. Cleanup Tracker로 전달할 Firmware Item

```text
FW-001  Unsupported peripheral/VRAM byte-write 사용 deprecate
FW-002  Bounded polling/timeout API 추가
FW-003  Driver ownership / direct-MMIO rule 정리
FW-004  Timer stale-READY/restart sequencing driver 수정
FW-005  Legacy GPIO SW/LED firmware를 gpio/sw/led로 분리
FW-006  RTL migration과 함께 SW/LED base constant 추가
FW-007  Final true-GPIO + IRQ register용 GPIO driver 구현
FW-008  G-sensor coherent sample API
FW-009  ADC/joystick coherent sample API
FW-010  AES argument/busy/auth/timeout hardening
FW-011  Legacy LEDR9 등 stale application assumption 제거
FW-012  Host MMIO regression + FPGA acceptance 갱신
```

Central cleanup tracker에서 ID는 재정규화할 수 있다.

## 35. Firmware Invariants

### Current

1. bare-metal / polling-oriented
2. active APB slot은 0~7
3. APB MMIO는 word-oriented
4. legacy GPIO가 현재 SW/LED 역할을 가짐
5. CPU/PLIC interrupt service 없음
6. G-sensor/ADC current coherency limitation 존재
7. AES caller가 length/sequencing/auth check 책임
8. current blocking wait는 unbounded일 수 있음
9. canonical address만 지원

### Target

1. approved 16-slot APB map
2. GPIO/SW/LED ownership 분리
3. GPIO/SW local PLIC-ready IRQ
4. normal wait는 bounded
5. stateful register는 single software owner
6. G-sensor/ADC coherent sample contract
7. AES driver가 validation/authentication enforce
8. exact memory image + FPGA image를 build artifact로 추적
9. PLIC source ID/CPU interrupt semantics는 future PLIC spec 소유

## 36. Current Source of Truth

```text
firmware/bsp/start.S
firmware/bsp/linker.ld
firmware/include/soc_memory_map.h
firmware/include/soc_mmio.h
firmware/drivers/uart.c
firmware/drivers/timer.c
firmware/drivers/gpio.c
firmware/drivers/vram.c
firmware/drivers/aes_gcm.c
firmware/drivers/joystick.c
firmware/drivers/hex_display.c
```

Hardware behavior는 각 canonical hardware spec이 authoritative하다. Current firmware와 hardware spec이 충돌하면 firmware가 hardware contract를 재정의하는 것이 아니라 cleanup defect로 기록한다.

## Phase 4A-2 승인된 firmware cleanup contract (일부 현행; P04 종결 주석 참조)

A1 generic GPIO는 JP1 GPIO_0–15의 16비트 DATA_IN/OUT/DIR/local IRQ이며 UART/LoRa pin은 분리, `gpio_irq`는 PLIC 전 CPU 미연결이다. P04가 해당 driver/map과 stale GPIO-LED assumption 제거를 구현했지만 `FW-005/FW-007`의 물리 보드 시험은 남아 있다. A2 invalid AHB/APB/DMEM/VGA/register 접근은 zero/OKAY가 아닌 fault; load/store cause 5/7, misalignment 4/6은 별개다. Driver는 canonical aligned offset/size만 사용한다. A3 framebuffer는 정렬된 32-bit `vram_write_word()`만 지원하고 `vram_write_byte()`는 제거/deprecate하며 readback API는 없다. A4 busy DATA write는 stall 후 1회 수락하므로 FW는 bounded TX_READY polling을 사용한다. UART_BAUD는 50 MHz divisor(default 434)이며 preset 외 안전 rate도 계산 가능하다. A5 `timer_start(N)` exact-N 계약과 A6 PCLK-only G-sensor visible contract는 각 owning evidence를 따른다. 언급하지 않은 계약은 종결 근거가 생길 때까지 target이다.

## Phase 4A-P05A 승인 Firmware-facing AUX Contract

Firmware는 UART0 status를 통해 synchronized E220-900T22D AUX level을 읽는다. `HIGH`이면 다음 LoRa UART-side write/transmission을 허용하고 `LOW`이면 허용하지 않는다. AUX readiness는 지속되는 level condition이며 rising-edge event가 아니므로 firmware는 project-level post-rising delay나 valid-window 의미를 추가하지 않는다. 기존 byte별 HIGH 확인 방향은 이 계약과 일치한다. Bounded polling/timeout, error handling, module-mode management는 별도 cleanup 범위이며 이 policy addendum은 firmware를 변경하거나 해당 항목을 종결하지 않는다.

## 37. Phase 4A-P06B 현재 Timer Firmware Contract

현재 driver는 command-oriented `timer_start(compare)`, `timer_stop()`, `timer_reload()`과 COUNT/STATUS/READY helper를 제공한다. `timer_start(compare)`는 COMPARE를 먼저 쓰고 START를 발행하며, 반복 호출도 항상 fresh hardware interval을 요청한다. STOP은 baseline STOP command를 쓰고 RELOAD는 programmed compare를 보존하면서 COUNT/RUNNING/READY를 명시적으로 지운다.

`final_main.c`는 `UINT32_MAX`를 긴 one-shot interval로 사용한다. Terminal에서 READY를 acknowledge한 뒤 fresh START를 명시적으로 발행하므로 W1C automatic resume에 더 이상 의존하지 않는다. Elapsed check는 visible maximum-to-zero re-arm 경계에서 unsigned subtraction을 유지한다.

`benchmark_main.c`는 Timer direct MMIO 대신 driver를 사용한다. Measurement setup은 RELOAD 후 START, 완료는 COUNT read 후 STOP 순서다. 과거 COMPARE=0/W1C automatic-rearm reset trick은 제거됐다.

`timer_wait_ready()`는 여전히 unbounded다. P06B는 `FW-002`를 종결하거나 바꾸지 않으며 Timer IRQ/PLIC 동작을 추가하지 않는다. Host mock-MMIO ordering test와 `final_main`/`benchmark_main` 실제 RV32I build는 PASS했고, User/Chat이 이 evidence를 승인하여 `FW-004`는 VERIFIED다.

## 38. Phase 4A-P07B 현행 UART Firmware Contract

UART baud programming은 217..65535만 MMIO write 후 success를 반환하고,
0..216은 write 없이 invalid argument를 반환한다. UART TX는 caller budget 기반의
finite put-character/buffer/string/hex API를 제공한다. Zero budget은 status read를
한 번도 하지 않고 DATA도 쓰지 않으며, timeout에서도 pending DATA write가 없다.

LoRa 송신은 각 byte마다 `AUX HIGH -> TX_READY -> DATA` 순서를 유지하고 AUX와
UART-TX에 별도 finite budget을 사용한다. 결과는 success, AUX timeout, UART TX
timeout, invalid argument를 구분한다. 기존 이름의 normal entry point도 무한 wait가
아니라 문서화된 finite default budget을 사용한다. Nonblocking RX는 유지하며 combined
sticky RX error query와 `UART_STATUS[2]` W1C acknowledge API를 제공한다.

`final_main`은 LoRa send 실패 시 현재 message를 중단하고 UART timeout error를
기록하며 PC debug output도 bounded status-returning helper를 사용한다. Benchmark도
bounded output을 사용하고 output failure를 board indication용 상태에 기록한다.
Diagnostic LoRa/UART application 역시 finite-default API를 사용하므로 별도 recovery
policy가 없더라도 driver에서 영원히 기다리지는 않는다.

Host mock-MMIO evidence는 immediate/eventual success, timeout, invalid, zero-budget,
W1C, LoRa ordering을 검증했고 영향받은 RV32I application build가 PASS했다. 이는
`FW-002`의 UART sub-scope evidence일 뿐이며 다른 peripheral wait가 P07B 범위 밖에
남아 있으므로 global `FW-002`는 OPEN이다. UART IRQ/PLIC 동작은 추가하지 않았다.

## P08B trap-policy 경계

Commit되지 않은 P08B candidate는 startup의 `mtvec` write commit 이후에만
firmware fail-stop handling에 의존한다. 모든 rebuild는 startup opcode
순서와 자체 trap symbol을 다시 검증해야 하며 application/VGA MMIO는 설치
이후에 수행한다. 그 이전 reset `mtvec=0x00006d60`은 canonical IMEM 밖에
있으며 `RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT`이라는 미검증
risk이다. Rejected VGA store를 retry/skip/`mepc` 증가/blind `mret` 또는
recoverable driver 결과로 처리하지 않는다.

## P09B G-sensor firmware 계약 — source/documentation 동시 게시 갱신

> **현행 Public 통합:** 이 API는 P09B source/documentation 동시 commit과 함께 현행 상태가 된다. tracker 종료나 물리 acceptance를 주장하지 않는다.

> **게시 정합성:** 이 API는 대응 P09B source commit과 함께 게시될 때만 현행 Public 문서가 된다. 최종 commit SHA, tracker 종료 또는 물리 acceptance를 주장하지 않는다.

이 절은 현재 Public `main` 구현 주장이 아닌 격리 P09B 후보 driver/RTL 계약이다. 공개 API는 정확히 `gsensor_status_t gsensor_read_sample(gsensor_sample_t *out)`이다. `gsensor_sample_t`는 `int16_t x, y, z` 및 `uint32_t seq` field를 갖고, `gsensor_status_t`의 결과는 정확히 `GSENSOR_OK`, `GSENSOR_NO_NEW`, `GSENSOR_BUSY`, `GSENSOR_ERROR` 네 가지다. Enum 숫자값과 padding은 MMIO ABI가 아니다. null `out`은 MMIO 없이 `GSENSOR_ERROR`를 반환한다. API는 단일 소유자·비재진입이며 다른 문맥의 HOLD를 RELEASE하지 않는다. 여기서 PLIC/센서 interrupt firmware 처리는 도입하지 않는다.

Polling은 순서가 보장된 volatile 32-bit MMIO를 사용한다: STATUS 1회 read → `HOLD_VALID=1`이면 CAPTURE/RELEASE 없이 `BUSY` → 아니면 `LIVE_VALID=0`이면 `NO_NEW` → `SNAP_CTRL=1` CAPTURE write → STATUS read로 `HOLD_VALID=1` 확인 → HOLD_SEQ → HOLD_XY_DATA → HOLD_Z_DATA → `SNAP_CTRL=2` RELEASE write → sample과 `OK` 반환이다. 두 조건이 모두 참이면 BUSY가 NO_NEW보다 우선한다. 새 LIVE가 없어 자격을 잃은 정상 CAPTURE는 APB OKAY no-op이며 CAPTURE 후 HOLD_VALID=0이면 RELEASE 없이 `NO_NEW`로 처리한다. 이전 HOLD를 새 sample로 반환하지 않는다. 예상 밖 protocol state나 알려진 로컬 driver 오류는 `ERROR`다. 잘못된/unmapped MMIO에서 발생하는 AHB ERROR는 trap policy상 CPU fault이지 통상적인 복구 가능 `GSENSOR_ERROR` 반환이 아니다. 호출자 측 경쟁 guard도 MMIO 전에 `BUSY`를 반환할 수 있다. 해당 호출이 성공적으로 획득한 HOLD만 해제한다. SEQ는 세대 식별·진단용으로 반환하고 last-seq 필터를 필수로 쓰지 않는다. STATUS read와 sample completion이 같은 edge면 pre-edge STATUS를 반환하고 다음 read에서 새 LIVE 세대가 보인다.

레지스터 폭, 동시 이벤트 우선순위, reset, 잘못된 접근 fault는 [G-sensor ABI](../12_gsensor.md)를 따른다. Stage 1 `NOT_RUN` 표시는 역사 기록이며, 격리 후보 host/RV32I test는 존재하지만 외부·reset-negative 범위를 승격하지 않는다.

P09B 공통 reset은 release가 clock-qualified여도 assertion은 비동기다. Firmware는 완료 전에 reset으로 중단된 MMIO read를 `OK`, `NO_NEW` 또는 유효한 과거 sample로 취급하거나 반드시 반환된다고 가정하지 않는다. CPU 자체가 그 transfer 중 reset될 수 있다. 이미 완료된 read는 이전 완료로 남는다. HOLD 소유 중 reset이면 HW가 HOLD/LIVE를 clear하고 sensor를 재초기화한다. 재부팅 뒤 stale sample/이전 소유권을 사용하거나 무소유 RELEASE를 실행하지 않는다. Controller는 historical 추가 local delay 없이 공통 `PRESETn` release에 12-write 초기화를 시작한다. APB는 첫 완료 sample 이전에도 접근할 수 있으나 VALID=0이다. 이는 격리 후보 동작이며 현행 Public `main` 동작이나 CPU reset을 건너는 software recovery 보장이 아니다.
