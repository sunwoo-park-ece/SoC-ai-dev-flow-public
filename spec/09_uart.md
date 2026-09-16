# Baseline SoC UART Subsystem Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `uart.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.
>
> **P07B current-state precedence:** Section 20 records the implemented P07B
> contract. Where the earlier reconstructed-baseline narrative differs, Section
> 20 is the current implementation contract; the older text is retained as
> historical cleanup context until Full Spec Refresh.
>
> **P07 closure (2026-09-16):** User/Chat approved P07B plus its focused
> supplement for Open Verification. `UART-001..004` are `VERIFIED`.
> `UART-005` remains `OPEN` for source-identity-traceable physical PC/LoRa
> acceptance; `UART-006` remains optional/OPEN and UART IRQ remains DEFERRED.

## 1. Purpose

This document defines the two active APB UART peripherals in the FPGA baseline:

- UART0 / LoRa at `0x4000_0000`, implemented by `APB_UART_LORA`.
- UART1 / PC at `0x4006_0000`, implemented by `APB_UART`.

It owns the software-visible register behavior, UART line format, baud-divisor semantics, TX/RX state-machine behavior, RX FIFO behavior, LoRa AUX extension, polling requirements, current error behavior, and baseline cleanup items.

The baseline UARTs are **polling peripherals**. They do not generate interrupts and the `UART_CONTROL` register has no active control effect.

## 2. Active RTL Boundary

The active integration is:

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +--> PSEL[0] --> APB_UART_LORA --> LoRa UART TX/RX + AUX
 |
 +--> PSEL[6] --> APB_UART      --> PC UART TX/RX
```

Active RTL sources:

```text
rtl/peripherals/APB_UART_LORA_RT.v
rtl/peripherals/APB_UART_RT.v
rtl/soc/AMBA_SoC_TOP.v
```

Both UART instances operate in the 50 MHz APB clock domain:

```text
PCLK = 50 MHz
PRESETn = system APB reset
```

Both slaves normally assert `PREADY`. A busy `UART_DATA` write is the sole UART
wait-state case: it holds `PREADY=0` until TX can accept that transfer exactly
once. Reads and non-DATA writes are not stalled merely because TX is busy.

## 3. Canonical Address Map

### 3.1 UART0 / LoRa

```text
Base: 0x4000_0000
APB slot: PSEL[0]
```

### 3.2 UART1 / PC

```text
Base: 0x4006_0000
APB slot: PSEL[6]
```

Both implement the same four canonical register offsets:

| Offset | Register | Access | Implemented field width | Summary |
|---:|---|---|---:|---|
| `0x00` | `UART_DATA` | R / W | 8 bits | TX data on write; RX FIFO front on read; read pops one byte when available |
| `0x04` | `UART_STATUS` | R | 3 or 4 bits | TX ready, RX ready, RX error, plus LoRa AUX on UART0 |
| `0x08` | `UART_CONTROL` | RAZ/WI | — | Reserved; reads zero and ignores writes |
| `0x0C` | `UART_BAUD` | R / W | 16 bits | UART baud divisor |

The RTL compares the full 16-bit local offset and implements only the four
canonical offsets. Noncanonical local offsets read zero and writes have no
effect; the former 16-byte register mirrors are removed.

Firmware shall use naturally aligned 32-bit MMIO accesses at the exact offsets above.

## 4. UART Line Format

Both UART instances use the same asynchronous serial format:

```text
Idle    : 1
Start   : 0
Data    : 8 bits, LSB first
Parity  : none
Stop    : 1 bit
```

Therefore the baseline line format is:

```text
8-N-1
```

The TX shift register is loaded as:

```text
{ stop=1, data[7:0], start=0 }
```

and is shifted right so bit 0 is transmitted first.

There is no programmable parity, word length, or stop-bit configuration in the baseline.

## 5. Baud-Divisor Contract

`UART_BAUD[15:0]` stores the number of PCLK cycles per nominal UART bit period.

The intended relation is:

```text
baud_rate ≈ PCLK / baud_div
```

At the baseline 50 MHz PCLK and reset value `baud_div = 434`:

```text
50,000,000 / 434 ≈ 115,207.37 bit/s
```

which is approximately 115200 baud.

Reset value:

```text
UART_BAUD = 434
```

### 5.1 Programming rules

The active RTL accepts divisors 217..65535 and ignores 0..216 while preserving
the previous programmed value. TX captures the programmed divisor at DATA
acceptance; RX captures it at start detection. These direction-local active
values remain fixed for their current frames, so a BAUD write may safely update
the following frame without perturbing a frame in flight. The external peer
must use a compatible nominal rate.

## 6. TX Architecture

### 6.1 No TX FIFO

The baseline UART has one TX shift register and no transmit FIFO.

Software-visible flow:

```text
poll UART_STATUS.TX_READY
        |
        v
write UART_DATA[7:0]
        |
        v
one 8-N-1 serial frame
```

A DATA write presented while `TX_READY == 0` remains in APB ACCESS with
`PREADY=0`. It completes only when the transmitter becomes available and the
handshake accepts exactly one byte. Firmware still uses bounded `TX_READY`
polling for latency and timeout control; correctness does not rely on the poll
alone.

### 6.2 TX_READY semantics

`UART_STATUS[0]` is:

```text
TX_READY = !tx_busy
```

Meaning:

| `TX_READY` | Meaning |
|---:|---|
| 0 | transmitter is not accepting a new byte |
| 1 | `UART_DATA` write may start a new byte |

### 6.3 TX completion

The TX frame itself contains the expected 10 serial bit periods:

```text
1 start + 8 data + 1 stop
```

`TX_READY` returns on the edge completing the stop-bit interval. No additional
idle-high divisor interval is inserted before the next DATA write may be
accepted.

## 7. RX Architecture

### 7.1 External-input synchronization

`uart_rx` is asynchronous to PCLK and passes through a 2-FF synchronizer before the RX state machine consumes it.

```text
uart_rx
  |
  v
2-FF synchronizer
  |
  v
RX FSM
```

The synchronizer resets to logic high, matching UART idle level.

### 7.2 RX state machine

The active RX FSM has four states:

```text
IDLE -> START -> DATA -> STOP -> IDLE
```

Behavior:

- `IDLE`: detect a low RX level as a possible start bit.
- `START`: wait approximately half a bit period and verify the line is still low.
- `DATA`: sample eight data bits at one divisor interval each, LSB first.
- `STOP`: sample the stop bit and classify it as valid or framing-error.

A false start that returns high during the start-bit confirmation returns the FSM to `IDLE` without pushing a byte.

## 8. RX FIFO

Each UART contains a 16-byte RX FIFO:

```text
Depth : 16 entries
Width : 8 bits
```

State includes:

```text
rx_fifo_wr_ptr : 4 bits
rx_fifo_rd_ptr : 4 bits
rx_fifo_count  : 5 bits, 0..16
```

### 8.1 RX_READY

```text
UART_STATUS[1] = RX_READY = (rx_fifo_count != 0)
```

### 8.2 UART_DATA read / FIFO pop

A valid APB read of `UART_DATA`:

- returns the current FIFO front byte in `PRDATA[7:0]`,
- pops exactly one byte if the FIFO is non-empty.

Software shall first check `RX_READY` before reading `UART_DATA`.

If software reads `UART_DATA` while the FIFO is empty, it returns zero and
causes no pop, pointer/count change, or error side effect.

### 8.3 Simultaneous push and pop

The RTL explicitly supports a receive-byte push and a software pop in the same PCLK cycle. In that case:

```text
FIFO count remains unchanged
```

and both pointers advance as appropriate.

A FIFO that is currently full may still accept a newly completed RX byte if a software pop occurs in the same cycle.

## 9. RX Error Semantics

`UART_STATUS[2]` is named `RX_ERROR`.

Despite older comments calling it only a framing-error flag, active RTL sets it for either:

1. **framing error** — sampled stop bit is low,
2. **RX FIFO overflow** — a valid stop bit arrives while the FIFO is full and no simultaneous pop creates space.

On overflow, the newly received byte is dropped.

### 9.1 Clear behavior

`RX_ERROR` is sticky. Successful FIFO push/pop does not clear it. Reset or an
explicit write-one to `UART_STATUS[2]` clears the bit. A new framing/overflow
event on the same edge as W1C is set-dominant and leaves `RX_ERROR=1`.

## 10. UART_CONTROL

`UART_CONTROL` is reserved RAZ/WI: reads return zero and writes are ignored.

In the active baseline it does not control:

- TX enable,
- RX enable,
- interrupt enable,
- FIFO behavior,
- parity,
- stop bits,
- loopback,
- flow control.

Software shall not depend on any behavioral effect from `UART_CONTROL` writes.

## 11. UART0 / LoRa AUX Extension

UART0 adds one external input:

```text
lora_aux
```

The signal passes through its own 2-FF synchronizer and is exposed as:

```text
UART_STATUS[3] = LORA_AUX_HIGH
```

Meaning:

| Bit 3 | Meaning |
|---:|---|
| 0 | synchronized AUX low |
| 1 | synchronized AUX high |

The UART hardware does **not** gate TX on AUX. It merely reports the synchronized signal.

Therefore the LoRa firmware driver owns this sequencing policy:

```text
wait AUX high
wait TX_READY
write UART_DATA
```

The active `lora_uart` driver performs the AUX poll before each byte.

### 11.1 AUX reset behavior

Both AUX synchronizer stages reset low/NOT READY. After reset release the
persistent external level propagates through the unchanged two-flop path;
`HIGH=READY` remains a level condition rather than an edge event.

UART1 has no AUX input. Its status bit 3 is not implemented and reads 0 because only bits `[2:0]` are constructed in its status value.

## 12. Register Bit Definitions

### 12.1 UART_DATA — offset `0x00`

Write:

| Bits | Name | Behavior |
|---|---|---|
| `[7:0]` | TX_DATA | accepted only when `TX_READY=1` |
| `[31:8]` | — | ignored |

Read:

| Bits | Name | Behavior |
|---|---|---|
| `[7:0]` | RX_DATA | current RX FIFO front; read pops one byte if available |
| `[31:8]` | — | 0 |

### 12.2 UART_STATUS — offset `0x04`

| Bit | Name | UART0 | UART1 | Meaning |
|---:|---|---|---|---|
| 0 | `TX_READY` | R | R | 1 when new TX byte may be accepted |
| 1 | `RX_READY` | R | R | 1 when RX FIFO count is nonzero |
| 2 | `RX_ERROR` | R | R | recent framing error or FIFO overflow |
| 3 | `LORA_AUX_HIGH` | R | 0 | synchronized LoRa AUX high state |
| 31:4 | Reserved | 0 | 0 | reads zero |

### 12.3 UART_CONTROL — offset `0x08`

| Bits | Behavior |
|---|---|
| `[31:0]` | reads zero; writes ignored (RAZ/WI) |

### 12.4 UART_BAUD — offset `0x0C`

| Bits | Behavior |
|---|---|
| `[15:0]` | read/write baud divisor |
| `[31:16]` | reads zero; writes ignored |

## 13. Reset State

On `PRESETn=0`, both UARTs reset to:

```text
programmed_baud_div = 434
tx_active_baud_div  = 434
rx_active_baud_div  = 434
tx_busy        = 0
TX output      = 1 (idle)
RX state       = IDLE
RX FIFO count  = 0
RX pointers    = 0
RX_ERROR       = 0
RX synchronizer= 1 / 1
```

UART0 additionally resets:

```text
AUX synchronizer = 0 / 0 (NOT READY)
```

FIFO data-array contents are not architecturally initialized; the zero FIFO count makes them invalid until bytes are received.

## 14. Interrupt Architecture

Neither UART exposes an interrupt output in the active FPGA baseline.

There is no active behavior for:

```text
RX interrupt
TX-empty interrupt
error interrupt
AUX interrupt
```

All UART activity is software-polled.

`UART_CONTROL` shall not be interpreted as an interrupt-enable register until a future interrupt/PLIC specification explicitly assigns such behavior.

When PLIC integration is designed, UART interrupt behavior must be specified before RTL changes, including source IDs, level/edge policy, pending-clear semantics, FIFO thresholds, and interaction with `RX_ERROR`.

## 15. Firmware Contract

Baseline firmware shall follow these rules:

1. Use canonical UART0/UART1 addresses only.
2. Use aligned 32-bit MMIO register accesses.
3. Poll `TX_READY` before every `UART_DATA` write.
4. Poll `RX_READY` before every `UART_DATA` read.
5. Treat each `UART_DATA` read as one FIFO pop.
6. Treat `RX_ERROR` as sticky and acknowledge it with `UART_STATUS[2]` W1C.
7. Do not depend on any behavioral effect from `UART_CONTROL`.
8. Program only divisors 217..65535; active frames retain their captured divisor.
9. For LoRa transmission, also verify synchronized AUX high according to the module-level firmware policy.
10. Do not access noncanonical local offsets; they read zero/write-ignore.

Current production drivers use finite polling budgets and return explicit
success/timeout/invalid results. The LoRa wrapper additionally distinguishes
AUX timeout from UART TX timeout and checks AUX before every byte.

## 16. Verification Requirements

Baseline verification should cover at minimum:

- reset register/status values,
- default divisor and measured bit period,
- 8-N-1 TX bit ordering,
- TX ready transition before/after one frame,
- write-while-busy behavior,
- back-to-back software-polled TX bytes,
- RX false-start rejection,
- correct LSB-first RX reconstruction,
- RX FIFO fill from 0 through 16 bytes,
- one-byte pop per `UART_DATA` read,
- simultaneous FIFO push/pop,
- FIFO overflow byte-drop behavior,
- framing-error detection,
- current `RX_ERROR` clear behavior,
- empty FIFO read policy,
- baud changes at safe and unsafe times,
- UART0 AUX synchronization and status reporting,
- proof that UART1 bit 3 remains zero,
- register-mirror behavior being excluded from canonical software tests.

For FPGA validation, UART1 can be looped to a PC serial terminal/test harness and UART0 can be checked against the LoRa module or an electrical UART peer. Firmware-level success alone is not proof of physical serial timing or pin connectivity.

## 17. Historical Pre-P07 Cleanup Targets

The following table preserves the pre-P07 cleanup inventory. P07B now provides
closure-candidate evidence for C01..C08/C11; the table is historical and does
not override the current contract or tracker review gate.

| ID candidate | Priority | Issue | Required direction |
|---|---|---|---|
| UART-C01 | P1 | TX busy termination holds `TX_READY=0` for one extra idle bit period | correct TX bit-count completion and re-verify baud/frame timing |
| UART-C02 | P1 | TX write while busy is silently dropped | define explicit policy; preferably prevent software-visible silent loss through FIFO/backpressure/error semantics |
| UART-C03 | P1 | `RX_ERROR` conflates framing error and FIFO overflow | define separate/sticky error semantics or explicit counters/status bits |
| UART-C04 | P1 | `RX_ERROR` auto-clears on normal push/pop | define deterministic software-clear behavior if reliable diagnostics are required |
| UART-C05 | P1 | Empty `UART_DATA` read exposes non-meaningful FIFO storage | define deterministic empty-read behavior or require guarded access in hardware contract |
| UART-C06 | P1 | Baud divisor accepts zero/unsafe values and may be changed mid-frame | define legal range and safe-update behavior |
| UART-C07 | P1 | `UART_CONTROL` is storage-only | either define actual control/IRQ semantics with PLIC work or remove misleading behavior |
| UART-C08 | P1 | Low-bit register decode creates 16-byte mirrors | tighten decode to canonical offsets or explicitly reject reserved offsets |
| UART-C09 | P2 | UART0/UART1 duplicate almost all RTL | consider common UART core plus LoRa AUX wrapper to reduce divergence risk |
| UART-C10 | P1 | No interrupt architecture | define RX/TX/error interrupt sources before PLIC integration |
| UART-C11 | P1 | UART directed protocol regression is not yet a baseline signoff artifact | add deterministic RTL tests for TX/RX/FIFO/error/AUX corner cases |

These cleanup targets document current implementation weaknesses; they do not change the present baseline behavior until approved RTL/spec updates are made.

## 18. Baseline Invariants

The current baseline shall be treated as obeying these invariants:

```text
UART0 base = 0x4000_0000
UART1 base = 0x4006_0000
register offsets = 0x00 / 0x04 / 0x08 / 0x0C
PCLK = 50 MHz
PREADY = 0 only for a busy DATA write; otherwise 1
format = 8-N-1, LSB first
reset baud divisor = 434
RX FIFO depth = 16 bytes
TX FIFO depth = 0
TX firmware polling is bounded; hardware backpressures busy DATA writes
RX requires software polling
UART0 status[3] = synchronized LoRa AUX
UART1 status[3] = 0
UART_CONTROL is RAZ/WI
no UART interrupt output exists
```

Any future change to these architectural properties requires an approved specification update first.

## 19. Related Specifications and Sources

Logical specification dependencies:

```text
soc_architecture.md
memory_map.md
apb_subsystem.md
reset_clock.md
interrupt_architecture.md
firmware_contract.md   # future
```

Primary active implementation evidence:

```text
rtl/peripherals/APB_UART_RT.v
rtl/peripherals/APB_UART_LORA_RT.v
rtl/soc/AMBA_SoC_TOP.v
firmware/include/soc_memory_map.h
firmware/include/uart.h
firmware/include/lora_uart.h
firmware/drivers/uart.c
firmware/drivers/lora_uart.c
```

## Phase 4A-2 Approved UART Target (not active RTL)

A4 requires a busy `UART_DATA` APB write to hold `PREADY=0` until it can latch exactly one byte and start exactly one TX frame; silent drop is forbidden. `TX_READY` means an immediate DATA write can be accepted and deasserts at acceptance. Other registers do not stall merely because TX is busy. There is no UART-specific hardware timeout; every supported baud setting must guarantee TX progress. `UART_BAUD` remains a divisor, not a rate enumeration: nominal baud is 50 MHz / `BAUD_DIV`, default divisor 434 (~115200). Hardware must not whitelist only standard rates. Firmware presets include 9600, 19200, 38400, 57600, 115200, and 230400; other safe rates are allowed when peer timing permits. `BAUD_DIV=0` must not become active. Current TX/RX counters, start-bit sampling and input synchronization do not establish a high-confidence numerical lower bound, so `MIN_SAFE_BAUD_DIV = unresolved implementation constraint`; derive and verify it before implementation acceptance, and reject/prevent any unsafe divisor from becoming active. Firmware uses bounded `TX_READY` polling. STA-002 owns UART pin voltage/standard, asynchronous RX classification, drive/load and peer timing evidence; do not fabricate synchronous input delay for RX.

## Phase 4A-P05A Approved LoRa AUX Contract — Implementation Target

For the project interface, E220-900T22D AUX is an asynchronous module-to-FPGA **level-status** signal. `HIGH = READY` and `LOW = NOT READY`; a current synchronized HIGH permits the next UART-side write/transmission. Readiness is not an edge event and has no project-level valid-after-rising window or post-rising UART delay requirement. Do not add an AUX edge detector, pulse stretcher, minimum-high counter, or delay counter for this contract.

The existing `lora_aux -> aux_sync_1 -> aux_sync_2` CDC is accepted. P05B shall retain that two-flop structure but change both synchronizer reset values from HIGH to LOW/NOT READY, so reset alone cannot expose a false ready state. This reset-value change is an approved target, not current RTL behavior. Hardware continues to expose the synchronized level; firmware continues to own readiness polling. Bounded waits, error handling, and E220 mode management remain separate UART/firmware work.

## Phase 4A-P05B LoRa AUX — Current Implementation

The approved AUX reset-value change is active in the current RTL: both synchronization stages reset LOW, so `UART_STATUS[3]` reports NOT READY throughout reset even when the physical input is HIGH. After reset, the unchanged two-flop path reports the persistent level with `HIGH=READY`; there is no edge detector, pulse stretcher, minimum-high qualifier, or post-rising delay. UART0/UART1 RX synchronizers and RX state machines were not changed, and focused full-byte RX regression passed for both production modules at multiple input phases. This scoped evidence does not close broader UART cleanup items such as backpressure, divisor range, or complete protocol signoff.

## 20. Phase 4A-P07B Current UART Contract

P07B implements the same public map and polling-only roles for UART0/LoRa and
UART1/PC. There is still no UART IRQ and `UART_CONTROL` is now explicitly
reserved read-as-zero/write-ignored (RAZ/WI).

The current register behavior is:

- A busy `UART_DATA` write holds `PREADY=0`; the held APB ACCESS is accepted
  exactly once when TX becomes available. Other UART registers do not stall
  solely because TX is busy.
- `TX_READY` means a DATA write can be accepted immediately. It deasserts on
  acceptance and returns on the edge completing the one stop-bit interval;
  there is no additional idle divisor interval.
- TX remains exact 8-N-1, LSB first, with no TX FIFO.
- Each RX FIFO remains 16 bytes. A valid frame is pushed only after a valid
  stop bit; a full FIFO drops the incoming byte and preserves queued data.
- Empty `UART_DATA` reads return zero and do not pop or alter error state.
- `RX_ERROR` is a combined framing/overflow sticky bit. Normal push/pop cannot
  clear it. Software clears it by writing one to `UART_STATUS[2]`; a new error
  wins over same-cycle W1C.
- Only offsets `0x00/0x04/0x08/0x0c` decode locally; old 16-byte register-bank
  mirrors are removed.

`UART_BAUD` exposes `programmed_baud_div`. Reset is 434. Values 217..65535 are
accepted; 0..216 are ignored and preserve the prior value. TX captures a
private active divisor on DATA acceptance and RX captures a private active
divisor on start detection. A later BAUD write therefore affects only a later
frame in that direction. A BAUD write coincident with RX start detection uses
the old programmed value for that frame.

The P05 CDC/reset boundary is preserved: each RX input uses the existing
high/high-reset two-flop synchronizer; LoRa AUX uses the existing low/low-reset
two-flop synchronizer and remains a persistent `HIGH=READY` level reported in
UART0 status. Hardware does not gate TX with AUX.

Focused evidence covers both production modules, cycle-checked TX at divisors
217 and 434, RX and FIFO/error corner cases, active-divisor isolation,
full-duplex operation, reset, actual AHB/APB wait propagation, firmware mock
MMIO ordering, P05 preservation, open/bus regressions, whole-SoC lint and
elaboration, and affected RV32I firmware builds. The focused RX_ERROR
supplement explicitly checks both independent production modules and passed as
`p07b_uart_supplement_02` with wrapper exit 0. User/Chat approved this combined
evidence for Open Verification, so `UART-001..004` are `VERIFIED`. This is not
post-fit or physical serial acceptance: `UART-005` remains open for PC/LoRa
board evidence, while `UART-006` and UART IRQ remain optional/open and deferred
as already tracked.
