# Baseline SoC Timer Subsystem Specification

> **Phase 4A-P06 closure note (2026-09-16):** The public candidate implements the approved A5 polling-only one-shot contract. Section 21 is the current Timer behavior and supersedes the earlier reconstructed ENABLE/N+1/automatic-W1C-resume descriptions, which remain as historical pre-P06B context. User/Chat approved the P06B evidence and `TIMER-001..005` are VERIFIED; `TIMER-IRQ` remains deferred and no IRQ was added.

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `timer.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. Purpose

This document defines the active APB timer peripheral in the FPGA baseline. It specifies:

- the APB-visible register contract,
- counter, compare, enable, and READY semantics,
- exact compare timing in PCLK cycles,
- W1C and re-arm behavior,
- reset and disable behavior,
- firmware usage requirements,
- current polling-only architecture,
- known edge cases and implementation quirks,
- verification requirements,
- cleanup items that shall be resolved before major future interrupt/interconnect integration.

The active timer is a simple 32-bit compare timer. It is **not** a RISC-V architectural timer, CLINT/ACLINT timer, watchdog, PWM block, or interrupt source in the current baseline.

## 2. Active RTL Boundary

The active timer is:

```text
rtl/peripherals/APB_TIMER.v
```

and is instantiated in `AMBA_SoC_TOP` as APB slot 2:

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

Canonical base address:

```text
TIMER_BASE = 0x4002_0000
```

Clock/reset domain:

```text
PCLK    = 50 MHz
PRESETn = APB/system reset
```

The active peripheral permanently asserts:

```text
PREADY = 1
```

so the timer itself adds no APB wait state. The AHB-to-APB bridge still contributes its normal APB SETUP/ACCESS latency as defined in `apb_subsystem.md`.

The timer has no `irq` output in the active baseline.

## 3. Canonical Register Map

| Offset | Register | Access | Reset | Summary |
|---:|---|---|---:|---|
| `0x00` | `TIMER_CTRL` | R/W | `0x0000_0000` | bit 0 = enable |
| `0x04` | `TIMER_COUNT` | R | `0x0000_0000` | current 32-bit counter |
| `0x08` | `TIMER_COMPARE` | R/W | `0x0000_0000` | terminal compare value |
| `0x0C` | `TIMER_STATUS` | R / W1C(bit 0) | `0x0000_0000` | bit 0 = READY |

Only naturally aligned 32-bit MMIO accesses to these canonical offsets are part of the baseline contract.

The RTL decodes `PADDR[3:0]`, so these four registers physically repeat every 16 bytes within the selected APB slot. Those mirrors are implementation artifacts and shall not be used by firmware or verification as architectural aliases.

## 4. Register Semantics

### 4.1 TIMER_CTRL — `+0x00`

Read value:

```text
31                         1 0
+---------------------------+-+
|             0             |E|
+---------------------------+-+
```

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `ENABLE` | R/W | `1`: counter engine enabled; `0`: disabled |
| 31:1 | Reserved | R | Read as zero |

Writing `ENABLE=0` stops future timer operation but does **not** explicitly clear:

- `TIMER_COUNT`,
- `TIMER_COMPARE`,
- `TIMER_STATUS.READY`.

There is no implemented counter-clear/reset command in `TIMER_CTRL`, despite older source comments referring to "En, Clear".

### 4.2 TIMER_COUNT — `+0x04`

`TIMER_COUNT` returns the current internal 32-bit `counter` value.

The counter is read-only through the APB register interface. Writes to this offset have no implemented effect.

When actively counting and not READY, the counter advances by one per PCLK edge while its old value is less than `TIMER_COMPARE`.

### 4.3 TIMER_COMPARE — `+0x08`

`TIMER_COMPARE` stores the 32-bit `counter_cmp` terminal compare value.

Writes replace the compare value but do not reset or reload the current counter.

Therefore changing `TIMER_COMPARE` while the timer is enabled changes the terminal condition of the already-running count. This is legal current RTL behavior but is not recommended as a portable firmware sequence.

### 4.4 TIMER_STATUS — `+0x0C`

Read value:

```text
31                         1 0
+---------------------------+-+
|             0             |R|
+---------------------------+-+
```

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `READY` | R / W1C | `1`: terminal compare event reached; counting stopped |
| 31:1 | Reserved | R | Read as zero |

Writing bit 0 as `1` clears READY.

Writing bit 0 as `0` leaves READY unchanged.

There is no interrupt side effect associated with READY in the active baseline.

## 5. Core Counter State Machine

The effective timer behavior is:

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

This is not a free-running counter followed by an equality comparator. Reaching the terminal condition causes the counter to return to zero and READY to stop further counting.

Conceptually:

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
   |  COUNT <- 0
   |  READY <- 1
   v
Stopped-at-READY
   |
   | STATUS W1C
   v
Counting again if ENABLE remains 1
```

## 6. Exact Compare Timing

### 6.1 Baseline start from COUNT = 0

Assume:

```text
COUNT   = 0
READY   = 0
ENABLE  = 1
COMPARE = N
```

and COMPARE remains unchanged.

For each active timer edge:

```text
COUNT < N  -> increment COUNT
COUNT >= N -> set READY and reset COUNT to 0
```

Therefore READY is asserted after:

```text
N + 1 active timer edges
```

not after exactly N edges.

Examples:

| COMPARE | Active edges until READY | Sequence |
|---:|---:|---|
| `0` | 1 | `COUNT=0` already satisfies terminal condition -> READY |
| `1` | 2 | `0->1`, then terminal |
| `2` | 3 | `0->1->2`, then terminal |
| `49,999,999` | 50,000,000 | approximately 1 second at 50 MHz |
| `0xFFFF_FFFF` | `2^32` | full 32-bit count span before READY |

Accordingly, if software wants a terminal event after approximately `T` PCLK cycles from COUNT=0, the intuitive programmed value is generally:

```text
COMPARE = T - 1
```

for `T >= 1`.

### 6.2 Time conversion

At the baseline PCLK:

```text
PCLK = 50 MHz
1 PCLK period = 20 ns
```

For a fresh count from zero:

```text
terminal_time = (COMPARE + 1) / 50,000,000 seconds
```

subject to the distinction between the APB enable transaction and the first subsequent active timer edge.

### 6.3 Enable-write edge

If the timer was previously disabled, an APB write that changes `ENABLE` from 0 to 1 does not simultaneously perform the first increment because the sequential timer logic evaluates the old `enable` value at that clock edge.

The first active count evaluation occurs on the following PCLK edge.

## 7. READY Stop and Re-Arm Behavior

When the terminal condition is reached:

```text
COUNT <- 0
READY <- 1
```

`ENABLE` is not automatically cleared.

While READY remains 1:

```text
COUNT remains 0
```

even if ENABLE is still 1.

If software then performs:

```text
write TIMER_STATUS bit0 = 1
```

READY becomes 0. If ENABLE is still 1, the timer automatically resumes counting on a following PCLK edge from COUNT=0.

Therefore the current block can be used as a software-rearmed periodic timer:

```text
terminal event
 -> READY=1, COUNT=0
 -> software observes READY
 -> software W1C READY
 -> next count interval begins automatically
```

The re-arm operation does not require rewriting ENABLE.

## 8. Firmware Start / Restart Requirements

The baseline driver currently provides:

```c
void timer_start(uint32_t compare)
{
    mmio_write32(TIMER_BASE + TIMER_COMPARE, compare);
    mmio_write32(TIMER_BASE + TIMER_CTRL, TIMER_CTRL_ENABLE);
}
```

This sequence works for the initial use after reset because READY starts at zero.

However, `timer_start()` does **not**:

- clear a previously asserted READY flag,
- reset a partially advanced COUNT value,
- force a clean disable/reload/re-enable sequence.

Consequently, calling `timer_start()` after a previous timer completion while READY is still 1 does not begin a new interval. The timer remains stopped until READY is W1C-cleared.

Likewise, calling `timer_start()` while a previous count is in progress updates COMPARE but continues from the existing COUNT value.

**Baseline firmware rule:** code requiring a deterministic fresh interval shall explicitly establish a known timer state rather than assuming `timer_start(compare)` always means "restart from zero".

The benchmark firmware contains an explicit reset/re-arm sequence for this reason.

## 9. Disable Semantics and Same-Edge Quirk

An APB write of:

```text
TIMER_CTRL.ENABLE = 0
```

disables the timer for subsequent cycles.

However, because the counter update and APB register write occur in the same sequential RTL process, the counter logic on that clock edge evaluates the **old** enable value.

Therefore, if the timer was enabled before the write, the disable transaction edge can still perform one final counter evaluation:

- increment COUNT, or
- reach the terminal condition and set/reset timer state,

before `enable <= 0` takes effect for following cycles.

Firmware shall not assume that writing ENABLE=0 atomically freezes the exact pre-write COUNT value.

This behavior is especially relevant to cycle-measurement code and should be cleaned up or explicitly preserved in a future timer redesign.

## 10. Compare Update While Running

Because writing `TIMER_COMPARE` does not reset COUNT:

### New compare greater than current count

The timer continues toward the new compare value.

### New compare equal to or less than current count

On a subsequent active timer evaluation, the condition:

```text
COUNT < COMPARE
```

is false, so the timer enters terminal state, resets COUNT to zero, and asserts READY.

The compare value written on an APB edge becomes effective for subsequent timer evaluations; the same edge's counter logic evaluates the previous compare value.

**Baseline firmware rule:** do not modify COMPARE during an active interval unless this behavior is intentional.

## 11. W1C Race Behavior

READY generation and APB STATUS writes are implemented in the same sequential process.

The STATUS write logic appears after the counter terminal logic. Therefore, if a W1C write and terminal READY generation occur on the same PCLK edge, the later W1C assignment can clear READY on that edge.

This creates a possible event-loss race for software that writes STATUS without first observing a stable READY state.

Normal baseline polling software avoids this by clearing READY only after detecting it.

A future interrupt-capable timer shall define a race-safe event/acknowledge contract explicitly.

## 12. Polling-Only Architecture

The baseline timer has no active interrupt output.

Software uses:

```text
TIMER_STATUS.READY polling
```

rather than interrupt-driven completion.

This is consistent with `interrupt_architecture.md`, where the active baseline has no PLIC/external interrupt path.

The legacy PLIC candidate shall not be treated as defining current timer interrupt semantics. Any future timer IRQ shall be specified first, including:

- source ID,
- level versus pulse behavior,
- pending condition,
- interaction with READY,
- W1C/claim-complete ordering,
- enable/reset semantics.

## 13. Free-Running-Counter Use in Baseline Firmware

The final baseline application uses the timer approximately as a long-running cycle counter:

```c
timer_start(0xfffffffeu);
```

and checks READY when sampling time. If READY is set, firmware clears it so the counter can resume from zero.

This works because unsigned subtraction can be used around the software-visible wrap/reset point for the application's timing intervals, but the hardware is still architecturally a compare-and-stop timer rather than a true continuously wrapping free-running counter.

For `COMPARE = 0xFFFF_FFFE`, a fresh interval contains:

```text
0xFFFF_FFFF active timer edges
```

before READY is asserted.

At 50 MHz this is approximately:

```text
85.8993459 seconds
```

per terminal interval.

## 14. Hardware Timer vs Software Delay Helper

The firmware function:

```c
timer_delay_cycles(uint32_t cycles)
```

is a software loop containing `nop`; it does **not** program or wait on `APB_TIMER`.

Its elapsed wall-clock time includes loop/instruction execution overhead and therefore shall not be confused with exact PCLK timer semantics.

This distinction is relevant to `display_smoke` and other diagnostics that use `timer_delay_cycles()` only as a coarse software delay.

## 15. APB and Addressing Behavior

The timer commits writes only during:

```text
PSEL && PENABLE && PWRITE
```

and returns register data only during:

```text
PSEL && PENABLE && !PWRITE
```

`PREADY` is permanently high.

The local register decoder is:

```text
PADDR[3:0]
```

with implemented offsets 0x0, 0x4, 0x8, and 0xC.

Consequences:

- canonical registers repeat every 16 bytes inside the physically selected slot,
- noncanonical mirrors are unsupported,
- misaligned/unimplemented low-nibble addresses read zero or have no write effect,
- the broader APB bridge itself can also create higher-level slot aliases as documented in `apb_subsystem.md`.

Only the canonical addresses in `memory_map.md` are software-visible architecture.

## 16. Reset Behavior

On active-low reset:

```text
COUNT   <- 0
COMPARE <- 0
ENABLE  <- 0
READY   <- 0
```

The timer remains inactive until software enables it.

With COMPARE still equal to its reset value 0, enabling the timer causes READY to assert on the first active timer edge because `COUNT < COMPARE` is immediately false.

Firmware should normally program COMPARE before asserting ENABLE.

## 17. Non-Architectural Debug Output

The timer RTL exposes:

```text
counter_debug = counter[31:22]
```

as a 10-bit debug port.

The active `AMBA_SoC_TOP` instance leaves this output unconnected.

It is therefore not part of the architectural software, board-I/O, or verification contract.

## 18. Verification Requirements

Directed verification for the baseline timer should cover at minimum:

1. reset state of COUNT/COMPARE/ENABLE/READY,
2. read/write behavior of all four canonical registers,
3. COMPARE=0 -> READY on first active edge,
4. COMPARE=1 -> READY after two active edges,
5. representative COMPARE=N -> exactly N+1 active edges from COUNT=0,
6. COUNT reset to zero at terminal event,
7. READY stops further counting,
8. STATUS bit0 W1C behavior,
9. automatic resume after W1C when ENABLE remains 1,
10. disable while counting, including the same-edge final-evaluation quirk,
11. compare update above/below current COUNT,
12. W1C/terminal same-edge race behavior,
13. repeated start behavior when READY was not cleared,
14. canonical-address accesses versus noncanonical 16-byte mirrors,
15. PREADY remains high for all timer accesses,
16. absence of an active timer IRQ in the baseline integration.

Cleanup verification shall prove frozen A5 one-shot START/STOP/RELOAD/READY semantics rather than preserving accidental RTL behavior; timer IRQ is still outside this baseline target.

## 19. Baseline Cleanup Targets Before Major Feature Integration

The following items shall be carried into the consolidated baseline cleanup document before PLIC/AXI work is treated as the next stable architecture stage.

### TIMER-CLEANUP-01 — Define intuitive interval semantics

Current fresh-start terminal latency is `COMPARE + 1` cycles. Frozen A5 instead requires exactly `COMPARE` counting edges after START; this remains unimplemented.

### TIMER-CLEANUP-02 — Define deterministic START / RESTART

`timer_start(compare)` currently does not guarantee COUNT=0 or READY=0. Implement frozen A5 fresh START/restart behavior.

### TIMER-CLEANUP-03 — Add explicit counter reset/reload control

The active CTRL register has only ENABLE despite stale comments implying a clear function. Implement frozen A5 `CTRL[1]` RELOAD command.

### TIMER-CLEANUP-04 — Remove disable same-edge ambiguity

Frozen A5 STOP wins over counting/terminal evaluation on its commit edge and preserves COUNT/READY; implement and test it.

### TIMER-CLEANUP-05 — Define safe compare-update policy

Frozen A5 writes only programmed COMPARE while running; active_compare remains latched until next START. Implement/test it.

### TIMER-CLEANUP-06 — Harden READY event acknowledgement

Frozen A5 makes terminal event set-dominant over same-edge READY W1C; implement/test it before any future interrupt use.

### TIMER-CLEANUP-07 — Define timer interrupt contract for PLIC

Do not simply add an `irq` wire. Specify enable, pending, source type, acknowledgement, reset, and claim/complete interaction first.

### TIMER-CLEANUP-08 — Tighten register decode

Remove or explicitly contain the current 16-byte register mirroring and align the implementation with canonical address policy.

### TIMER-CLEANUP-09 — Remove or formally retain dead debug interface

`counter_debug` is unconnected at top level. Remove it or define a deliberate debug integration rather than leaving an unused architectural-looking port.

### TIMER-CLEANUP-10 — Add directed timer regression

Add deterministic RTL tests for cycle-accurate compare timing, re-arm, disable, update, W1C race, boundary values, and future IRQ behavior.

## 20. Baseline Invariants

Unless a later approved specification changes the architecture:

1. Timer base address is `0x4002_0000`.
2. The timer is APB slot `PSEL[2]`.
3. PCLK is 50 MHz in the FPGA baseline.
4. Registers are 32-bit MMIO at offsets `0x00/0x04/0x08/0x0C`.
5. CTRL bit 0 is the only implemented enable control.
6. COUNT increments only when ENABLE=1 and READY=0.
7. A fresh count from zero reaches READY after `COMPARE + 1` active timer edges.
8. Terminal behavior resets COUNT to zero and sets READY.
9. READY stops counting until cleared.
10. READY bit 0 is W1C.
11. Clearing READY while ENABLE remains 1 re-arms counting without another ENABLE write.
12. The active baseline has no timer interrupt output.
13. `PREADY` is permanently asserted by the timer slave.
14. Physical register mirrors are not architectural addresses.
15. `timer_delay_cycles()` is a software delay helper, not the APB timer engine.

## Phase 4A-2 Approved One-Shot Target (not active RTL)

A5 defines reset `COUNT=COMPARE=RUNNING=READY=0`. START clears COUNT/READY and latches programmed COMPARE as `active_compare`; N=0 completes on the START commit edge, otherwise edge #1 is the following PCLK edge and edge #N completes with `COUNT=N, READY=1, RUNNING=0`. START while running restarts. STOP halts without terminal completion and preserves COUNT/READY. RELOAD clears COUNT/READY/RUNNING. A COMPARE write during a run affects only the next START. READY is sticky; W1C clears only READY, and a simultaneous terminal event wins over W1C. No automatic restart or periodic mode. Firmware `timer_start(N)` writes COMPARE=N then START for a fresh interval. Existing `COMPARE+1` behavior is current-only.

The four existing register offsets remain. For the target, `TIMER_CTRL[0]` reads RUNNING; writing 1 issues START and writing 0 issues STOP. `TIMER_CTRL[1]` reads zero; writing 1 issues RELOAD. Other bits are reserved/read zero. `TIMER_STATUS[0]` is READY/W1C. A simultaneous CTRL START+RELOAD selects START; STOP or RELOAD wins over counting/terminal evaluation on its commit edge. COMPARE writes during RUNNING do not alter `active_compare` or the current interval. Supported N spans the 32-bit COMPARE range including zero. These were the Phase 4A-2 frozen target rules; §21 records their P06B implementation.

## 21. Phase 4A-P06B Current Implementation

The public candidate implements the A5 target at the unchanged base, slot, clock, reset, and register offsets:

```text
base       0x4002_0000
slot       PSEL[2]
clock      PCLK = HCLK = 50 MHz
CTRL       +0x00
COUNT      +0x04
COMPARE    +0x08
STATUS     +0x0c
```

Current state ownership is `programmed_compare`, `active_compare`, `counter`, `running`, and sticky `ready`.

- Writing COMPARE changes only `programmed_compare`.
- START (`CTRL[0]=1`) captures programmed COMPARE, clears COUNT/READY, and starts a fresh interval. START wins if `CTRL[1]` is also written as 1.
- N=0 completes on the START commit edge with `COUNT=0`, `RUNNING=0`, and `READY=1`.
- N>=1 completes after exactly N subsequent active PCLK edges with `COUNT=N`, `RUNNING=0`, and `READY=1`.
- STOP (`CTRL[1:0]=00`) suppresses same-edge count/terminal evaluation and preserves COUNT/READY.
- RELOAD (`CTRL[1:0]=10`) suppresses same-edge count/terminal evaluation, clears COUNT/RUNNING/READY, and preserves programmed COMPARE.
- A COMPARE write during RUNNING affects the next START only.
- STATUS bit 0 remains W1C. Clearing READY does not restart the Timer or clear COUNT.
- Terminal completion is set-dominant over a same-edge STATUS W1C.
- COUNT is read-only and holds while stopped.
- Reset clears programmed/active compare, COUNT, RUNNING, and READY.
- Local decoding uses the full 16-bit slot offset; the former 16-byte slave-local mirrors are removed. The central bridge continues to reject noncanonical/misaligned/unsupported Timer accesses before asserting `PSEL[2]`.
- The unowned `counter_debug` port is removed.
- No `timer_irq`, interrupt register, PLIC source, or CPU IRQ routing exists.

Applications may repeatedly re-arm one-shot intervals to maintain a software timebase. The hardware Timer itself is not a continuously free-running wall clock: it stops at terminal and requires an explicit START for the next interval.

P06B directed verification covers reset, register access, COUNT write-ignore, N=0/1/2/representative N, maximum compare by controlled near-terminal state, fresh START, STOP/RELOAD priority, programmed/active compare isolation, READY/W1C, terminal/W1C collision, back-to-back command sequences, local invalid offsets, and architectural bridge ERROR/no-side-effect cases. Open regression, whole-SoC lint/elaboration, and affected firmware builds pass. User/Chat approved this evidence for `TIMER-001..005` closure.
