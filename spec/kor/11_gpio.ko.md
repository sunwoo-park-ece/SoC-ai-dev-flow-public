# Baseline 및 Target SoC GPIO Subsystem Specification — 한국어 Companion

> **P04 종결 주석(2026-09-15):** Part I의 SW/LED 혼합 GPIO는 P04 이전 이력이다. 공개 소스에는 Part II의 JP1 GPIO_IO 16비트, 리셋 Hi-Z, 동기화 입력 및 로컬 IRQ가 구현되었다. 공개 검증과 사용자 실행 16/16 post-fit pin/OE 검토가 통과했고 User/Chat이 `BOARDIO-001/002`를 `VERIFIED`로 승인했다. 보드 기능과 전체 외부 전기/timing 종결은 `VER-005`, `STA-002`의 별도 gate다.

> **상태:** DRAFT — 1~16장은 P04 이전 baseline 이력이고, 17장 이후는 active P04 GPIO contract다. 보드/전기 승인은 별도다.
>
> **정본 언어:** 영어. 이 문서와 `spec/11_gpio.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`, `board_io_architecture.md`.

## 1. 목적

이 문서는 두 역할을 명확히 분리한다.

먼저 현재 active `APB_GPIO`가 실제로는 switch/LED를 묶은 pseudo-GPIO라는 baseline behavior를 기록한다.

그리고 baseline cleanup 이후에는 같은 APB 위치를 유지하면서 진짜 bidirectional GPIO로 교체하는 target contract를 정의한다.

```text
GPIO_BASE = 0x4001_0000
PSEL[1]
```

Target GPIO에서는 DE10-Lite `SW[9:0]`, `LEDR[9:0]` 연결을 제거하고 각각 `APB_SW`, `APB_LED`가 소유한다.

---

# Part I — Active FPGA Baseline

## 2. Active RTL 경계

현재 peripheral은:

```text
rtl/peripherals/APB_GPIO.v
```

이며 top-level에서는:

```text
PSEL[1] -> APB_GPIO
             |   |
             |   +--> gpio_in  <- SW[9:0]
             +------> gpio_out -> LEDR[8:0]

LEDR[9] <- ~HRESETn
```

으로 연결된다.

현재 `PREADY=1`이고 IRQ output은 없다.

## 3. Baseline Register Map

| Offset | Register | Access | Reset | 의미 |
|---:|---|---|---:|---|
| `0x00` | `GPIO_DATA` | R/W | output latch=`0` | output latch write / DIR 기반 mixed readback |
| `0x04` | `GPIO_DIR` | R/W | `0` | `1=output latch read`, `0=input read` |

`[9:0]`만 구현되며 현재 RTL은 `PADDR[3:2]`만 decode하므로 16-byte 간격 mirror가 생긴다. Mirror는 canonical address가 아니다.

## 4. Baseline DATA/DIR 의미

`GPIO_DATA` write는 direction과 무관하게 output latch를 바꾼다.

```text
gpio_out[9:0] <- PWDATA[9:0]
```

Read는:

```text
GPIO_DATA[i] = GPIO_DIR[i] ? gpio_out[i] : gpio_in[i]
```

이다.

따라서 현재 `GPIO_DIR`은 physical output-enable을 제어하지 않는 readback-source selector다.

## 5. Baseline Board Mapping

```text
SW[9:0]       -> gpio_in[9:0]
gpio_out[8:0] -> LEDR[8:0]
gpio_out[9]   -> physical LED 미연결
LEDR[9]       <- ~HRESETn
```

Logical bit 9 readback이 성공해도 physical `LEDR[9]` 변화는 보장하지 않는다.

## 6. Baseline Reset / CDC / IRQ

Reset:

```text
gpio_out = 0
direction = 0
```

SW 입력은 synchronizer 없이 직접 들어오며, debounce/event detector도 없다.

현재 GPIO는 polling-only이며 interrupt enable/type/polarity/pending register가 없다.

## 7. Baseline Firmware / Verification 의미

현재 `gpio_led_write()` 등은 legacy board-specific behavior에 속한다. Register readback은 physical LED pin 동작을 독립적으로 증명하지 않는다.

## 8. Baseline Invariants

1. `0x4001_0000 / PSEL[1]`.
2. Register는 DATA, DIR 두 개.
3. `GPIO_DIR`은 true direction이 아니다.
4. SW는 unsynchronized input이다.
5. LEDR[9]는 GPIO 소유가 아니다.
6. IRQ 없음.
7. Register mirror는 noncanonical artifact다.

## 9. Baseline Sources

```text
rtl/peripherals/APB_GPIO.v
rtl/soc/AMBA_SoC_TOP.v
firmware/include/gpio.h
firmware/drivers/gpio.c
firmware/apps/display_smoke.c
```

---

# Part II — Approved Target GPIO Contract

> **TARGET MIGRATION NOTE — 현재 FPGA baseline 아님:** 아래 내용은 approved cleanup target이다. RTL/FW/DV/FPGA 검증 완료 전에는 현재 구현 동작의 증거로 사용하면 안 된다.

## 10. Target Role

GPIO의 APB 위치는 유지한다.

```text
GPIO_BASE = 0x4001_0000
PSEL[1]
```

대신 `SW[9:0]`, `LEDR[9:0]` ownership은 제거하고 external bidirectional pin bank를 소유한다.

```text
GPIO_IO[GPIO_WIDTH-1:0]
```

## 11. GPIO Width

```text
1 <= GPIO_WIDTH <= 32
```

으로 parameterize한다.

모든 MMIO register는 32-bit이며:

```text
implemented bits = [GPIO_WIDTH-1:0]
upper read bits  = 0
upper write bits = ignored
```

으로 고정한다.

Register 구조는 parameterized지만 승인된 A1 DE10-Lite target은 16비트 JP1 GPIO_0–15 매핑으로 동결되었다.

## 12. Target Register Map

| Offset | Register | Access | Reset | 의미 |
|---:|---|---|---:|---|
| `0x00` | `GPIO_DATA_IN` | RO | sampled | synchronized physical pin level |
| `0x04` | `GPIO_DATA_OUT` | R/W | `0` | output latch |
| `0x08` | `GPIO_DIR` | R/W | `0` | `0=input/Hi-Z`, `1=output` |
| `0x0C` | `GPIO_IRQ_ENABLE` | R/W | `0` | pin별 IRQ enable |
| `0x10` | `GPIO_IRQ_TYPE` | R/W | `0` | `0=level`, `1=edge` |
| `0x14` | `GPIO_IRQ_POLARITY` | R/W | `0` | level: low/high, edge: falling/rising |
| `0x18` | `GPIO_IRQ_BOTH_EDGE` | R/W | `0` | edge mode에서 양 edge 검출 |
| `0x1C` | `GPIO_IRQ_PENDING` | R/W1C | `0` edge pending | effective pending view |

Target에서는 exact offset decode를 사용하고 legacy register mirroring을 만들지 않는다.

## 13. True Bidirectional Semantics

각 pin에 대해:

```text
GPIO_DIR[i] = 0
 -> output enable OFF
 -> peripheral 기준 input / Hi-Z

GPIO_DIR[i] = 1
 -> output enable ON
 -> GPIO_DATA_OUT[i] drive
```

개념적으로:

```verilog
assign GPIO_IO[i] = GPIO_DIR[i] ? GPIO_DATA_OUT[i] : 1'bz;
```

이다.

`GPIO_DATA_OUT`은 DIR과 무관하게 미리 write할 수 있다. 즉 output value를 preload한 뒤 DIR을 output으로 바꿔 의도치 않은 중간 출력값을 피할 수 있다.

## 14. Input Synchronization

모든 external GPIO input은 최소 2FF synchronizer를 통과한다.

```text
GPIO_IO[i]
  -> sync_ff1
  -> sync_ff2 = gpio_in_sync
```

`GPIO_DATA_IN`과 IRQ detector는 raw pin이 아니라 `gpio_in_sync`만 사용한다.

Output mode에서도 DATA_IN은 synchronized physical level을 읽을 수 있지만, 이를 electrical feedback 보장으로 해석하면 안 된다.

## 15. Direction 변경 시 IRQ Rule

`1 -> 0` 즉 output에서 input으로 바꿀 때 stale edge history 때문에 false edge IRQ가 발생하면 안 된다.

따라서 input 전환 시 현재 synchronized value로 edge history를 re-arm한 뒤 edge detect를 시작한다.

`0 -> 1` 즉 input에서 output으로 바꾸면 해당 pin은 IRQ qualification에서 제외하고 sticky edge pending도 clear한다.

## 16. IRQ Eligibility

Output pin은 IRQ source가 될 수 없다.

```text
input_mask = ~GPIO_DIR
```

IRQ logic은 input-configured pin만 대상으로 한다.

## 17. IRQ Type / Polarity

```text
GPIO_IRQ_TYPE[i] = 0 -> level
GPIO_IRQ_TYPE[i] = 1 -> edge
```

### Level mode

```text
POLARITY=0 -> active-low
POLARITY=1 -> active-high
```

Level pending은 sticky register가 아니라 현재 synchronized level condition이다.

### Edge mode

`BOTH_EDGE=0`이면:

```text
POLARITY=0 -> falling
POLARITY=1 -> rising
```

`BOTH_EDGE=1`이면 rising/falling 모두 event이며 POLARITY는 무시한다.

## 18. Sticky Edge Pending

Edge event는 sticky `edge_pending`을 set한다.

W1C와 새 event가 같은 cycle에 겹칠 경우 event가 우선한다.

```text
edge_pending_next = (edge_pending & ~w1c_mask) | edge_event
```

## 19. `GPIO_IRQ_PENDING`

Read는 edge sticky event와 live level condition을 합친 effective pending view다.

```text
edge_view  = edge_pending & IRQ_TYPE
level_view = level_active & ~IRQ_TYPE

GPIO_IRQ_PENDING = (edge_view | level_view) & ~GPIO_DIR
```

`IRQ_ENABLE`과 무관하게 pending 상태를 읽을 수 있다.

W1C는 **edge pending만 clear**한다.

Level source가 active한 동안에는 W1C를 해도 pending read가 계속 1이다. Level이 해제되어야 사라진다.

## 20. IRQ Output

```text
gpio_irq = |(GPIO_IRQ_PENDING & GPIO_IRQ_ENABLE)
```

특성:

- active-high
- level output
- PLIC-friendly
- enabled effective pending이 존재하는 동안 유지
- output-configured pin은 제외

PLIC source ID, priority, claim/complete, CPU CSR는 future PLIC spec에서 정의한다.

## 21. Reset

Target reset:

```text
GPIO_DATA_OUT      = 0
GPIO_DIR           = 0      // all input / Hi-Z
GPIO_IRQ_ENABLE    = 0
GPIO_IRQ_TYPE      = 0      // level
GPIO_IRQ_POLARITY  = 0      // active-low
GPIO_IRQ_BOTH_EDGE = 0
edge_pending       = 0
gpio_irq           = 0
```

Synchronizer warm-up 동안 static input 때문에 false edge event를 만들지 않는다.

## 22. APB / Firmware Contract

```text
PREADY = 1
```

32-bit aligned MMIO를 사용한다.

권장 init 순서:

```text
1. IRQ_ENABLE = 0
2. DATA_OUT preload
3. DIR 설정
4. IRQ_TYPE/POLARITY/BOTH_EDGE 설정
5. edge pending W1C
6. IRQ_ENABLE 설정
```

Legacy `gpio_led_write()` 같은 board-specific API는 LED peripheral 도입 후 제거한다.

Target driver는 DATA_IN/OUT/DIR/IRQ 기능을 분리한다.

## 23. Target Verification

최소 검증 항목:

1. reset에서 all input/Hi-Z
2. DATA_OUT preload 후 output 전환
3. true tri-state/output-enable
4. synchronized DATA_IN
5. output/input direction 전환
6. rising/falling/both-edge IRQ
7. active-high/active-low level IRQ
8. IRQ enable masking
9. edge W1C
10. same-cycle event+W1C set-dominant
11. active level은 W1C로 사라지지 않음
12. output pin은 IRQ source가 아님
13. output->input re-arm에서 false edge 없음
14. input->output에서 stale edge pending 제거
15. multiple source OR
16. exact register decode/no mirror
17. `gpio_irq` assertion/deassertion
18. board header input/output test

## 24. Target Invariants

1. GPIO는 `0x4001_0000 / PSEL[1]` 유지.
2. SW/LED는 GPIO에서 분리.
3. Module parameter 범위는 1~32이지만 DE10-Lite target은 `GPIO_WIDTH=16`, JP1 GPIO_0–15로 bind한다.
4. DIR=0 input/Hi-Z, DIR=1 output.
5. Input은 2FF sync 후 사용.
6. DATA_IN/OUT/DIR 분리.
7. Input pin만 IRQ source 가능.
8. Pin별 level/edge 선택 가능.
9. Rising/falling/both-edge 지원.
10. Edge pending은 sticky W1C + set-dominant.
11. Level pending은 live condition.
12. `gpio_irq`는 active-high level.
13. PLIC source ID는 별도 spec 소유.
14. Target register mirror는 금지.
15. GPIO는 reusable general-purpose digital I/O peripheral이다.

## 25. Related Target Architecture

```text
SW[9:0]   -> APB_SW  @ 0x4008_0000 / PSEL[8]
LEDR[9:0] <- APB_LED @ 0x4009_0000 / PSEL[9]
GPIO_IO[] <-> APB_GPIO @ 0x4001_0000 / PSEL[1]
```

전체 board-I/O ownership과 APB 16-slot migration은 `board_io_architecture.md`가 소유한다.

## Phase 4A-2 승인된 GPIO physical 목표 (P04 이후 현행)

A1은 `GPIO_WIDTH=16`, `GPIO_IO[0:15]` ↔ DE10-Lite JP1 `GPIO_[0:15]` 1:1이며 P04가 이를 구현·피팅했다. Ascending package pin은 `V10,W10,V9,W9,V8,W8,V7,W7,W6,V5,W5,AA15,AA14,W13,W12,AB13`. JP1 GPIO_27/29/31/34/35는 UART/LoRa 전용이며 다른 fixed function도 보존한다. DATA_IN/OUT, DIR/OE 및 local IRQ register가 정본이다. DIR=0은 input/Hi-Z, DIR=1은 DATA_OUT drive, reset은 Hi-Z; 외부 입력은 PCLK 2FF sync다. Local `gpio_irq`는 PLIC 전 CPU에 연결하지 않는다.

### GPIO 전기 사용 계약

- 핀은 3.3-V LVTTL로 설정되며 5-V tolerance를 가정하거나 주장하지 않는다.
- FPGA GPIO가 output인 상태에서 외부 output을 맞물려 연결하지 않는다.
- output mode 활성화 전에 외부 peer voltage 호환성과 drive/load 요구를 확인한다.
- pin별 drive-strength 할당이 없으면 Quartus 기본 동작을 사용하지만 이는 peer별 승인값이 아니다.
- peer 요구가 있으면 근거 검토 후 명시적 drive strength나 추가 constraint를 적용할 수 있다.
- peer timing/load, I/O delay, signal integrity와 전체 외부 timing 종결은 `STA-002` 소유다. `BOARDIO-002 VERIFIED`는 `STA-002` 종결을 뜻하지 않는다.
