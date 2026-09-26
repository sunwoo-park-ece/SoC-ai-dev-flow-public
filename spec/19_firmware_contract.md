# SoC Firmware Contract

> **Issue #7 S1 application-role freeze:** `firmware/apps/final_main.c` is **HISTORICAL RC-CAR SYSTEM DEMO FIRMWARE**, retained for provenance/demo reproduction and dependent on the external STM32-based RC-car system. It is not the canonical standalone SoC integration-test firmware and, after Issue #7 completion/review, is not the basis for Issue #6 C4-A/C4-B. Owner-provided [FPGA SoC + STM32 RC-car demo](https://www.youtube.com/shorts/XYbi3uSHmUU).
>
> The future canonical app is `firmware/apps/soc_health_main.c`; its approved contract and temporary baseline-cleanup spec/FW reconciliation ledger are [spec 22](22_soc_health_firmware.md). S1 is documentation only: app/services/providers/getters remain unimplemented and C4 remains paused. The monitor reports `AES_GCM = EXCLUDED_PENDING_CLEANUP`, contributes AES to neither PASS nor FAIL, and executes no AES operations. This application exclusion does not alter the existing AES hardware/driver contract. Existing per-IP rules and historical sections remain intact; broad reconciliation is deferred to the ledger's later coordinated pass.

> **P09 closure note (2026-09-17):** Section 12 defines the active coherent G-sensor firmware contract (`gsensor_read_sample()`) and supersedes the historical raw telemetry description. RV32I builds and host mock-MMIO tests pass; `FW-008` is `IN_PROGRESS` for residual negative/race coverage.

> **P07 closure note (2026-09-16):** Section 38 is the current UART/LoRa
> firmware contract and supersedes the historical UART-specific statements in
> §§7–8. User/Chat approved P07B for Open Verification; the UART/LoRa sub-scope
> contributes evidence to global `FW-002`, which remains `OPEN` because other
> peripheral waits are not closed.

> **P06 closure note (2026-09-16):** The public Timer driver and active applications use the A5 command contract. Section 37 supersedes the historical Timer sequences in §9 for the current public candidate. User/Chat approved the P06B evidence and `FW-004` is VERIFIED; `FW-002` remains open.

> **P04 closure note (2026-09-15):** Public firmware uses dedicated GPIO (JP1), SW (slot 8), and LED (slot 9) drivers. Earlier combined GPIO/SW/LED usage is historical. Open firmware builds/host smoke and the matching structural Quartus fit pass. User/Chat approved `FW-006/FW-011` as `VERIFIED`; `FW-005/FW-007` remain non-verified because their explicit board tests are absent.

> **Status:** DRAFT — current-baseline software contract plus approved target rules for the baseline-cleanup redesign.
>
> **Canonical language:** English. If this file and `firmware_contract.ko.md` conflict, this file is authoritative.
>
> **Related specifications:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`, all peripheral specifications, and `board_io_architecture.md`.

## 1. Purpose

This document defines how firmware is allowed to use the SoC.

Peripheral specifications define what hardware registers and signals do. This document defines the software-side rules that compose those blocks into a consistent runtime contract:

- startup and linker assumptions,
- MMIO access rules,
- driver ownership,
- peripheral initialization and service ordering,
- polling and timeout behavior,
- current polling-only interrupt model,
- approved target interrupt/PLIC preparation,
- cryptographic sequencing and authentication rules,
- board-I/O migration,
- error handling,
- firmware verification requirements.

The document is intentionally divided into two contracts:

```text
CURRENT BASELINE
    = rules required by the FPGA design and firmware that exist today

APPROVED TARGET
    = rules firmware shall follow after the baseline-cleanup redesign
```

A target rule shall not be cited as evidence that the current FPGA image already implements that behavior.

---

# Part I — Current Baseline Firmware Contract

## 2. Execution Environment

The active firmware environment is bare-metal RV32I.

The startup path is:

```text
reset / instruction fetch
        |
        v
      _start
        |
        +--> sp = __stack_top
        +--> clear .bss with 32-bit stores
        +--> call main
        |
        v
if main returns -> infinite loop
```

The current startup code does not provide:

- an operating system,
- threads,
- processes,
- dynamic interrupt dispatch,
- a C library runtime beyond the explicitly linked firmware support,
- automatic constructors/destructors unless separately provided,
- automatic peripheral initialization.

Firmware shall therefore explicitly initialize every peripheral state on which the application depends.

## 3. Linker and Memory Contract

The current linker contract is:

```text
IMEM  0x0000_0000 .. 0x0000_3FFF   16 KiB
DMEM  0x1000_0000 .. 0x1000_7FFF   32 KiB
```

Section placement is conceptually:

```text
.start / .text / .init / .fini -> IMEM
.rodata / .data / .sdata       -> DMEM initialized image
.bss / .sbss / COMMON          -> DMEM, cleared by startup
stack                           -> top of DMEM
```

The current design does not copy initialized data from IMEM into DMEM at runtime. Initialized DMEM content is part of the FPGA memory-image flow. Therefore the selected firmware build and the selected IMEM/DMEM MIF images form one inseparable firmware artifact.

System reset does not architecturally scrub the entire DMEM. Firmware may assume only that `.bss` is cleared by `_start` and that initialized DMEM sections contain the values placed into the selected memory image.

Firmware shall not use non-canonical DMEM or VRAM aliases even when coarse RTL decode causes them to access physical storage.

## 4. Current Canonical MMIO Map

The current firmware-visible APB bases are:

```text
UART0_BASE       = 0x4000_0000
GPIO_BASE        = 0x4001_0000
TIMER_BASE       = 0x4002_0000
GSENSOR_BASE     = 0x4003_0000
AES_GCM_BASE     = 0x4004_0000
ADC_BASE         = 0x4005_0000
JOYSTICK_BASE    = ADC_BASE   /* transitional P11 migration alias only */
UART1_BASE       = 0x4006_0000
HEX_DISPLAY_BASE = 0x4007_0000
```

The current APB implementation exposes only `PSEL[7:0]`. `0x4008_0000` and above are not active SW/LED peripherals in the current FPGA baseline.

Firmware shall use only addresses declared canonical by `memory_map.md` and the individual peripheral specifications. Physical register mirroring inside a 64-KiB slot is not a supported software interface.

## 5. MMIO Access Rules

### 5.1 Peripheral MMIO

The normative current rule is:

> **APB peripheral registers shall be accessed with naturally aligned 32-bit reads and writes.**

The current AHB-to-APB bridge does not propagate `HSIZE` and does not provide `PSTRB`. Therefore byte or halfword stores to APB registers shall not be treated as supported partial-register writes.

The generic firmware header currently contains `mmio_read8()` and `mmio_write8()` helpers. Their existence does not make 8-bit APB accesses architectural.

### 5.2 VRAM exception and current driver caveat

Framebuffer storage is an AHB-side block, not an APB peripheral. However, the active VGA write path does not provide a general byte-enable contract and the VGA specification defines aligned 32-bit framebuffer writes as normative.

The P08B local candidate removes the legacy `vram_write_byte()` helper. Firmware updates the framebuffer through aligned 32-bit word writes and software packing; no byte-write or readback API is supported.

### 5.3 Volatile semantics

MMIO accesses shall remain volatile and ordered by program order as required by the current single-core bare-metal implementation. Applications shall use the project MMIO helpers or peripheral drivers rather than casting arbitrary reserved addresses to pointers.

## 6. Driver Ownership — Current Baseline

The repository already provides dedicated drivers for several peripherals. Current applications should prefer these APIs over direct register accesses:

```text
UART0/UART1   -> uart driver
GPIO          -> gpio driver
Timer         -> timer driver
G-Sensor      -> gsensor driver
VGA/VRAM      -> vram/display support
AES-GCM       -> aes_gcm driver
ADC / Joystick -> generic ADC driver + joystick policy layer
HEX Display   -> hex_display driver
```

Direct MMIO still exists in legacy/application code and is not globally prohibited by the current baseline. However, code shall not mix direct writes with a driver that maintains private software state.

The current HEX driver maintains `hex_ctrl_shadow`. Therefore application code that uses the HEX driver shall not independently write `HEX_CTRL`, because doing so can desynchronize the software shadow from the hardware register.

## 7. Current Polling Model

The active CPU has no integrated external interrupt path and no active PLIC. Peripheral service is therefore polling-based.

Current drivers still contain unbounded waits outside the UART/LoRa sub-scope,
including conceptually:

```text
Timer READY wait
VGA VSYNC wait
VGA clear-busy wait
AES-GCM DONE wait
```

P07B migrated normal UART TX and LoRa AUX/TX entry points to finite caller
budgets or documented finite defaults with explicit results. The remaining
items above are current implementation behavior, not a recommended reliability
property. Firmware using those routines accepts that a non-responding
peripheral can stall the CPU indefinitely.

Applications that require forward progress should use their own bounded polling around status APIs where practical until the target driver contract is implemented.

## 8. UART0 / UART1 Rules

UART0 and UART1 share the same register contract. UART0 is the LoRa-facing port in the baseline; UART1 is the PC-facing port.

Current TX rule:

```text
use a bounded TX_READY poll
then write UART_DATA when ready
```

A busy DATA write is also protected by APB `PREADY` backpressure and is accepted
exactly once when the transmitter becomes available. Firmware retains the
bounded ready check to provide a software timeout rather than depending on an
unbounded bus stall.

Current RX rule:

```text
if RX_READY = 1
    read UART_DATA
else
    no byte is available
```

The current driver implements non-blocking receive and bounded/status-returning
transmit helpers. It exposes sticky combined RX error query and
`UART_STATUS[2]` W1C acknowledgement according to `09_uart.md`.

`UART_CONTROL` is reserved RAZ/WI and shall not be assumed to enable
unimplemented interrupt functionality.

## 9. Timer Rules

The current timer is polling-based.

A safe software service sequence for a new one-shot/count interval is:

```text
1. clear stale READY if set
2. program COMPARE
3. enable timer
4. poll READY
5. clear READY before reuse
```

Firmware shall not assume that writing a new compare value alone clears an existing READY condition.

The hardware counter semantics are defined by `timer.md`; software shall not infer a wall-clock duration without converting from the active PCLK/HCLK frequency and the timer's documented compare behavior.

`timer_delay_cycles()` is a CPU instruction-delay loop, not a peripheral-timer measurement and not a precise real-time API across CPU-frequency changes.

## 10. VGA / VRAM Rules

The CPU-visible framebuffer is the back buffer.

Normative framebuffer access is:

```text
aligned 32-bit writes
within 0x2000_0000 .. 0x2000_95FF
```

Firmware shall not depend on framebuffer readback because the active VGA subsystem does not provide a normal CPU framebuffer-read contract.

A normal publish sequence is conceptually:

```text
draw complete frame into back buffer
        |
        v
wait for / observe VSYNC policy
        |
        v
request SWAP
```

If hardware clear is used, firmware shall obey the `CLEAR_BUSY` / `CLEAR_DONE` semantics in `vga.md` and shall avoid assuming that concurrent framebuffer writes are preserved.

Current infinite polling helpers can hang if VSYNC or clear completion never arrives. Diagnostic applications that need fault tolerance should use a bounded poll as `display_smoke` already does for VSYNC.

## 11. Legacy GPIO Rules

The current GPIO block is not a true bidirectional GPIO peripheral.

Current meanings are:

```text
GPIO_DATA write -> internal output latch
GPIO_DIR bit 0  -> GPIO_DATA read selects SW input
GPIO_DIR bit 1  -> GPIO_DATA read selects output latch
```

Physical current mapping:

```text
SW[9:0]        -> GPIO input path
GPIO out[8:0]  -> LEDR[8:0]
LEDR[9]        -> reset indicator, not GPIO controlled
```

`gpio_led_write()` therefore manipulates the legacy pseudo-GPIO mapping and shall not be treated as a generic GPIO API.

GPIO register readback proves register/latch state, not physical LED pin state.

## 12. G-Sensor Firmware Contract

The G-sensor subsystem provides a coherent software-visible sample publication ABI using LIVE and HOLD banks. Firmware accesses accelerometer data through the production driver API:

```c
gsensor_status_t gsensor_read_sample(gsensor_sample_t *out);
```

The sample structure returns coherent signed 16-bit axes and sequence identification:

```c
typedef struct {
    int16_t x;
    int16_t y;
    int16_t z;
    uint32_t seq;
} gsensor_sample_t;
```

### 12.1 Driver Lifecycle and Polling Protocol

The driver enforces a strict single-owner, non-reentrant lifecycle:

```text
STATUS read
    |
    +--> if HOLD_VALID == 1 -> return GSENSOR_BUSY
    +--> if LIVE_VALID == 0 -> return GSENSOR_NO_NEW
    |
write SNAP_CTRL = 1 (CAPTURE)
    |
STATUS read
    |
    +--> if HOLD_VALID != 1 -> return GSENSOR_NO_NEW (capture failed / no new data)
    |
read HOLD_SEQ
read HOLD_XY_DATA
read HOLD_Z_DATA
    |
write SNAP_CTRL = 2 (RELEASE)
    |
return GSENSOR_OK (sample populated in *out)
```

### 12.2 Result Semantics

| Status | Meaning | Driver action |
|---|---|---|
| `GSENSOR_OK` | Successful coherent sample acquired | Sample copied to `*out`, HOLD released |
| `GSENSOR_NO_NEW` | No new complete sample available | No CAPTURE or failed capture; HOLD remains/released |
| `GSENSOR_BUSY` | HOLD bank is currently occupied or caller contention | No MMIO modification; caller must retry later |
| `GSENSOR_ERROR` | Null pointer or unrecoverable error | No sample written; caller must handle |

### 12.3 Ownership and Reentrancy Constraints

- **Single Owner:** The driver is single-owner and non-reentrant. It must not be invoked concurrently or from an interrupt context that preempts another driver invocation.
- **No Stale Data:** The driver never returns stale HOLD data as a new sample. An ineligible CAPTURE (when `LIVE_VALID = 0`) acts as a hardware no-op and returns `GSENSOR_NO_NEW`.
- **Caller Contention Guard:** Callers may implement software concurrency protection; unexpected contention returns `GSENSOR_BUSY`.
- **Bus Faults:** An APB/AHB error from malformed addresses or access sizes raises a CPU exception under the system trap policy, not a recoverable `GSENSOR_ERROR`.

### 12.4 Reset Semantics

- System reset asynchronously clears both LIVE and HOLD banks, SEQ, and VALID bits.
- Any transfer interrupted by reset has no guaranteed return value.
- Following reset release, `VALID` remains 0 until the 12-write initialization completes and the first full digital burst finishes.

## 13. ADC / Joystick Firmware Rules — P11 Target (In-progress)

P11 introduces a generic ADC driver contract at `ADC_BASE = 0x4005_0000`. A temporary `JOYSTICK_BASE` alias may exist only as migration compatibility; new code shall use the generic ADC naming.

Firmware shall not program runtime channel selection in P11. The Clean Baseline hardware scan is fixed/read-only:

```text
ACTIVE_MASK = 0x03
command CH1 -> raw slot CH1
command CH2 -> raw slot CH2
```

CH3..CH6 addresses are reserved canonical RO raw-data locations and return zero/invalid in this baseline.

### 13.1 Acquisition enable

`ADC_CTRL.ENABLE` is a real persistent acquisition request. Software distinguishes request from hardware acknowledgement:

```text
ADC_STATUS.ENABLE_REQ
ADC_STATUS.ENGINE_ENABLED
```

Code that requires the engine to be quiescent shall wait for the acknowledged state with a bounded poll budget. Disable preserves the previous HOLD snapshot but prevents publication of a partial post-disable frame.

### 13.2 CAPTURE-only snapshot

Firmware reads coherent ADC data only from HOLD registers.

Recommended sequence:

```text
1. inspect LIVE_VALID / NEW_FRAME as needed
2. write CAPTURE
3. read HOLD FRAME_SEQ / VALID_MASK / CHx_RAW
4. no RELEASE step
```

If no newer LIVE frame exists, CAPTURE returns normal bus success and is a no-op. Existing HOLD remains readable. This differs intentionally from the P09 G-sensor `CAPTURE -> HOLD ownership -> RELEASE` lifecycle.

### 13.3 Generic ADC versus joystick policy

The ADC driver returns raw coherent frame data. Joystick interpretation is a separate policy layer.

Firmware shall implement an independent `joystick_policy_eval()`-class function from raw HOLD CH1/CH2, HOLD valid mask, and the current center/deadzone parameters. It may also read hardware `JOY_STATUS` and compare the two results during verification, but the software result shall not be derived from the hardware result.

Calibration semantics are live-policy semantics:

```text
JOY_STATUS = current center/deadzone applied to current HOLD sample
```

Thus changing calibration may change direction without a new CAPTURE.

Physical X/Y polarity and application/ASCII mapping remain **(In-progress)** board acceptance. Firmware shall not preserve the historical LEFT->`d`, RIGHT->`a` quirk as an architectural requirement.

### 13.4 Error and count use

`ERROR_STATUS` contains sticky acquisition/protocol errors and is cleared only by the defined W1P clear command. `FRAME_COUNT` counts completed frames published into PCLK LIVE, not individual ADC responses or CAPTURE calls.

Normal firmware shall use exact 32-bit aligned v2 offsets and shall not rely on historical local mirrors or removed live response-debug fields.

## 14. HEX Display Rules

The HEX driver owns the software control shadow when that driver is used.
`hex_display.c` is the sole software writer of `HEX_CTRL`: application/ISR
direct writes and uncontrolled concurrent writers are prohibited. Shadow and
CTRL writes retain only bits `[1:0]` (`& HEX_CTRL_MASK`, `0x3`); normal
helpers remain Shadow-based rather than hardware read-modify-write. Normal
system reset plus firmware initialization sets hardware CTRL and Shadow to `0x1`.

The driver implements explicit boot initialization and resynchronization APIs:

```c
void hex_display_init(void);
void hex_display_resync(void);
```

At boot, firmware calls `hex_display_init()` to establish the boot shadow (`0x1`)
and write hardware `CTRL = 0x1`. After a HEX-only reset during execution, or a
suspected out-of-band change, the caller invokes `hex_display_resync()` **before
the next CTRL update** to read hardware CTRL, mask `& HEX_CTRL_MASK`, and update
Shadow. This does not imply automatic reset detection or authorize out-of-driver
writes. Any future ISR/multi-context owner must serialize driver access.

Decoded-value mode packs:

```text
VALUE[3:0]   -> HEX0
...
VALUE[23:20] -> HEX5
```

Applications using `hex_display_write_monitor()` may use the existing six-nibble monitor convention, but that convention is application-level and not an architectural register requirement.

Raw mode and display-enable semantics are defined in `hex_display.md`.

The current top-level exposes seven segments per digit; firmware shall not assume decimal-point control.

## 15. AES-GCM Rules

The current wrapper is an AES-128, single-payload-window accelerator. The firmware contract is stricter than the current driver implementation.

### 15.1 Length

Firmware shall enforce:

```text
0 <= LEN <= 16 bytes
```

The current hardware does not safely reject every value greater than 16. Passing `LEN > 16` is invalid firmware behavior.

### 15.2 Operation ownership

Before START, firmware shall completely program the required operation state:

```text
KEY
NONCE_DIR
SEQ_HI / SEQ_LO
LEN
PAYLOAD_IN
TAG_IN for decrypt
```

While `BUSY=1`, firmware shall not modify these operation inputs and shall not issue another START.

### 15.3 Decrypt authentication rule

For decryption:

> **PAYLOAD_OUT shall not be consumed as authenticated plaintext until the operation is DONE, TAG_OK is asserted, and ERROR is clear.**

A generated plaintext value existing in output registers before authentication succeeds does not make it trustworthy.

### 15.4 IV uniqueness

The current IV construction includes session/direction information and sequence state. Firmware/protocol logic owns sequence allocation and shall prevent IV reuse under the same key.

```text
same AES key + same effective IV = forbidden
```

Hardware does not automatically allocate/increment a safe global sequence number.

### 15.5 Key handling limitation

The current accelerator is not a secure key vault. Key registers are software-visible and remain programmed until overwritten/reset. Firmware shall not represent the current design as secure key storage.

## 16. Current Error-Handling Limitations

Current bus behavior does not provide a reliable architectural fault for every invalid address:

```text
unmapped access
    -> can complete with zero / OKAY
```

The CPU does not consume a meaningful bus-error path for access-fault handling in the current baseline.

Therefore firmware correctness must be based on compile-time canonical addresses and driver contracts, not runtime probing of arbitrary MMIO space.

Peripheral status errors such as AES `ERROR` or UART RX error shall be handled at the peripheral level.

---

# Part II — Approved Target Firmware Contract

## 17. Target Principles

After the baseline-cleanup redesign, firmware shall follow these project-wide principles:

1. canonical MMIO addresses only,
2. naturally aligned 32-bit peripheral MMIO unless a future spec explicitly adds strobes/partial access,
3. one driver owns each stateful peripheral register set,
4. application code does not bypass driver-owned software shadows or sequencing,
5. every hardware-completion wait exposed as a normal firmware API is bounded,
6. driver APIs return explicit success/error status for operations that can fail or time out,
7. interrupt-capable peripherals clear/resolve the local source before PLIC completion,
8. cryptographic output is consumed only after authentication succeeds,
9. firmware source and selected IMEM/DMEM images are versioned as one reproducible build artifact,
10. target behavior is enabled only after corresponding RTL/DV/FPGA evidence exists.

## 18. Target APB / Board-I/O Map

After the approved board-I/O migration is implemented, firmware shall use:

```text
0x4000_0000 UART0 / LoRa
0x4001_0000 GPIO
0x4002_0000 Timer
0x4003_0000 G-sensor
0x4004_0000 AES-GCM
0x4005_0000 ADC / Joystick Policy
0x4006_0000 UART1 / PC
0x4007_0000 HEX Display
0x4008_0000 SW
0x4009_0000 LED
0x400A_0000 .. 0x400F_FFFF Reserved slots 10..15
```

This map corresponds to target `PSEL[15:0]` and does not move existing slot 0..7 bases.

Firmware constants for SW/LED shall be introduced only in the same migration milestone that integrates those peripherals into RTL and verification.

## 19. Target Driver Ownership

The target software stack shall provide one clear owner per peripheral:

```text
uart.*          -> UART0/UART1 register sequencing
 timer.*         -> timer programming/status/timeout
 vram/display.*  -> framebuffer/control sequencing
 gpio.*          -> external generic GPIO only
 sw.*            -> DE10-Lite SW state + local IRQ control
 led.*           -> DE10-Lite LED output
 gsensor.*       -> coherent sensor sample API after RTL cleanup
 adc/joystick.*  -> coherent ADC/joystick sample API
 aes_gcm.*       -> validated crypto transaction API
 hex_display.*   -> HEX register and control-shadow ownership
```

Application code shall not directly write a register that is owned by a stateful driver unless the driver contract explicitly exposes a raw/debug operation.

Register definitions may remain visible in common headers for verification and low-level bring-up, but normal application code shall use drivers.

## 20. Target Bounded-Wait Policy

A target driver shall not expose an unbounded wait as its only normal API when hardware completion can fail to arrive.

Operations such as:

```text
UART transmit readiness
Timer completion
VGA VSYNC
VGA hardware clear
AES-GCM completion
future peripheral-ready handshakes
```

shall provide a bounded form conceptually equivalent to:

```c
status_t operation_wait(uint32_t budget);
```

or a non-blocking/status-query API from which a caller can implement a deadline.

Timeout shall produce an explicit software error rather than silently continue as if the peripheral completed.

A deliberately infinite wait may exist only as a clearly named debug/boot primitive where permanent blocking is the intended policy.

## 21. Target GPIO / SW / LED Contract

### 21.1 GPIO

`GPIO_BASE = 0x4001_0000` remains unchanged, but target firmware shall use the redesigned true GPIO registers defined by `gpio.md`:

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

The target GPIO driver shall not expose legacy `gpio_led_write()` semantics.

Generic GPIO is for selected external bidirectional pins only; it does not own DE10-Lite SW or LED signals.

### 21.2 SW

Target SW firmware uses:

```text
SW_BASE = 0x4008_0000
```

and the `SW_DATA`, `SW_IRQ_ENABLE`, and W1C `SW_IRQ_PENDING` contract from `sw.md`.

Polling applications may keep IRQ enable zero and read `SW_DATA`.

Interrupt applications shall treat pending as a change indication, not a transition-count queue.

### 21.3 LED

Target LED firmware uses:

```text
LED_BASE = 0x4009_0000
```

and a dedicated ten-bit `LED_DATA` latch.

All ten `LEDR[9:0]` bits become software-controlled through the LED driver. The old GPIO LED helper and the special `LEDR[9]` reset-indicator assumption shall be removed from target applications.

## 22. Target Interrupt / PLIC Preparation

The target board-I/O peripherals expose local active-high level interrupt wires:

```text
gpio_irq
sw_irq
```

Until the PLIC is implemented, these wires may exist without CPU interrupt service.

After PLIC integration, firmware shall follow this generic service ordering for a level-sensitive peripheral source:

```text
1. claim source from PLIC
2. read peripheral-local cause/pending state
3. service the peripheral
4. clear or otherwise resolve the local source condition
5. ensure the local IRQ can deassert when appropriate
6. complete the PLIC claim
```

Completing the PLIC while the local level source remains asserted may cause immediate re-pending and is not a software-visible peripheral fault.

PLIC source IDs, PLIC MMIO addresses, CSR enable rules, and `mcause` encoding are intentionally outside this firmware contract until the dedicated PLIC specification is approved.

## 23. Target UART Contract

The target UART driver shall preserve TX-ready-before-write behavior and shall add a bounded transmit API for callers requiring forward progress.

If later UART cleanup adds interrupt-driven RX/TX, the polling APIs may remain as boot/debug primitives, but interrupt-enable fields shall not be used by firmware until the matching RTL and PLIC source contract are verified.

Driver APIs shall expose RX framing/overflow/error state in a way that does not silently discard the information available from the hardware status model.

## 24. Target Timer Contract

The target timer driver shall own restart sequencing so callers do not need to remember stale READY behavior.

Conceptually, `timer_start()` or its replacement shall establish a deterministic new interval by clearing/initializing all state required by the approved timer RTL contract before enabling counting.

Timeout/deadline helpers used to guard other peripherals should prefer a verified timer-derived budget rather than optimization-sensitive CPU `nop` loops when timing accuracy matters.

Future timer IRQ service shall be specified only when a local timer IRQ wire and PLIC mapping are approved.

## 25. Target VGA Contract

Frozen A3 requires word-oriented framebuffer writes and removal/deprecation of byte-write helpers; byte strobes/RMW are not part of baseline cleanup.

VGA helper APIs shall provide bounded VSYNC/clear waits.

A buffer publish helper should hide the required ordering among:

```text
finish drawing
wait/observe synchronization policy
request SWAP
optional clear sequencing
```

so application code does not duplicate hardware-specific sequencing.

## 26. Target G-sensor Contract

After G-sensor cleanup, firmware shall consume a coherent PCLK-domain sample publication rather than independent unsafe multi-bit CDC registers.

The preferred target software abstraction is one sample record such as:

```text
x
y
z
valid
sequence
```

or an equivalent coherent snapshot defined by the final RTL spec.

Firmware shall reject/use-no-sample semantics before first valid acquisition and shall not compensate in software for any RTL byte/bit reconstruction defect. If directed verification proves a reconstruction bug, RTL and spec shall be fixed.

The private ADXL345 SPI transport remains hardware-owned unless a separate generic SPI peripheral is later approved.

## 27. Target ADC / Joystick Contract — P11 Frozen (In-progress)

The P11 firmware target is frozen as follows:

- generic ADC MMIO at slot 5 owns coherent raw-frame access;
- real ENABLE request/ack semantics replace the historical disconnected enable bit;
- runtime X/Y channel programming is removed from the baseline ABI; active channels are fixed/read-only;
- CAPTURE atomically replaces HOLD only when a newer LIVE frame exists;
- no ADC RELEASE command exists;
- firmware reads `FRAME_SEQ`, `VALID_MASK`, and CH raw registers from HOLD;
- `ADC_STATUS.NEW_FRAME` provides freshness under the frozen sequence comparison rule;
- CH3..CH6 raw addresses are reserved now for future six-channel activation;
- joystick hardware policy is optional convenience/acceleration logic, not the owner of ADC acquisition;
- firmware independently recomputes joystick policy and serves as a golden/reference implementation;
- board-specific cable polarity and ASCII/control mapping remain outside generic ADC semantics.

Suggested driver layering:

```text
adc.c / adc.h
  -> enable/disable + bounded acknowledgement
  -> capture latest coherent frame
  -> raw frame/status/error access

joystick_policy.c / joystick_policy.h
  -> pure C policy evaluator over raw frame + calibration

joystick.c / joystick.h
  -> optional application convenience wrapper
```

The P11 implementation may choose exact C type/function names during the implementation task, but it shall preserve these ownership boundaries and observable MMIO semantics.

## 28. Verified HEX Contract (Active Baseline)

The HEX driver is the sole owner of control state; application/ISR direct
writes to `HEX_CTRL` are prohibited. The verified contract retains Shadow
rather than routine hardware RMW, retains only `[1:0]` via `HEX_CTRL_MASK` (`0x3`),
and provides `hex_display_init()` and `hex_display_resync()` for explicit
Shadow initialization and resynchronization. Any future multi-context use
must serialize this one authoritative owner.

Decimal-point behavior shall remain unavailable unless RTL/top-level/QSF are
intentionally extended and the HEX specification is revised.

## 29. Target AES-GCM Contract

The target crypto driver shall enforce, rather than merely document:

```text
LEN <= 16
no START while BUSY
no operation-input mutation while BUSY
bounded completion wait
decrypt output accepted only when DONE && TAG_OK && !ERROR
```

The driver should return distinct status for at least:

```text
success
timeout
invalid length
hardware error
authentication failure
busy / invalid state
```

Firmware/protocol logic remains responsible for IV/sequence uniqueness unless a later hardware sequence allocator is explicitly specified.

If hardware cleanup adds key zeroization, the target driver shall expose it and use it at key-lifetime boundaries. Until then, software shall not claim secure key erasure from the accelerator.

## 30. Target Error-Handling Contract

Firmware shall distinguish at minimum:

```text
invalid software argument
peripheral busy/not-ready
timeout
peripheral-reported error
authentication failure
future bus/access fault
```

Drivers shall not translate every failure into a generic zero return value when zero is also valid data.

When frozen A2 unmapped/error responses and CPU load/store access-fault support are implemented, firmware trap handling shall follow the CPU/exception contract; this is independent of PLIC. Until implementation is verified, software shall avoid reserved addresses rather than probing them.

## 31. Build and Image Reproducibility

A firmware milestone shall identify at minimum:

```text
source commit
application name
compiler/toolchain configuration
ELF
selected IMEM image
selected DMEM image
FPGA build/SOF that contains those images
verification evidence
```

A firmware test result is not transferable to a different SOF merely because the RTL source revision is similar; the selected memory images are part of the programmed FPGA artifact.

Changes to linker memory sizes or canonical MMIO bases require corresponding specification updates before firmware is treated as compatible.

## 32. Firmware Verification Requirements

The firmware layer shall be tested at multiple levels.

### 32.1 Host/unit tests

Where practical, drivers shall be tested with mocked MMIO for:

- register addresses,
- write/read ordering,
- bit masking,
- timeout exits,
- error propagation,
- state-shadow ownership,
- SW/GPIO W1C semantics,
- AES input validation and auth-failure handling.

### 32.2 RTL/integration tests

Firmware-visible tests shall prove that the compiled access sequence matches RTL behavior for the actual peripheral implementation rather than only a software mock.

### 32.3 FPGA acceptance

Board tests shall separately validate physical effects that register readback cannot prove, including:

- UART communication with an external peer,
- all ten target LEDs,
- all ten target switches,
- selected external GPIO pins,
- HEX physical segments,
- VGA output,
- sensor/ADC plausibility,
- any interrupt path after PLIC integration.

## 33. Migration Rules

The current-to-target firmware migration shall not happen as one silent address/API substitution.

Required migration actions include:

```text
legacy GPIO SW read      -> dedicated sw driver
legacy gpio_led_write    -> dedicated led driver
legacy GPIO API          -> true external GPIO driver
PSEL[8]/[9] constants    -> added with matching RTL integration
unbounded wait APIs      -> bounded/status-returning APIs
vram_write_byte          -> remove/deprecate under frozen A3
ADC fixed-scan assumptions -> coherent configured acquisition
G-sensor raw unsafe reads  -> coherent valid sample API
AES caller-side assumptions -> driver-enforced validation
```

Compatibility wrappers may exist temporarily during cleanup, but they shall be clearly marked transitional and removed or isolated before the cleanup milestone is closed.

## 34. Cleanup Items to Carry Forward

The consolidated `baseline_cleanup.md` shall include firmware-visible work items for at least:

```text
FW-001  Deprecate unsupported peripheral/VRAM byte-write usage
FW-002  Add bounded polling/timeout APIs
FW-003  Normalize driver ownership and direct-MMIO rules
FW-004  Fix timer restart/stale-READY sequencing in driver API
FW-005  Split legacy GPIO SW/LED firmware into gpio/sw/led drivers
FW-006  Add target SW/LED base constants with RTL migration
FW-007  Update GPIO driver for finalized true-GPIO + IRQ registers
FW-008  Add coherent G-sensor sample API after RTL CDC cleanup
FW-009  Add coherent ADC/joystick sample API after RTL cleanup
FW-010  Harden AES-GCM argument/busy/authentication/timeout handling
FW-011  Remove stale application assumptions such as legacy LEDR9 ownership
FW-012  Add host MMIO driver regressions and FPGA acceptance updates
```

Exact IDs may be normalized when the central cleanup tracker is created.

## 35. Firmware Invariants

### 35.1 Current baseline invariants

Until cleanup is implemented and verified:

1. firmware is bare-metal and polling-oriented,
2. active APB peripherals occupy slots 0..7 only,
3. APB peripheral MMIO is word-oriented,
4. legacy GPIO still owns SW input and LEDR[8:0] output roles,
5. no active CPU/PLIC interrupt service exists,
6. G-sensor uses the coherent LIVE/HOLD sample ABI; ADC retains its documented CDC/coherency limitations pending cleanup,
7. AES-GCM callers must enforce valid length, sequencing, and authentication checks,
8. current blocking waits may be unbounded,
9. only canonical addresses are supported.

### 35.2 Approved target invariants

After the corresponding cleanup milestone is implemented and verified:

1. APB uses the approved 16-slot map,
2. GPIO/SW/LED have separate ownership,
3. GPIO and SW expose local PLIC-ready IRQ state,
4. normal driver waits are bounded,
5. stateful register sets have one software owner,
6. G-sensor/ADC samples use coherent publication contracts,
7. AES driver validates operation state and authentication before releasing plaintext,
8. firmware build artifacts identify their exact memory images and FPGA image,
9. PLIC-specific source IDs and CPU interrupt behavior remain governed by a separate future PLIC contract.

## 36. Sources of Truth

Current firmware behavior referenced by this document includes:

```text
firmware/bsp/start.S
firmware/bsp/linker.ld
firmware/include/soc_memory_map.h
firmware/include/soc_mmio.h
firmware/drivers/uart.c
firmware/drivers/timer.c
firmware/drivers/gpio.c
firmware/drivers/gsensor.c
firmware/include/gsensor.h
firmware/drivers/vram.c
firmware/drivers/aes_gcm.c
firmware/drivers/joystick.c
firmware/drivers/hex_display.c
```

Hardware behavior remains authoritative in the corresponding canonical specifications. If current firmware code conflicts with a hardware specification, the conflict is a cleanup defect rather than permission for firmware to redefine the hardware contract.

## Phase 4A-2 Approved Firmware Cleanup Contract (partly active; see P04 closure note)

Under A1, expose 16 generic GPIO bits (`GPIO_IO[0:15]` to JP1 `GPIO_[0:15]`) through DATA_IN/OUT, DIR and local IRQ registers; existing UART/LoRa pins are separate and `gpio_irq` is not yet CPU-routed. P04 implements this driver/map structure and removes the stale GPIO-LED assumptions, but physical GPIO/LED board tests for `FW-005/FW-007` remain. Under A2, invalid AHB/APB, DMEM, VGA and peripheral accesses fault rather than read zero/OKAY; load/store faults have causes 5/7, with misalignment causes 4/6 remaining distinct. Drivers must use canonical aligned offsets/sizes and handle errors, not rely on mirrors. Under A3, framebuffer API is `vram_write_word()` for aligned 32-bit writes only; remove/deprecate `vram_write_byte()` and provide no framebuffer readback API. Under A4, use bounded `TX_READY` polling; busy DATA writes are backpressured, not dropped. `UART_BAUD` is a 50 MHz PCLK divisor, default 434, not an enumeration; presets include 9600/19200/38400/57600/115200/230400, and additional safe rates may be calculated. Zero/unsafe divisors cannot become active; `MIN_SAFE_BAUD_DIV` remains an unresolved implementation constraint. Under A5, `timer_start(N)` writes COMPARE=N then START to create a fresh exact-N-edge one-shot (N=0 completes at START); W1C does not restart. Under A6, software-visible G-sensor register behavior is unchanged by the private PCLK-only SPI clock implementation. Unmentioned contracts remain targets until their owning evidence closes them.

## Phase 4A-P05A Approved Firmware-Facing AUX Contract

Firmware reads the synchronized E220-900T22D AUX level through UART0 status. `HIGH` permits the next LoRa UART-side write/transmission and `LOW` does not. AUX readiness is a persistent level condition, not a rising-edge event; firmware shall not add a project-level post-rising delay or valid-window interpretation. The existing per-byte HIGH check is directionally consistent with this contract. Bounded polling/timeout, error handling, and module-mode management remain separate cleanup concerns; this policy addendum does not modify firmware or close them.

## 37. Phase 4A-P06B Current Timer Firmware Contract

The current driver exposes command-oriented `timer_start(compare)`, `timer_stop()`, and `timer_reload()` operations plus COUNT/STATUS/READY helpers. `timer_start(compare)` writes COMPARE first and then issues START; repeated calls always request a fresh hardware interval. STOP writes the baseline STOP command and RELOAD explicitly clears COUNT/RUNNING/READY while preserving the programmed compare value.

`final_main.c` uses `UINT32_MAX` as its long one-shot interval. At terminal it acknowledges READY and explicitly issues a fresh START; it no longer relies on W1C automatic resume. Its elapsed checks retain unsigned subtraction across the visible maximum-to-zero re-arm boundary.

`benchmark_main.c` uses the Timer driver rather than direct Timer MMIO. Measurement setup performs RELOAD then START, and measurement completion reads COUNT then issues STOP. The legacy COMPARE=0/W1C automatic-rearm reset trick is removed.

`timer_wait_ready()` remains unbounded. P06B does not close or change `FW-002`, and no Timer IRQ/PLIC behavior is introduced. Host mock-MMIO ordering tests and actual RV32I builds of `final_main` and `benchmark_main` pass; User/Chat approved this evidence and `FW-004` is VERIFIED.

## 38. Phase 4A-P07B Current UART Firmware Contract

UART baud programming is validated: 217..65535 performs the MMIO write and
returns success; 0..216 performs no write and returns invalid argument. UART TX
offers caller-budgeted finite put-character, buffer, string, and hexadecimal
operations. A zero polling budget performs zero status reads and cannot write
DATA. Timeout returns without issuing the pending DATA write.

LoRa transmit preserves the per-byte `AUX HIGH -> TX_READY -> DATA` order and
uses separate finite AUX and UART-TX budgets. Its result distinguishes success,
AUX timeout, UART TX timeout, and invalid argument. The normal compatibility
entry points use documented finite default budgets rather than infinite waits.
Nonblocking receive behavior is unchanged. Firmware can query the combined
sticky RX error and acknowledge it through `UART_STATUS[2]` W1C.

`final_main` aborts the current LoRa message on send failure, records a UART
timeout error, and uses bounded status-returning PC debug helpers. The benchmark
also uses bounded output and records output failure for its board indication.
Diagnostic-only LoRa/UART applications call finite-default APIs, so they no
longer contain an infinite driver wait even when they do not implement a larger
recovery policy.

Host mock-MMIO evidence verifies success/eventual-success/timeout/invalid paths,
zero-budget behavior, W1C, and LoRa ordering. Affected RV32I applications build.
This is UART-subscope evidence for `FW-002`; global `FW-002` remains OPEN because
other peripheral waits remain outside P07B. No UART IRQ/PLIC behavior is added.

## P08B Trap-Policy Boundary

The uncommitted P08B candidate may rely on firmware fail-stop handling only
after startup's `mtvec` write commits. Every rebuilt image must validate the
startup opcode order and its own trap symbols. Application and VGA MMIO shall
occur after installation. Before that commit, reset `mtvec=0x00006d60` lies
outside canonical IMEM; this is
`RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT`, not verified behavior.
Rejected VGA stores are terminal faults: firmware shall not retry, skip,
increment `mepc`, blindly `mret`, or present the fault as a recoverable driver
result.

## 39. Phase 4A-P09B G-Sensor Firmware Integration Note

The coherent G-sensor firmware API `gsensor_read_sample()` is fully integrated into the public firmware tree. Directed host mock-MMIO tests and RV32I application builds verify the polling lifecycle, ordered register reads, CAPTURE/RELEASE sequencing, and error result branches. `FW-008` remains `IN_PROGRESS` for residual exhaustive reset-negative coverage and multi-context caller misuse cases.

### Historical Pre-P09 Firmware Contract

Prior to P09B, the firmware had no coherent driver or snapshot mechanism. Software read raw telemetry directly from two APB registers (`GSENSOR_XY_DATA` and `GSENSOR_Z_DATA`), which lacked `VALID` or `SEQ` indicators and risked torn reads across separate bus transactions. This raw interface is retained only as historical background and is superseded by the active driver contract in §12.
