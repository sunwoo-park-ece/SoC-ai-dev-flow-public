# Baseline SoC ADC Joystick Subsystem Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `adc_joystick.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. Purpose

This document defines the active MAX10 ADC / joystick subsystem in the FPGA baseline.

It specifies:

- the boundary between Intel/Qsys ADC IP and project-local joystick logic,
- the actual top-level ADC command path,
- the APB-visible register contract,
- ADC channel and 12-bit sample semantics,
- joystick center/dead-zone/direction processing,
- reset, clock, and clock-domain-crossing behavior,
- firmware usage constraints,
- verification requirements,
- baseline cleanup items required before major feature integration.

The baseline implementation contains an important architectural split: the ADC command generator inside `APB_ADC_Joystick_Controller` is **not connected to the active ADC command interface**. The real ADC command stream is generated independently at SoC top level. This distinction is part of the current-behavior contract and shall not be hidden by the software-facing register names.

## 2. Active Architecture

Canonical base address:

```text
JOYSTICK_BASE = 0x4005_0000
APB slot      = PSEL[5]
```

Active project-local RTL:

```text
rtl/peripherals/APB_ADC_Joystick_Controller.v
rtl/soc/AMBA_SoC_TOP.v
```

Vendor/Qsys implementation:

```text
private vendor-project vault: adc_qsys generated IP (not in public tree)
```

The active datapath is:

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
                       |  no explicit project-RTL CDC
                       v
PCLK = 50 MHz --> APB_ADC_Joystick_Controller --> CPU/APB
                       |
                       +-- X/Y raw registers
                       +-- center/dead-zone compare
                       +-- direction status
```

The APB controller also contains command-generation outputs, but the top level connects them only to `*_unused` wires. They do not drive `adc_qsys`.

## 3. Clock and Reset Domains

### 3.1 PCLK domain

`APB_ADC_Joystick_Controller` runs on:

```text
PCLK = 50 MHz
```

with active-low `PRESETn`.

It owns the software-visible registers, X/Y sample storage, validity flags, direction combinational logic, and sample counter.

### 3.2 Qsys ADC domain

The generated Qsys PLL is configured from the 50 MHz board clock with:

```text
c0 = 50 MHz / 2 = 25 MHz
c1 = 50 MHz / 5 = 10 MHz
```

The active top names `c0`:

```text
adc_sys_clk
```

The top-level channel sequencer runs on `adc_sys_clk`.

The modular ADC command/response interface is associated with this Qsys clock domain. The generated Qsys design internally provides the PLL `locked` indication to the MAX10 modular ADC control block and includes generated reset controllers with synchronized deassertion.

Software shall not infer a stable sample rate solely from these clock values. ADC conversion latency and command-ready behavior remain properties of the vendor ADC subsystem.

## 4. Actual ADC Command Path

The real active top-level command generation is:

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

Therefore, after reset release:

```text
command_valid = 1 continuously
command SOP   = 1
command EOP   = 1
channel       = 1,2,1,2,... as command_ready accepts requests
```

The baseline ADC scan set is physically fixed by this top-level RTL to channels 1 and 2.

### 4.1 Consequence for software-visible channel registers

`APB_ADC_Joystick_Controller` has its own:

```text
X_CHANNEL
Y_CHANNEL
CTRL.ENABLE
scan_axis
adc_command_valid/channel outputs
```

but those command outputs are not connected to Qsys.

Thus, in the active FPGA baseline:

- `CTRL.ENABLE` does **not** start or stop the real ADC conversion stream.
- writing `X_CHANNEL` or `Y_CHANNEL` does **not** change which analog channels Qsys scans.
- `X_CHANNEL` and `Y_CHANNEL` only control how returned response channel numbers are classified into the APB controller's X and Y sample registers.
- changing them away from the top-level fixed channels 1 and 2 can cause real channel-1/2 responses to be reported as unexpected instead of changing the ADC source.

The current firmware uses X=1 and Y=2, which matches the hard-wired top-level command sequencer.

## 5. Vendor ADC Configuration

The generated MAX10 modular ADC block exposes:

```text
command channel width  = 5 bits
response channel width = 5 bits
response data width    = 12 bits
```

The generated modular ADC configuration includes an analog-input mask of `63`, while the active SoC command sequencer uses only channels 1 and 2.

The current subsystem does not expose general ADC channel selection, acquisition timing, reference selection, or conversion-control registers through the SoC APB interface.

## 6. APB Interface

The joystick peripheral permanently asserts:

```text
PREADY = 1
```

and has no interrupt output.

APB accesses are accepted on the standard active access phase:

```text
PSEL && PENABLE && PWRITE
PSEL && PENABLE && !PWRITE
```

Register decoding uses:

```text
PADDR[7:2]
```

so the implemented register set occupies the first 256 bytes of the selected APB slot. The wider APB slot remains aliased by the upstream bridge decode and is not a canonical software contract.

## 7. Register Map

| Offset | Register | Access | Reset | Description |
|---:|---|---|---:|---|
| `0x00` | `NAME0` | R | `"apb-"` | identification |
| `0x04` | `NAME1` | R | `"joy "` | identification |
| `0x08` | `VERSION` | R | `"0.01"` | wrapper version |
| `0x0C` | `CTRL` | R/W | `0` | local controller enable / clear commands |
| `0x10` | `STATUS` | R | dynamic | local status plus live ADC handshake fields |
| `0x14` | `X_CHANNEL` | R/W | `1` | response classification channel for X |
| `0x18` | `Y_CHANNEL` | R/W | `2` | response classification channel for Y |
| `0x1C` | `X_RAW` | R | `0` / invalid | X sample and valid flag |
| `0x20` | `Y_RAW` | R | `0` / invalid | Y sample and valid flag |
| `0x24` | `CENTER_X` | R/W | `2048` | X center threshold |
| `0x28` | `CENTER_Y` | R/W | `2048` | Y center threshold |
| `0x2C` | `DEADZONE` | R/W | `300` | common dead-zone magnitude |
| `0x30` | `DIR_STATUS` | R | dynamic | decoded direction and X/Y validity |
| `0x34` | `SAMPLE_COUNT` | R | `0` | count of all observed ADC response-valid events |
| `0x38` | `RESP_INFO` | R | dynamic | debug/live response information |

Writes to unspecified/read-only offsets have no functional effect and do not generate an APB error.

## 8. CTRL Register

Current defined write bits are:

```text
bit 0 ENABLE
bit 1 CLEAR_FLAGS
bit 2 CLEAR_COUNT
```

### 8.1 ENABLE

`ENABLE` is stored in `enable_reg` and controls only the APB controller's **unused local command generator**.

It does not gate:

- the real top-level Qsys command stream,
- Qsys conversions,
- response capture into X/Y registers.

Therefore software shall not treat `CTRL.ENABLE=0` as an ADC power-down or sampling-disable operation in the active baseline.

### 8.2 CLEAR_FLAGS

Writing bit 1 as `1` clears:

```text
X valid
Y valid
unexpected-channel flag
```

It does not stop incoming responses. A new response may set the flags again immediately afterward.

### 8.3 CLEAR_COUNT

Writing bit 2 as `1` clears `SAMPLE_COUNT` to zero.

The firmware helper `joystick_clear_flags()` writes:

```text
ENABLE | CLEAR_FLAGS | CLEAR_COUNT
```

and therefore also forces the local `ENABLE` storage bit to one.

## 9. Response Capture

Whenever the APB controller observes `adc_response_valid` high on a PCLK edge, it:

```text
last_response_channel <- response channel
sample_sop            <- response SOP
sample_eop            <- response EOP
SAMPLE_COUNT           <- SAMPLE_COUNT + 1
```

and classifies the response:

```text
if response_channel == X_CHANNEL:
    X_RAW   <- response_data
    X_VALID <- 1
else if response_channel == Y_CHANNEL:
    Y_RAW   <- response_data
    Y_VALID <- 1
else:
    UNEXPECTED_CHANNEL <- 1
```

`SAMPLE_COUNT` counts response beats, not completed X/Y pairs. Unexpected-channel responses also increment the count.

There is no sample timestamp or pair sequence number.

## 10. Raw Sample Registers

`X_RAW` and `Y_RAW` contain:

```text
bit 12    VALID
bits 11:0 12-bit ADC sample
```

The 12-bit data range is:

```text
0 .. 4095
```

The baseline does not convert the raw values to voltage or a normalized signed joystick coordinate in hardware.

X and Y are updated on separate response events. They are not committed as an atomic pair.

## 11. Joystick Center and Dead-Zone Processing

The default calibration is:

```text
CENTER_X = 2048
CENTER_Y = 2048
DEADZONE = 300
```

The active comparisons are equivalent to:

```text
RIGHT    = X_VALID && X_RAW > CENTER_X + DEADZONE
LEFT     = X_VALID && X_RAW < CENTER_X - DEADZONE
FORWARD  = Y_VALID && Y_RAW > CENTER_Y + DEADZONE
BACKWARD = Y_VALID && Y_RAW < CENTER_Y - DEADZONE
```

The RTL implements the low-side comparison as `raw + deadzone < center` using 13-bit extended arithmetic, avoiding unsigned subtraction underflow.

There is no hysteresis, filtering, averaging, calibration procedure, or rate limiting.

If the raw value lies inside the dead zone, neither direction on that axis is asserted.

## 12. DIR_STATUS Register

`DIR_STATUS` fields are:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `FORWARD` | Y above center + deadzone |
| 1 | `BACKWARD` | Y below center - deadzone |
| 2 | `LEFT` | X below center - deadzone |
| 3 | `RIGHT` | X above center + deadzone |
| 4 | `X_VALID` | at least one matching X response captured since reset/clear |
| 5 | `Y_VALID` | at least one matching Y response captured since reset/clear |
| 31:6 | reserved | zero |

The direction outputs are combinational functions of the most recently stored independent X/Y samples.

### 12.1 Firmware direction mapping quirk

The current firmware maps:

```text
FORWARD  -> 'w'
BACKWARD -> 's'
LEFT     -> 'd'
RIGHT    -> 'a'
```

Thus the symbolic `LEFT/RIGHT` register names and conventional WASD character meanings are reversed for the X axis. This may reflect physical joystick orientation, but the repository does not establish that intent as an architectural invariant.

Future cleanup shall verify physical axis polarity and then align naming, board orientation, and firmware command semantics.

## 13. STATUS Register

The implemented `STATUS` read contains these useful low-order fields:

| Bits | Field |
|---:|---|
| 0 | local `ENABLE` storage bit |
| 1 | local `scan_axis` bit |
| 2 | `X_VALID` |
| 3 | `Y_VALID` |
| 4 | unexpected-channel flag |
| 5 | live `adc_command_ready` |
| 6 | local `command_fire` |
| 7 | live `adc_response_valid` |
| 12:8 | last captured response channel |
| 17:13 | configured X classification channel |
| 22:18 | configured Y classification channel |
| 31:23 | zero/reserved |

`scan_axis` and `command_fire` describe the APB controller's unused local command generator, not the real top-level Qsys command sequencer. They shall not be used as authoritative indicators of which channel the ADC is actually converting.

The live `adc_command_ready` and `adc_response_valid` fields are also subject to the CDC limitation described below.

## 14. RESP_INFO Register

`RESP_INFO` combines captured and live Qsys response information:

```text
bits 11:0   live adc_response_data
bits 16:12  live adc_response_channel
bit  17     live response SOP
bit  18     live response EOP
bit  19     last sampled SOP
bit  20     last sampled EOP
bits 31:21  zero
```

The live fields are meaningful only around a response-valid event and are not a coherent software snapshot.

The baseline firmware does not expose a public helper for this register.

## 15. Clock-Domain Crossing Limitation

The Qsys command/response interface operates in the generated ADC system clock domain, while `APB_ADC_Joystick_Controller` operates in the 50 MHz PCLK domain.

The active top directly connects:

```text
adc_command_ready
adc_response_valid
adc_response_channel[4:0]
adc_response_data[11:0]
adc_response_startofpacket
adc_response_endofpacket
```

into the PCLK-domain APB controller without an explicit project-RTL synchronizer, handshake bridge, or asynchronous FIFO.

Consequences include:

- `adc_response_valid` can be missed or sampled unpredictably,
- the multi-bit response channel/data bus is not guaranteed to be captured atomically in PCLK,
- `adc_command_ready` is sampled asynchronously by the unused local command logic,
- `RESP_INFO` exposes live asynchronous signals directly through APB combinational read logic.

The current baseline shall therefore be treated as having an **unresolved ADC-to-PCLK CDC defect**, consistent with `reset_clock.md`.

A future implementation shall establish a coherent CDC boundary, preferably by capturing completed ADC responses in the ADC domain and transferring a stable response record into PCLK through a handshake/toggle bridge or small asynchronous FIFO.

## 16. Sample Coherency Limitation

Even after CDC is corrected, the current software-visible model stores X and Y independently.

The firmware helper performs separate reads:

```text
DIR_STATUS
X_RAW
Y_RAW
```

while ADC responses may continue updating the registers.

Therefore one `joystick_read()` call can theoretically observe:

```text
DIR_STATUS based on sample set A
X_RAW based on later sample B
Y_RAW based on later sample C
```

No atomic X/Y snapshot mechanism exists.

A future cleanup should provide either:

- an atomic X/Y pair snapshot with sequence number,
- double-buffered sample publication,
- or a software-visible capture/commit protocol.

## 17. Reset Behavior

On `PRESETn` assertion, the APB controller resets to:

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

Separately, Qsys receives `HRESETn` and internally controls its generated PLL/reset domains.

After system reset release the top-level real ADC command stream begins automatically because `adc_command_valid = HRESETn`, regardless of the APB controller's reset `ENABLE=0` state.

This means the two halves of the subsystem have different apparent enable semantics immediately after reset.

## 18. Interrupt Behavior

The active ADC joystick block has no interrupt output and no active PLIC connection.

CPU use is polling based.

A future interrupt design shall define before implementation:

- sample-ready event semantics,
- X/Y pair-ready versus individual ADC-response interrupts,
- overflow/lost-sample behavior,
- unexpected-channel/error signaling,
- interrupt enable/status/clear registers,
- PLIC source allocation.

## 19. Firmware Contract

The current firmware initializes the block as:

```text
X channel = 1
Y channel = 2
center X  = 2048
center Y  = 2048
deadzone  = 300
```

This matches the actual top-level fixed Qsys scan channels.

Baseline firmware shall:

- use 32-bit aligned MMIO accesses,
- keep X/Y classification channels at 1/2 unless the top-level ADC command path is changed first,
- require both X_VALID and Y_VALID before converting direction status to a command,
- not assume `CTRL.ENABLE` stops ADC conversions,
- not assume one `SAMPLE_COUNT` increment equals one complete joystick sample,
- not rely on `STATUS.scan_axis`, `command_fire`, or live `RESP_INFO` fields as a trustworthy representation of the active command path.

## 20. Verification Requirements

A baseline-directed regression shall verify at minimum:

1. reset register values,
2. APB reads/writes for center/deadzone/channel classification fields,
3. response-channel classification into X/Y/unexpected paths,
4. X/Y valid flag set/clear behavior,
5. sample count increment/clear behavior,
6. exact dead-zone boundary behavior,
7. DIR_STATUS bit ordering,
8. top-level channel sequence 1->2->1->2 on accepted commands,
9. confirmation that APB controller command outputs are not connected to Qsys,
10. physical joystick axis polarity on board,
11. CDC-safe behavior after cleanup using assertions or dedicated asynchronous-clock tests,
12. atomic X/Y publication behavior after coherency cleanup.

Existing successful Quartus compilation or general board demonstration is not sufficient evidence that the current unsynchronized response crossing is CDC-safe.

## 21. Baseline Cleanup Targets Before Major Feature Integration

The following items shall be entered into the consolidated baseline cleanup tracker.

### High priority

1. **Unify ADC command ownership.** Remove the duplicate/disconnected command generator architecture. Either the APB controller owns Qsys command generation or a dedicated ADC acquisition engine owns it with an explicit APB status/control interface.
2. **Fix ADC/Qsys -> PCLK CDC.** Transfer response valid/channel/data/SOP/EOP coherently.
3. **Fix command-ready CDC** if command generation remains outside the ADC clock domain.
4. **Provide atomic X/Y sample publication** with validity and sequence information.
5. **Make ENABLE semantics real and deterministic.** It shall either control acquisition or be removed/renamed.
6. **Resolve channel-programming semantics.** Software channel registers shall control actual conversion channels or become read-only fixed configuration.
7. **Verify physical X/Y polarity** and resolve the current LEFT/RIGHT versus `a`/`d` firmware mapping.

### Medium priority

8. Separate ADC acquisition from joystick policy so the MAX10 ADC can be reused independently of center/dead-zone/WASD logic.
9. Add explicit sample-ready/overflow/error status.
10. Decide whether calibration remains software programmable or gains a defined calibration procedure.
11. Replace live asynchronous fields in `STATUS`/`RESP_INFO` with captured synchronous debug/status values.
12. Define interrupt policy before PLIC integration.
13. Tighten register decode/alias behavior with the APB cleanup policy.
14. Add generated-clock/CDC timing constraints consistent with `reset_clock.md`.

## 22. Recommended Future Architecture

A cleaner future decomposition is:

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
      +-- raw channel samples
      +-- valid/sequence/error
      +-- channel configuration
      |
      +--> optional joystick policy block / firmware
```

This separates:

```text
ADC hardware acquisition
```

from:

```text
joystick interpretation policy
```

and avoids making a board-specific joystick decoder the architectural owner of the reusable ADC interface.

## 23. Baseline Invariants

Until cleanup changes the specification first, the active baseline shall be understood as:

```text
APB base                     = 0x4005_0000
APB slot                     = 5
ADC response width           = 12 bits
real Qsys scan channels      = fixed 1 and 2
real command valid           = continuously high after reset
APB X/Y channel registers    = response classifiers only
APB ENABLE                   = does not control real ADC scan
X/Y sample storage           = independent, non-atomic
ADC/Qsys -> PCLK CDC         = unresolved / unsynchronized in project RTL
interrupt output             = none
software model               = polling
```

## 24. Related Specifications

- `soc_architecture.md`
- `memory_map.md`
- `apb_subsystem.md`
- `reset_clock.md`
- `interrupt_architecture.md`
- `firmware_contract.md` (planned)

## Phase 4A-2 Approved External-I/O Closure Target (not active signoff)

STA-002 requires the ADC-facing top ports to be classified by actual analog/digital role. Analog ADC pins do not receive fabricated digital `set_input_delay`; generated ADC clock/reset relationships remain STA-001. Review ADC pin voltage/standard and package placement against the VGA adjacency critical warning, measure/quantify ADC behavior during relevant VGA activity, and explicitly disposition any residual warning risk. Positive internal timing slack is not ADC/board acceptance evidence.
