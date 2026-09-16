# Baseline SoC Timer Subsystem Specification — 한국어 Companion

> **Phase 4A-P06 종결 주석(2026-09-16):** 공개 candidate는 승인된 A5 polling-only one-shot 계약을 구현했다. 아래 §21이 현재 Timer 동작이며, 앞선 ENABLE/N+1/W1C 자동 재시작 설명은 P06B 이전 이력으로 남긴다. User/Chat이 P06B evidence를 승인하여 `TIMER-001..005`는 VERIFIED이며, `TIMER-IRQ`는 계속 deferred이고 IRQ를 추가하지 않았다.

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/10_timer.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. 목적

이 문서는 active FPGA baseline의 APB timer peripheral을 정의한다. 주요 범위는 다음과 같다.

- APB-visible register contract
- counter / compare / enable / READY semantics
- PCLK 기준 정확한 compare timing
- W1C 및 re-arm 동작
- reset / disable behavior
- firmware 사용 규칙
- polling-only 구조
- edge case 및 implementation quirk
- verification requirement
- PLIC/AXI 이전 baseline cleanup target

현재 timer는 단순한 32-bit compare timer다. RISC-V architectural timer, CLINT/ACLINT timer, watchdog, PWM block, interrupt source가 아니다.

## 2. Active RTL 경계

Active RTL:

```text
rtl/peripherals/APB_TIMER.v
```

Top-level integration:

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +--> PSEL[2]
       |
       v
   APB_TIMER
```

Canonical base:

```text
TIMER_BASE = 0x4002_0000
```

Clock/reset:

```text
PCLK    = 50 MHz
PRESETn = APB/system reset
```

Timer slave는 항상:

```text
PREADY = 1
```

이므로 timer 자체가 APB wait state를 추가하지 않는다. 다만 AHB-to-APB bridge의 SETUP/ACCESS latency는 `apb_subsystem.md` 계약을 따른다.

현재 active timer에는 `irq` output이 없다.

## 3. Canonical Register Map

| Offset | Register | Access | Reset | Summary |
|---:|---|---|---:|---|
| `0x00` | `TIMER_CTRL` | R/W | `0x0000_0000` | bit 0 = enable |
| `0x04` | `TIMER_COUNT` | R | `0x0000_0000` | current 32-bit counter |
| `0x08` | `TIMER_COMPARE` | R/W | `0x0000_0000` | terminal compare value |
| `0x0C` | `TIMER_STATUS` | R / W1C(bit 0) | `0x0000_0000` | bit 0 = READY |

Canonical contract는 naturally aligned 32-bit MMIO access만 허용한다.

RTL은 `PADDR[3:0]`만 decode하므로 register bank가 selected APB slot 내부에서 16-byte마다 반복 mirror된다. 이러한 mirror는 implementation artifact이며 architectural alias가 아니다.

## 4. Register Semantics

### 4.1 TIMER_CTRL — `+0x00`

```text
31                         1 0
+---------------------------+-+
|             0             |E|
+---------------------------+-+
```

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `ENABLE` | R/W | `1`: timer engine enable, `0`: disable |
| 31:1 | Reserved | R | zero |

`ENABLE=0` write는 이후 counting을 멈추지만 다음 항목을 명시적으로 clear하지 않는다.

- `TIMER_COUNT`
- `TIMER_COMPARE`
- `TIMER_STATUS.READY`

기존 source comment의 "En, Clear"와 달리 active CTRL register에는 counter clear command가 구현되어 있지 않다.

### 4.2 TIMER_COUNT — `+0x04`

현재 internal 32-bit `counter` 값을 읽는다.

APB에서 read-only이며 이 offset에 write해도 구현된 효과가 없다.

`ENABLE=1 && READY=0`일 때 old COUNT가 COMPARE보다 작으면 PCLK edge마다 1 증가한다.

### 4.3 TIMER_COMPARE — `+0x08`

32-bit `counter_cmp` 값을 저장한다.

COMPARE write는 current COUNT를 reset/reload하지 않는다.

따라서 running 중 COMPARE를 변경하면 기존 COUNT에서 새로운 terminal condition을 향해 계속 동작한다.

### 4.4 TIMER_STATUS — `+0x0C`

```text
31                         1 0
+---------------------------+-+
|             0             |R|
+---------------------------+-+
```

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `READY` | R / W1C | terminal compare event 도달, counting stop |
| 31:1 | Reserved | R | zero |

Bit 0에 1을 write하면 READY가 clear된다.

0을 write하면 READY는 유지된다.

현재 READY와 연결된 interrupt side effect는 없다.

## 5. Core Counter State Machine

실제 핵심 동작은 다음과 같다.

```text
if ENABLE == 1 and READY == 0:
    if COUNT < COMPARE:
        COUNT <- COUNT + 1
    else:
        COUNT <- 0
        READY <- 1
else:
    hold COUNT
```

즉 free-running counter + equality comparator 구조가 아니다. Terminal condition에 들어가면 COUNT를 0으로 만들고 READY=1 상태에서 정지한다.

```text
Disabled
   |
   | ENABLE=1, READY=0
   v
Counting
   |
   | COUNT < COMPARE -> COUNT++
   |
   | COUNT >= COMPARE
   v
Terminal
   | COUNT <- 0
   | READY <- 1
   v
Stopped-at-READY
   |
   | STATUS W1C
   v
ENABLE이 여전히 1이면 다시 Counting
```

## 6. 정확한 Compare Timing

### 6.1 COUNT=0 fresh start

다음을 가정한다.

```text
COUNT   = 0
READY   = 0
ENABLE  = 1
COMPARE = N
```

COMPARE가 바뀌지 않으면:

```text
COUNT < N  -> COUNT increment
COUNT >= N -> READY set + COUNT=0
```

따라서 READY는 정확히:

```text
N + 1 active timer edges
```

후에 set된다.

예:

| COMPARE | READY까지 active edge | Sequence |
|---:|---:|---|
| `0` | 1 | 첫 edge에서 즉시 terminal |
| `1` | 2 | `0->1`, 다음 edge terminal |
| `2` | 3 | `0->1->2`, 다음 edge terminal |
| `49,999,999` | 50,000,000 | 50 MHz에서 약 1초 |
| `0xFFFF_FFFF` | `2^32` | full 32-bit span |

즉 COUNT=0에서 T개의 active edge 후 terminal event가 필요하면 일반적으로:

```text
COMPARE = T - 1
```

을 사용한다.

### 6.2 시간 변환

Baseline:

```text
PCLK = 50 MHz
1 period = 20 ns
```

Fresh count 기준:

```text
terminal_time = (COMPARE + 1) / 50,000,000 seconds
```

### 6.3 Enable write edge

이전에 disabled 상태였다면 `ENABLE: 0->1` APB write가 commit되는 같은 edge에서는 old `enable=0`을 기준으로 timer logic이 평가된다.

따라서 실제 첫 count evaluation은 다음 PCLK edge부터 발생한다.

## 7. READY Stop / Re-Arm

Terminal event 시:

```text
COUNT <- 0
READY <- 1
```

ENABLE은 자동으로 clear되지 않는다.

READY=1인 동안 COUNT는 0에서 정지한다.

Software가:

```text
TIMER_STATUS bit0 = 1
```

을 write하여 READY를 clear하면, ENABLE이 여전히 1일 경우 다음 PCLK부터 COUNT=0에서 다시 동작한다.

즉 current block은 software-rearmed periodic timer처럼 사용할 수 있다.

```text
terminal
 -> READY=1, COUNT=0
 -> software poll
 -> W1C READY
 -> next interval automatically starts
```

## 8. Firmware Start / Restart 규칙

현재 driver:

```c
void timer_start(uint32_t compare)
{
    mmio_write32(TIMER_BASE + TIMER_COMPARE, compare);
    mmio_write32(TIMER_BASE + TIMER_CTRL, TIMER_CTRL_ENABLE);
}
```

Reset 직후 최초 사용에는 문제가 없다. 하지만 `timer_start()`는 다음을 수행하지 않는다.

- previous READY clear
- partially advanced COUNT reset
- deterministic disable/reload/re-enable

따라서 이전 interval이 끝나 READY=1인 상태에서 `timer_start()`만 다시 호출하면 새 interval이 시작되지 않는다. READY를 W1C해야 한다.

Running 중 `timer_start()`를 호출하면 COUNT는 유지한 채 COMPARE만 바뀐다.

**Baseline firmware rule:** fresh interval이 필요하면 timer state를 명시적으로 known state로 만들고 사용해야 한다. `timer_start(compare)`를 무조건 "zero부터 restart" 의미로 해석하면 안 된다.

Benchmark firmware는 이 때문에 별도 reset/re-arm sequence를 사용한다.

## 9. Disable Same-Edge Quirk

`TIMER_CTRL.ENABLE=0` write는 이후 cycle부터 timer를 disable한다.

하지만 counter update와 APB register write가 같은 sequential always block 안에 있으므로 해당 edge의 counter logic은 old enable 값을 사용한다.

따라서 이전에 ENABLE=1이었다면 disable write edge에서 마지막으로:

- COUNT가 1 증가하거나
- terminal condition을 만나 COUNT=0 / READY=1이 될 수 있다.

Software는 ENABLE=0 write가 pre-write COUNT를 atomic하게 그대로 freeze한다고 가정하면 안 된다.

## 10. Running 중 Compare Update

COMPARE write는 COUNT를 reset하지 않는다.

새 COMPARE가 current COUNT보다 크면 새 compare까지 계속 count한다.

새 COMPARE가 current COUNT보다 같거나 작으면 다음 active evaluation에서 `COUNT < COMPARE`가 false가 되어 terminal로 진입한다.

COMPARE write와 같은 edge의 timer logic은 old compare를 보고, 새 compare는 이후 evaluation부터 적용된다.

**Baseline firmware rule:** 의도된 동작이 아니라면 active interval 중 COMPARE 변경을 피한다.

## 11. W1C Race Behavior

READY generation과 STATUS W1C write는 같은 sequential process에서 처리된다.

STATUS write code가 terminal READY assignment보다 뒤에 있으므로 동일 PCLK edge에 terminal event와 W1C가 겹치면 W1C가 READY를 0으로 덮을 수 있다.

즉 event-loss race가 가능하다.

Baseline polling software는 READY를 먼저 관찰한 뒤 clear하여 이 race를 피한다.

향후 interrupt-capable timer는 event/acknowledge race contract를 명시적으로 다시 설계해야 한다.

## 12. Polling-Only Architecture

현재 timer는 interrupt output이 없다.

Software는:

```text
TIMER_STATUS.READY polling
```

을 사용한다.

이는 active baseline에 PLIC/external interrupt path가 없다는 `interrupt_architecture.md`와 일치한다.

향후 timer IRQ를 추가할 때는 단순 `irq` wire 추가로 끝내지 말고 다음을 먼저 spec으로 고정해야 한다.

- source ID
- level/pulse semantics
- pending condition
- READY relationship
- W1C vs claim/complete ordering
- enable/reset behavior

## 13. Baseline Firmware의 Long-Running Counter 사용

최종 baseline application은 timer를 장시간 cycle counter처럼 사용한다.

```c
timer_start(0xfffffffeu);
```

READY가 올라오면 software가 clear하여 0부터 counting을 재개한다.

이는 application 관점에서 wrap-like 동작으로 활용한 것이며, hardware 자체는 true continuously wrapping free-running counter가 아니라 compare-and-stop timer다.

`COMPARE = 0xFFFF_FFFE` fresh interval은:

```text
0xFFFF_FFFF active timer edges
```

후 terminal에 도달한다.

50 MHz 기준 약:

```text
85.8993459 seconds
```

이다.

## 14. Hardware Timer와 Software Delay Helper 구분

Firmware 함수:

```c
timer_delay_cycles(uint32_t cycles)
```

는 `nop`가 포함된 software loop일 뿐 `APB_TIMER`를 사용하지 않는다.

따라서 실제 elapsed time에는 loop/instruction overhead가 포함되며 정확한 PCLK timer semantics와 동일하지 않다.

`display_smoke` 등의 진단 코드에서 이 함수는 coarse software delay 용도다.

## 15. APB / Addressing Behavior

Write commit:

```text
PSEL && PENABLE && PWRITE
```

Read data:

```text
PSEL && PENABLE && !PWRITE
```

`PREADY=1` 고정이다.

Local register decoder는:

```text
PADDR[3:0]
```

만 사용한다.

따라서:

- register가 16-byte마다 mirror됨
- mirror는 canonical address가 아님
- misaligned/unimplemented low-nibble read는 zero, write는 no effect
- APB bridge coarse decode 때문에 상위 주소 alias도 별도로 존재 가능

Software는 `memory_map.md`의 canonical 주소만 사용한다.

## 16. Reset Behavior

Reset 시:

```text
COUNT   <- 0
COMPARE <- 0
ENABLE  <- 0
READY   <- 0
```

COMPARE가 reset value 0인 상태에서 ENABLE만 1로 만들면 첫 active timer edge에 즉시 READY가 set된다.

따라서 일반적으로 COMPARE를 먼저 program한 뒤 ENABLE해야 한다.

## 17. Non-Architectural Debug Output

RTL에는:

```text
counter_debug = counter[31:22]
```

10-bit output이 있다.

하지만 active `AMBA_SoC_TOP`에서는 unconnected다.

따라서 software/board I/O/verification architectural contract가 아니다.

## 18. Verification Requirements

Baseline timer directed verification은 최소 다음을 확인해야 한다.

1. reset state
2. 4개 canonical register R/W semantics
3. COMPARE=0 first active edge READY
4. COMPARE=1 two active edges READY
5. representative N에 대해 N+1 timing
6. terminal 시 COUNT=0
7. READY 동안 counting stop
8. STATUS W1C
9. ENABLE 유지 상태에서 W1C 후 automatic resume
10. disable same-edge final evaluation
11. running compare update above/below current COUNT
12. terminal/W1C same-edge race
13. READY uncleared 상태 repeated start
14. canonical vs 16-byte mirror access
15. PREADY high
16. active timer IRQ 부재

## 19. Baseline Cleanup Targets Before Major Feature Integration

### TIMER-CLEANUP-01 — Interval semantics 정리

현재 fresh-start latency는 `COMPARE + 1` cycle이다. 승인된 A5 목표는 START 후 정확히 `COMPARE` counting edge이며 아직 구현되지 않았다.

### TIMER-CLEANUP-02 — Deterministic START / RESTART

`timer_start(compare)`가 현재 COUNT=0 / READY=0을 보장하지 않는다. 승인된 A5 fresh START/restart를 구현한다.

### TIMER-CLEANUP-03 — Explicit counter reset/reload

Stale comment와 달리 현행 CTRL에 clear가 없다. 승인된 A5 `CTRL[1]` RELOAD를 구현한다.

### TIMER-CLEANUP-04 — Disable same-edge ambiguity 제거

승인된 A5 STOP은 commit edge의 counting/terminal보다 우선하며 COUNT/READY를 보존한다. 구현/검증한다.

### TIMER-CLEANUP-05 — Safe compare update policy

승인된 A5에서는 running 중 programmed COMPARE만 갱신하고 active_compare는 다음 START까지 유지한다. 구현/검증한다.

### TIMER-CLEANUP-06 — READY acknowledge race hardening

승인된 A5에서는 terminal event가 동시 READY W1C보다 우선한다. future IRQ 사용 전에 구현/검증한다.

### TIMER-CLEANUP-07 — PLIC용 timer IRQ contract

IRQ enable, pending, source type, ack, reset, claim/complete interaction을 먼저 spec으로 정의한다.

### TIMER-CLEANUP-08 — Register decode tighten

16-byte mirror를 제거하거나 명시적으로 contain하여 canonical address 정책과 맞춘다.

### TIMER-CLEANUP-09 — Dead debug interface 정리

Unconnected `counter_debug`를 제거하거나 deliberate debug interface로 정의한다.

### TIMER-CLEANUP-10 — Directed timer regression

Cycle-accurate compare timing, re-arm, disable, update, W1C race, boundary, future IRQ를 검증하는 deterministic test를 추가한다.

## 20. Baseline Invariants

1. Timer base는 `0x4002_0000`이다.
2. APB slot은 `PSEL[2]`다.
3. Baseline PCLK는 50 MHz다.
4. Register offset은 `0x00/0x04/0x08/0x0C`다.
5. CTRL bit0만 implemented enable control이다.
6. COUNT는 ENABLE=1 && READY=0일 때만 증가한다.
7. COUNT=0 fresh start에서 READY는 `COMPARE + 1` active edge 후 set된다.
8. Terminal에서 COUNT=0, READY=1이 된다.
9. READY 동안 counting은 멈춘다.
10. READY bit0는 W1C다.
11. ENABLE=1을 유지한 채 READY를 clear하면 counting이 다시 시작된다.
12. Active baseline에는 timer interrupt output이 없다.
13. Timer slave의 `PREADY`는 항상 1이다.
14. Physical register mirror는 architecture가 아니다.
15. `timer_delay_cycles()`는 APB timer가 아니라 software delay helper다.

## Phase 4A-2 승인된 one-shot 목표 (현행 RTL 아님)

A5 reset은 `COUNT=COMPARE=RUNNING=READY=0`. START는 COUNT/READY를 지우고 programmed COMPARE를 active_compare에 latch한다. N=0은 START commit edge에 완료; N>=1은 다음 PCLK이 counting edge #1이고 #N에서 COUNT=N, READY=1, RUNNING=0으로 완료한다. Running 중 START는 새 interval로 restart한다. STOP은 완료 event 없이 정지하고 COUNT/READY를 보존한다. RELOAD는 COUNT/READY/RUNNING을 0으로 한다. Running 중 COMPARE write는 다음 START에만 적용된다. READY는 sticky, W1C는 READY만 지우며 terminal event와 동시라면 set 우선이다. W1C 자동 restart/periodic mode 없음. FW `timer_start(N)`은 COMPARE=N 후 START한다. 현행 COMPARE+1은 baseline 한정이다.

기존 네 register offset은 유지한다. Target `TIMER_CTRL[0]`은 read RUNNING/write 1 START/write 0 STOP, `CTRL[1]`은 read 0/write 1 RELOAD, 나머지 bit는 reserved/read 0이다. `TIMER_STATUS[0]`은 READY/W1C다. CTRL START+RELOAD 동시이면 START 우선이고 STOP/RELOAD는 그 commit edge의 counting/terminal evaluation보다 우선한다. Running 중 COMPARE write는 active_compare/current interval을 바꾸지 않는다. N은 zero를 포함한 32-bit COMPARE 전 범위다. 이는 Phase 4A-2에서 동결한 target 규칙이고 §21이 P06B 구현 상태를 기록한다.

## 21. Phase 4A-P06B 현재 구현

공개 candidate는 기존 base/slot/clock/reset/register offset을 유지하면서 A5를 구현한다.

```text
base       0x4002_0000
slot       PSEL[2]
clock      PCLK = HCLK = 50 MHz
CTRL       +0x00
COUNT      +0x04
COMPARE    +0x08
STATUS     +0x0c
```

현재 상태 소유자는 `programmed_compare`, `active_compare`, `counter`, `running`, sticky `ready`다.

- COMPARE write는 `programmed_compare`만 바꾼다.
- START(`CTRL[0]=1`)는 programmed COMPARE를 capture하고 COUNT/READY를 지운 뒤 fresh interval을 시작한다. `CTRL[1]`도 동시에 1이면 START가 우선한다.
- N=0은 START commit edge에 `COUNT=0`, `RUNNING=0`, `READY=1`로 즉시 완료한다.
- N>=1은 이후 정확히 N개의 active PCLK edge 후 `COUNT=N`, `RUNNING=0`, `READY=1`로 완료한다.
- STOP(`CTRL[1:0]=00`)은 같은 edge의 count/terminal 평가보다 우선하고 COUNT/READY를 보존한다.
- RELOAD(`CTRL[1:0]=10`)는 같은 edge의 count/terminal 평가보다 우선하고 COUNT/RUNNING/READY를 지우며 programmed COMPARE를 보존한다.
- RUNNING 중 COMPARE write는 다음 START에만 적용된다.
- STATUS bit 0 W1C는 READY만 지우며 Timer를 재시작하거나 COUNT를 지우지 않는다.
- Terminal completion은 같은 edge의 STATUS W1C보다 set-dominant다.
- COUNT는 read-only이며 정지 중 값을 유지한다.
- Reset은 programmed/active compare, COUNT, RUNNING, READY를 모두 지운다.
- Local decoder는 slot 내부 16-bit offset 전체를 사용하여 과거 16-byte mirror를 제거했다. Central bridge는 noncanonical/misaligned/unsupported Timer 접근에 `PSEL[2]`를 내지 않고 계속 ERROR를 반환한다.
- 소유자가 없던 `counter_debug` port를 제거했다.
- `timer_irq`, interrupt register, PLIC source, CPU IRQ routing은 없다.

Application은 one-shot interval을 반복해서 re-arm하여 software-maintained timebase를 구성할 수 있다. Hardware Timer 자체는 continuously free-running wall clock이 아니며 terminal에서 정지하고 다음 interval에는 explicit START가 필요하다.

P06B directed verification은 reset, register access, COUNT write-ignore, N=0/1/2/대표 N, controlled near-terminal 방식의 maximum compare, fresh START, STOP/RELOAD priority, programmed/active compare isolation, READY/W1C, terminal/W1C collision, back-to-back command, local invalid offset, architectural bridge ERROR/no-side-effect를 포함한다. Open regression, whole-SoC lint/elaboration, 영향받은 firmware build도 통과했고 User/Chat이 이 evidence를 `TIMER-001..005` 종결 근거로 승인했다.
