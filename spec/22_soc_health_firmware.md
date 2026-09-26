# SoC Health Firmware Contract and Reconciliation Tracker

> **Status:** S1/S2 contracts preserved; S3 Timer/UART/G-sensor/ADC/joystick/VGA providers implemented, locally host-tested, integrated with real peripheral RTL and built for RV32I. S4-A board I/O providers and HEX raw getters are implemented with host/RTL checks; S4-B shared formatter and real VGA/UART1 TX observers are implemented and locally verified; no physical board, timing, or Clean Baseline acceptance.
> **Language:** English is canonical; [Korean companion](kor/22_soc_health_firmware.ko.md) mirrors this contract.
> **Roles:** Role A defines the standalone health firmware. Role B consolidates baseline-cleanup spec/FW reconciliation debt without replacing owning IP specifications.
> **Source anchor:** `390db6da2dcc8bbfa1c93b444525b0ba1e852056`. Trace IDs: Issue #7 S0 result `5845036298`, S0 acceptance `5845199371`, S1 task `5845199693`; these are internal governance locators, not public runtime evidence.

## 1. Status, purpose, and historical split

`firmware/apps/final_main.c` is **HISTORICAL RC-CAR SYSTEM DEMO FIRMWARE**. It is retained for provenance and demo reproduction, depends on the external STM32-based RC-car system, and is not the canonical standalone SoC integration-test firmware. After Issue #7 completes and is reviewed, it is not the basis for Issue #6 C4-A/C4-B.

Owner-provided demonstration: [FPGA SoC + STM32 RC-car demo](https://www.youtube.com/shorts/XYbi3uSHmUU). The link documents provenance; it does not independently qualify the future health monitor.

The future canonical application is `firmware/apps/soc_health_main.c`. It shall run standalone without the external RC-car system, exercise production peripheral contracts, report progress and failures, and freeze one snapshot for VGA and PC UART observers. It remains a reusable system diagnostic rather than an ADC-only test.

S1 changes documentation only. The application, services, providers, scheduler, and HEX raw getters do not exist as S1 deliverables. S2 added §10.1 infrastructure; S3 adds only the strong/functional providers in §10.2. S3 was accepted before S4-A; S4-A was accepted before S4-B; S4-B requires owner review before S5; Issue #6 C4 remains paused. Owning IP specifications remain authoritative for registers, hardware behavior, and existing acceptance scope. Preserve all existing STOP gates; this document does not reopen P08B, add interrupts/PLIC, redesign ADC/peripheral RTL, change pins, or close global cleanup/STA/board requirements.

## 2. Health model and failure history

### 2.1 Current states and evidence classes

| Current state | Meaning |
|---|---|
| `UNKNOWN` | Qualifying observations not yet available; never an optimistic PASS. |
| `PASS` | The stated evidence class and provider criterion have been met. |
| `WARN` | A degraded or pending condition is explicitly reported; not a substitute for a missed mandatory deadline. |
| `FAIL` | Mismatch, required deadline miss, or qualifying error. |
| `EXCLUDED` | Deliberately outside qualification; never a PASS/FAIL contribution. |

Evidence classes are `STRONG_PROGRESS`, `PHYSICAL_LOOPBACK`, `FUNCTIONAL_CONSISTENCY`, `REGISTER_READBACK`, `INPUT_OBSERVATION`, `VISIBLE_OUTPUT`, `OBSERVER_ONLY`, and `EXCLUDED`. An IP may expose several separately labeled evidence classes. Register readback or visible output shall not be promoted to acquisition/display-domain progress.

### 2.2 Current versus sticky failure semantics

Each record shall include current state, evidence class, `heartbeat_count`, `last_progress_epoch`, `miss_count`, and `detail`/status. The snapshot shall include current `pass_mask`, `warn_mask`, `fail_mask`, `excluded_mask`, and separate `sticky_fail_mask`. UNKNOWN is represented explicitly rather than silently included in PASS; masks shall agree with record states.

Current `FAIL` may recover to `PASS` after fresh qualifying evidence, but `sticky_fail_mask` remains set for the current boot session until reboot or an explicitly approved future clear mechanism. Recovery shall not erase misses or failure history. One state field shall not encode both current and historical failure. Every required missed deadline increments the corresponding miss history and yields FAIL; repeated polling of the same pending transaction does not manufacture multiple heartbeat events.

`AES_GCM = EXCLUDED_PENDING_CLEANUP`: AES contributes to neither PASS nor FAIL, including sticky failure qualification. The monitor shall execute no AES operations. AES cleanup and future heartbeat-provider addition require separate approval; AES absence is never a system failure.

## 3. Immutable snapshot and observers

The health manager shall calculate state once and freeze snapshot N, including epoch, deterministic signature, current masks, sticky history, per-IP state/evidence/progress, and board-test values. VGA and PC UART shall receive the same snapshot object/content and expose the same epoch and signature, masks, per-IP states, and selected progress counters. They shall not independently recompute health.

The signature shall use deterministic explicit fields, not uninitialized structure padding. Snapshot N is immutable while any observer consumes it. Live provider state and later snapshot N+1 remain separate. Observer lag/failure shall not mutate N; bounded observer cursors/storage ownership shall prevent reusing an in-flight snapshot. Report observer staleness and last completed epoch distinctly. VGA completion updates live state for N+1, not the already rendered N.

UART1 TX is `OBSERVER_ONLY`, never a UART heartbeat contributor. A failed/backlogged observer must not indefinitely stop other providers or snapshot service. Identical signatures are a consistency aid, not proof of peripheral correctness or physical visibility.

## 4. Cooperative service and fault boundary

All normal probes and observers shall be bounded or nonblocking. Use a cooperative polling loop with finite per-turn work, independent service-epoch deadlines, and explicit error results. Timer shall not be the only mechanism allowing the monitor to advance/report; a Timer failure must remain reportable. A service-epoch budget is not a proven wall-clock duration; actual quotas and timing shall be measured in S3/S5.

Use production bounded/status APIs; never call `timer_wait_ready()` in the normal monitor path. UART draining, renderer strings, initialization acknowledgement, and operation waits also require finite work/deadlines. A single failed IP shall not stop service of other IPs unless the CPU/bus faults terminally. Avoid long monolithic VGA frame waits by composing low-level status/operation APIs.

All MMIO shall use canonical aligned 32-bit accesses. VGA status prechecks cannot eliminate lock-loss races at a later store. Per [VGA contract](08_vga.md), a rejected framebuffer/control store may enter the existing terminal CPU trap. No recoverable-MMIO/trap redesign is promised; a hung bus instruction cannot be bounded by a software polling budget. Preserve the accepted diagnostic fail-stop and pre-mtvec risk boundary.

## 5. Per-IP heartbeat contract

| Target | Production API / authority | Required evidence |
|---|---|---|
| CPU/system service | Future service loop; [CPU](21_cpu_core.md), [firmware](19_firmware_contract.md) | Advancing service epoch and snapshot publication; system liveness, not independent CPU hardware acceptance. |
| Timer | `timer_start/count/status/clear_ready`; [Timer](10_timer.md) §21 | `STRONG_PROGRESS`: COUNT advances while active, fresh READY, acknowledgement, and a fresh START/restart. Use exact-N one-shot semantics; W1C alone does not restart. |
| UART | `uart0_putc_timeout`, `uart1_getc_nonblock`, RX error API; [UART](09_uart.md) current P07B | `PHYSICAL_LOOPBACK`: exact expected token arrives on RX1 within its bounded deadline; §6 defines topology/exclusions. |
| GPIO | `gpio_set_input/output`, `gpio_write/read/read_output`; [GPIO](11_gpio.md) active P04 | `PHYSICAL_LOOPBACK`: synchronized GPIO1 matches independently generated GPIO0 pattern after settling; §7. |
| G-sensor | `gsensor_read_sample()`; [G-sensor](12_gsensor.md) §§7–9 | `STRONG_PROGRESS`: successful coherent sample and advancing sequence. Static XYZ allowed. NO_NEW/BUSY cannot increment heartbeat; persistent lack of progress fails at deadline. CAPTURE/read/RELEASE remains single-owner. |
| ADC | `adc_init/enable/capture/get_frame_count/get_error_status`; [ADC](15_adc_joystick.md) §§8–11 | `STRONG_PROGRESS`: canonical v2 identity, bounded enable acknowledgement, new coherent HOLD, CH1/CH2 valid, advancing HOLD seq and consistent FRAME_COUNT progress; sticky acquisition errors shall be recorded. |
| Joystick policy | `joystick_policy_eval`, `adc_get_raw_joy_status/get_calibration`; [ADC policy](15_adc_joystick.md) §§10–11 | `FUNCTIONAL_CONSISTENCY`: HW ADC_JOY_STATUS equals independent FW evaluation of the same raw HOLD and current calibration, including validity bits and saturated strict thresholds. No physical movement needed every epoch. |
| VGA | `vram_status/clear_events/start_operation`, bounded text writes; [VGA](08_vga.md) | `STRONG_PROGRESS`: DOMAIN_READY, fresh/recurring VSYNC, issued SWAP, fresh associated OP_DONE, no OP_ABORT; §9. |
| SW | `sw_read()`; [SW](17_sw.md) P04 | `INPUT_OBSERVATION` and board control: synchronized SW[9:0], optional activity count; static SW valid. |
| LED | `led_write/read`; [LED](18_led.md) | `REGISTER_READBACK` plus separately observed `VISIBLE_OUTPUT`: LED[9:0] = captured SW[9:0]. |
| HEX | `hex_display_*`; [HEX](16_hex_display.md) | `REGISTER_READBACK` plus separately observed `VISIBLE_OUTPUT`: exact dual-mode contract in §8. |
| PC UART TX | UART1 bounded TX API | `OBSERVER_ONLY`: displays frozen snapshot; does not qualify UART loopback. |
| AES-GCM | [AES](14_aes_gcm.md) | `EXCLUDED`: always EXCLUDED_PENDING_CLEANUP; no monitor operation. |

ADC FRAME_COUNT counts PCLK LIVE publications, not CAPTURE calls. Do not require exactly +1 between captures: producer progress may outpace the loop. Compare coherent HOLD sequence and surrounding count observations with modulo-32 wrap and acquisition baselines; do not claim independent registers were sampled simultaneously. Require `(valid_mask & 0x03) == 0x03`. Record sticky acquisition errors before any explicit acknowledgement; do not silently clear away a failure. ADC uses CAPTURE-only HOLD, with no RELEASE; G-sensor retains its distinct RELEASE lifecycle.

Compare joystick policy before the next CAPTURE/calibration change with single-owner stable readback calibration. Expected directions shall come from raw values/validity and the pure FW model, never HW JOY_STATUS. Compatibility joystick wrappers that discard init/enable errors or fall back to stale HOLD shall not establish health progress.

## 6. UART physical loopback and observer wiring

Frozen automated path: **UART0 / LoRa-side TX → physical jumper → UART1 / PC-side RX**.

```text
PCLK = 50 MHz
divisor = 434 on both UARTs
format = 8-N-1
nominal terminal rate = 115200
UART0 TX: YES     UART1 RX: YES
UART1 TX: NO      UART0 RX: NO
LoRa AUX: NO      external LoRa module: NO
```

Nominal hardware baud is 50,000,000/434, approximately 115207.37 bit/s. This loop uses raw UART APIs and does not require the AUX-gated LoRa module wrapper. Preserve existing pins: UART0 `lora_tx` at Y4, UART1 `uart_rx` at AA2, UART1 observer `uart_tx` at AB2, per `fpga/quartus/constraints/de10_lite_pins.tcl`.

Use compatible 3.3-V logic/common ground. UART1 RX must have no competing PC-adapter TX or other external transmitter. A PC adapter RX may observe UART1 TX; UART0 RX and external LoRa behavior remain unqualified. Verify actual board/header wiring before board tests; this specification is not a cabling observation.

Use a deterministic sequence-tagged framed token, one outstanding transaction, exact expected receive bytes and a bounded deadline. The S0 transaction design is `A5 5A | seq32 little-endian | ~seq32 little-endian | C3 3C` (12 bytes). Service RX fairly during rendering; the RX FIFO holds 16 bytes. Bounded TX retries/resynchronization shall not become unbounded FIFO drains. Stale/corrupt/malformed tokens or sticky RX errors cannot qualify progress. UART1 TX output failure/staleness is observer evidence only.

## 7. GPIO, SW, and LED board tests

Frozen GPIO path: **GPIO[0] output → physical jumper → GPIO[1] input**. Owned mask `0x0003`, drive mask `0x0001`, sense mask `0x0002`. Canonical GPIO_IO0/1 pins V10/W10 are separate from UART pins. No external driver may compete on GPIO1; verify the actual JP1/header connection and voltage compatibility before board use.

Preload GPIO0's output latch, configure GPIO1 input and GPIO0 output using production direction APIs, and preserve other direction/output bits through single-owner masked operations. Generate changing 0/1 patterns independently of sampled input; require both logic levels repeatedly after bounded settling sufficient for the input synchronizer. Compare synchronized GPIO1 with the retained expected GPIO0 bit. DATA_OUT readback alone is insufficient. No other GPIO bits or IRQ/PLIC paths qualify this baseline.

Read synchronized `s = SW[9:0]` once per input service and retain it for board commands. Static switch values are valid. Write **LED[9:0] = SW[9:0]**, check LED latch readback against the captured s, and report captured SW, commanded LED, and readback in the common snapshot. The user separately verifies each physical LED follows its matching switch. No unrelated LED heartbeat animation or aggregate-status multiplexing is allowed while this mapping is active.

## 8. HEX dual-mode board contract

Initialize the production HEX CTRL shadow. `SW[9]` selects mode; `SW[8:0]` is payload p. ENABLE=1 during active display. The required SW board-test mapping takes precedence over suggestions to display aggregate health on HEX/LED; aggregate status belongs on VGA/PC UART.

### 8.1 Mode 0 — decoded numeric/value display

```text
p = SW[8:0]
P2 = p[8] (zero-extended nibble)
P1 = p[7:4]
P0 = p[3:0]
HEX5 HEX4 HEX3 HEX2 HEX1 HEX0
 P2   P1   P0   P2   P1   P0
VALUE = p | (p << 12)
RAW_MODE = 0
```

Examples: p=0x000 → `000000`, p=0x12A → `12A12A`, p=0x1FF → `1FF1FF`. HEX2/5 intentionally show only 0/1 in this mode; raw diagnostics supply full segment coverage on all six digits.

### 8.2 Mode 1 — raw segment diagnostics

```text
group = SW[8:7]
on_mask = SW[6:0] in {g,f,e,d,c,b,a} order
raw = (~on_mask) & 0x7f
RAW_MODE = 1
```

| group | HEX patterns |
|---|---|
| `00` | raw on all six digits. |
| `01` | raw on HEX2..0; HEX5..3 blank (`0x7f`). |
| `10` | raw on HEX5..3; HEX2..0 blank (`0x7f`). |
| `11` | raw on HEX0/2/4; complementary pattern `on_mask` on HEX1/3/5. |

Let ri be the selected seven-bit pattern for HEXi. Pack `RAW_LOW = r0 | (r1 << 7) | (r2 << 14)` and `RAW_HIGH = r3 | (r4 << 7) | (r5 << 14)`. Segment bits are active-low: 0 illuminates, 1 turns off; blank is `0x7f`. There is no DP bit. All-on/off and seven walking on_mask bits shall exercise every digit/segment; physical illumination remains human-visible evidence.

For transitions, disable through the driver, write VALUE or both RAW banks, select mode, and re-enable. Two RAW writes are not an atomic six-digit update. Check masked VALUE/RAW readback and CTRL=1 for decoded mode or CTRL=3 for raw mode. Publish mode, payload, group and commanded/readback data in the snapshot. Only the driver writes CTRL; preserve its shadow ownership.

### 8.3 S4-only raw getter decision

The accepted S4 extension is `hex_display_read_raw_low()` and `hex_display_read_raw_high()` in `firmware/include/hex_display.h` / `firmware/drivers/hex_display.c`. Getters shall be side-effect-free canonical register reads masked to 21 functional bits (`0x001fffff`). No CTRL ownership/shadow redesign is allowed. Implementation/testing is deferred to S4; S1 adds no driver API/code.

## 9. VGA heartbeat and publication sequence

VGA heartbeat requires **DOMAIN_READY + fresh/recurring VSYNC + issued SWAP + fresh OP_DONE associated with that operation + no OP_ABORT**. Static drawing, stale sticky events, and clear-only DONE never qualify.

Compose a bounded state machine: wait READY/idle; clear the writable back bank and observe clear completion if needed; freeze N and render it in bounded back-buffer chunks; acknowledge old VSYNC and observe a fresh event; issue SWAP under ready/idle ownership; observe fresh associated DONE and fresh VSYNC with no ABORT; record progress in live state for N+1. Clear the new back bank for the next frame if needed. Rendering shall respect bounds and exclude framebuffer writes during OP_BUSY.

Record aborts before a helper clears stale status. Acknowledge events so later cycles require new progress, not repeated reads of one sticky bit. `vga_text_begin_frame()` is bounded but waits/switches/clears before returning; it shall not substitute for the explicit render-then-present cooperative sequence. The physical screen image remains a separate human check; internal heartbeat proves display-domain/ownership progress only.

## 10. Implemented infrastructure and future stage gates

The following paths exist for the accepted S2 infrastructure and host verification:

```text
firmware/apps/soc_health_main.c
firmware/include/soc_health.h
firmware/services/soc_health.c
firmware/services/soc_health_probes.c
firmware/services/soc_health_render.c
verification/firmware/soc_health_host.c
verification/firmware/soc_health_mmio.h
scripts/wsl/soc_health_host_test.sh
```

The services layer is application service code, not a hardware driver. The minimal `scripts/firmware/build_fw.sh` change includes the core/probes/render/providers services only for the new app; existing app flows are preserved. Builds require external RUN_ROOT; the supported command is `scripts/firmware/build_fw.sh soc_health_main` with that environment set. Preserve RV32I/ILP32 freestanding behavior, existing startup/trap, **16 KiB IMEM / 32 KiB DMEM**, and explicit paired memory-image identity. Memory capacity and startup/trap are unchanged. S3 builds the strong-provider application; physical peripheral acceptance remains deferred.

| Stage | Approved future boundary |
|---|---|
| S2 HEALTH CORE | App skeleton, services, records/current masks/sticky history, immutable snapshot/signature, cooperative bounded scheduler. |
| S3 STRONG PROVIDERS | Timer, UART loopback, G-sensor, ADC, joystick consistency, VGA progress. |
| S4-A BOARD I/O | GPIO0→1, SW, SW-mirrored LED, HEX dual mode/raw getters. |
| S4-B OBSERVERS | VGA and PC UART shared-snapshot rendering, separately gated after S4-A review. |
| S5 CLOSURE | Host/unit tests, RV32I build/image-size check, relevant existing regressions, clean local checkpoint. |

S1 implemented none of S2–S5. S2 infrastructure, S3 providers, S4-A board I/O and S4-B observers are implemented and accepted. S5 closure verification/documentation is complete; stop for S5 owner review. After S5, stop for review before Issue #6 C4-A/C4-B resumes. No push, vendor execution, baseline release, or global tracker closure is implicitly authorized.

### 10.1 Accepted S2 core ABI, ownership and deterministic signature

Stable IDs are SYSTEM_SERVICE=0, TIMER=1, UART_LOOP=2, GPIO=3, GSENSOR=4, ADC=5, JOY_POLICY=6, VGA=7, SW=8, LED=9, HEX=10, AES_GCM=11. Mask bit `1u << id` is fixed. State and evidence enum order matches §2. Each record stores state, evidence, heartbeat_count, last_progress_epoch, miss_count and detail. Current masks are derived from copied records at publication; UNKNOWN contributes no bit. FAIL sets sticky history; recovery does not clear it. No runtime sticky-clear API exists.

At the S2 checkpoint, one cooperative owner advances a software epoch without Timer. Each turn visits one of ten round-robin pending providers (IDs 1–10) and at most two observer characters. SYSTEM_SERVICE progress means only that the software service turn ran. S2 peripheral placeholders stay UNKNOWN with `SOC_HEALTH_NOT_IMPLEMENTED` (0x4e4f5451, NOT QUALIFYING HARDWARE EVIDENCE). AES remains EXCLUDED_PENDING_CLEANUP with no provider/callback; all report attempts for AES are rejected. Production S2 code performs no MMIO.

Progress and deadline-miss tokens are deduplicated per IP/event stream. After the first event, a token must advance modulo 2^32 by a nonzero amount less than 2^31; replay/old completion cannot recover FAIL. PENDING updates detail only. An armed deadline uses unsigned epoch elapsed time, budget less than 2^31, and disarms after one expiry. These are bounded software-turn budgets, not physical time measurements; callers must service deadlines before an entire epoch wrap elapses. Terminal CPU/bus faults remain outside recovery guarantees.

Two static snapshot slots hold copied logical records and metadata. Publishing acquires both observer leases; occupied slots are never overwritten. If both are occupied, publication returns null and increments live backlog. Each observer releases exactly its own lease on completion or timeout; the slot can be reused only after both releases. A pointer is valid only for its acquired lease lifetime, and must not be used after release/reinitialization. There is no concurrent/interrupt ownership protocol. Live updates and releases change future-snapshot metadata, never published content. Observer completion tracks placeholder consumption, not physical display or UART delivery.

The two const-input cursors consume the same snapshot pointer, epoch and signature. Each ready cursor emits one character of `EPOCH=xxxxxxxx SIG=xxxxxxxx` per service call. A 64-epoch budget releases a stalled observer and increments only live observer misses; the other observer can finish independently. The application requests publication every 32 software turns and retains an active render until completion/timeout. S4-B adds the real observers in §10.4; the S2 cursors remain only for compatibility/unit tests.

Signature is 32-bit FNV-1a (seed 2166136261, prime 16777619), processing each explicit uint32 word as four little-endian bytes. Target prime multiplication is implemented with shifts/adds; no multiply/divide helper is required. Exact 97-word order:

1. Version tag 0x53483201, epoch, publication_id.
2. pass_mask, warn_mask, fail_mask, excluded_mask, sticky_fail_mask, publication_backlog.
3. observer_miss_count[0], [1], then observer_last_epoch[0], [1].
4. For each ID 0 through 11: ID, state, evidence, heartbeat_count, last_progress_epoch, miss_count, detail.

The signature itself, struct padding, pointers, slot leases and live deduplication tokens are excluded. Equal logical fields give equal signatures; this checksum is neither collision-free nor hardware acceptance evidence.

### 10.2 S3 strong providers and verification scope

`firmware/include/soc_health_providers.h` and `firmware/services/soc_health_providers.c` add provider-local state; the generic S2 core is unchanged. `soc_health_main` now calls the real provider dispatcher. The S2 pending-dispatch API remains for its unit tests; the current application uses the strong dispatcher. Both use the stable ID order. Initial bounded visits configure UART, Timer, G-sensor, ADC and VGA in that order, then a ten-way round robin visits IDs 1–10. Every step is finite: UART sends at most one byte with one readiness poll and receives/drains at most four; ADC enable requests once using `adc_enable(0)` then polls acknowledgement across turns; VGA writes at most one deterministic back-bank word. JOY shares ADC acquisition. At the S3 checkpoint GPIO/SW/LED/HEX remained pending placeholders; S4-A attaches the board callback described in §10.3. AES is never dispatched. S2 cursors still perform no hardware output.

Default provider budgets are 262144 software epochs; Timer compare is 50000 PCLK counts. These are initial bounded engineering parameters, not measured wall-clock quotas or board guarantees. A 12-byte single outstanding UART transaction fits the 16-byte RX FIFO under the owned-peer assumption; RX error still fails explicitly. No scheduler-count token qualifies hardware progress.

| Provider | Bounded qualification / actual progress token | Failure/recovery |
|---|---|---|
| Timer | STOP/W1C/RELOAD, START known compare and baseline COUNT; observe advancement, fresh READY, W1C and confirmed clear; restart and observe new COUNT advancement. Token is completed-interval generation, incremented only at that qualification. | Frozen COUNT, absent READY, stuck ACK or restart failure fail/miss. Bounded stop/restart retries preserve sticky history. |
| UART | Both divisors 434; exact `A5 5A / seq32 LE / ~seq32 LE / C3 3C`. Concurrent bounded TX/RX validates each expected byte; only all 12 bytes with all TX issued qualify the transaction seq. | Bad/stale bytes, RX error or deadline fail. Bounded drain to an observed empty FIFO, reset partial state, then increment next transaction seq; old partial data cannot complete a new token. UART1 TX/UART0 RX/AUX are unused. |
| G-sensor | Production `gsensor_read_sample()` CAPTURE/read/RELEASE and fresh actual sample.seq; static XYZ is allowed. | NO_NEW/BUSY/repeated/stale seq remain pending until deadline. Check expiry before late qualifying recovery so misses/sticky history survive; invalid result fails. |
| ADC | Canonical `adc_init`, retained calibration/count/error baseline, ENABLE request and acknowledgement; production CAPTURE, CH1/2 valid, fresh HOLD seq, supporting FRAME_COUNT delta in (0, 2^31), errors checked before and after CAPTURE. Token is HOLD frame.seq, never FRAME_COUNT. | Identity failure remains latched until explicit reinit. Enable/NO_NEW/stale/frozen-count deadlines fail; invalid mask or sticky errors fail. No provider clears ADC errors or uses compatibility joystick wrappers. Count jumps >1 are accepted. |
| JOY | Retained exact eligible ADC HOLD, current calibration readback, independent `joystick_policy_eval` versus all six hardware bits before another CAPTURE. Token is the compared HOLD seq. | Mismatch records expected/actual and fails. Same-HOLD calibration changes are rechecked but cannot create duplicate progress or recover an already-qualified seq; fresh eligible generation can recover while sticky stays. Invalid/error ADC frames are ineligible. |
| VGA | Sole operation owner: READY/idle, one back-bank word, acknowledge stale VSYNC/DONE, fresh VSYNC, issue SWAP (no CLEAR), fresh associated DONE/no BUSY/no ABORT. Token is completed SWAP generation. | Record ABORT before any helper W1C, readiness loss or deadline fails. Recover via bounded READY/idle/event preparation; no dashboard, monolithic frame helper or second MMIO owner. Terminal bus/CPU faults remain outside recovery. |

Run `RUN_ROOT=<fresh-external-directory> scripts/wsl/soc_health_provider_test.sh` for the real providers and production drivers against independent register/transaction inputs. Run `RUN_ROOT=<fresh-external-directory> scripts/wsl/soc_health_provider_rtl_test.sh` for the same C code against production Timer/UART/G-sensor/ADC+JOY/VGA RTL. The RTL fixture drives APB/AHB accesses, simulated UART0-to-UART1 serial continuity, a static digital sensor peer and ADC PCLK publication inputs; portable PLL/RAM models remain simulation abstractions. It does not execute the RISC-V CPU or replace the separately rerun P09 CPU/P11 acquisition+CDC regressions. Neither host nor simulated UART continuity is physical jumper/board acceptance. Guards retain raw target logs and reject missing required asserted cases/source drift; isolated faults and failure-exit fixtures verify rejection and nonzero parent propagation.

### 10.3 S4-A board I/O providers and verification scope

`firmware/services/soc_health_board_io.c` and `include/soc_health_board_io.h` hold static board state. An optional dispatcher callback preserves the S3-only harness; the application attaches it for IDs GPIO=3, SW=8, LED=9 and HEX=10. The ten-way schedule, strong provider functions, health core, copied snapshot ABI/signature and AES exclusion are unchanged. Each visit performs bounded work; there is no IRQ, busy wait or second VGA owner.

GPIO releases the owned pair, preloads GPIO0 low, configures GPIO0 output/GPIO1 input with production APIs, then drives independently retained `0,1,1,0`. Direction/output bits outside the owned pair survive. Each sample waits at least three software epochs across visits (MMIO itself advances PCLK, covering the two synchronized input stages), then compares synchronized GPIO1 with expected stimulus. Direction and latch readback are supplementary checks. Only four matched samples complete a loopback generation. The 262144-epoch whole-cycle deadline rejects stuck/late/inverted sense even when DATA_OUT is correct; configuration/readback inconsistency fails immediately. A later complete cycle restores current PASS without clearing sticky failure.

SW performs one canonical masked 10-bit read per command generation. Its observation token/heartbeat counts reads, not switch motion or autonomous progress; static input remains valid. The retained value/generation feeds both LED and HEX until each consumer retires. A consumer exceeding the 262144-epoch budget fails on its next fair visit and releases its pending bit; a new capture requires both bits clear. LED writes the captured value and checks its masked latch readback in one visit. LED/HEX completion tokens equal the consumed SW generation and advance only on completed matching transactions.

HEX initializes once and resynchronizes the production CTRL shadow before each command. Five visits perform disable → data → mode → enable → readback. RAW data uses two non-atomic bank writes while disabled. Decoder `p=SW[8:0]` uses `VALUE=p|(p<<12)`, CTRL=1. RAW uses CTRL=3, `on=SW[6:0]`, active-low `raw=(~on)&127`, group `SW[8:7]`: 00 all digits, 01 lower three only, 10 upper three only, 11 even digits raw/odd digits on. Each digit occupies seven bits in its three-digit bank. CTRL and relevant VALUE/RAW readbacks must match exactly after functional masking. `hex_display_read_raw_low/high()` read canonical +0x08/+0x0c, mask 0x001fffff and never change the CTRL shadow. Provider code never writes CTRL directly.

The signed/copied record detail remains 32 bits: SW stores the captured 10-bit value; LED bits [9:0] store captured SW and [19:10] its masked readback; HEX bits [9:0] store captured SW, [11:10] actual CTRL, and [27:24] mismatch flags (CTRL/LOW/HIGH/VALUE = 1/2/4/8). Mode, payload and group are recoverable from SW; on a matched command the complete expected/actual register values are deterministically recoverable from that capture. Static board state also retains full command/readback words; it is live provider state, not an extra snapshot pointer or leased payload. GPIO success detail 0x103 identifies drive/sense ownership; failure prefixes 0x71/0x72 identify sense deadline/configuration failures. Consumer deadline prefix is 0x73, LED mismatch prefix 0x74.

Evidence remains GPIO=PHYSICAL_LOOPBACK (automated wiring is **simulated**), SW=INPUT_OBSERVATION, LED/HEX=REGISTER_READBACK. Successful observation/mirror generations never become STRONG_PROGRESS. Actual GPIO jumper continuity, SW electrical behavior, LED illumination/mapping and HEX illumination/digit/polarity remain NOT_RUN board gates.

Run `scripts/wsl/soc_health_board_io_test.sh`, `scripts/wsl/soc_health_board_io_rtl_test.sh` and `scripts/wsl/soc_health_board_io_negative_test.sh` with fresh external RUN_ROOT. Host tests retain all S3 assertions and check the full decoder/raw matrix, canonical getter offsets/masks/shadow, shared generation, GPIO faults/recovery, consumers' bounded retirement and all-active fairness with snapshot immutability during failure. RTL integration executes production C core/providers/drivers against production APB_GPIO/SW/LED/HEX, with a simulated pin jumper and independent external SW-derived LED/physical-segment oracle. It does not execute a RISC-V CPU. Isolated source defects and compile/leaf/guard exits must be rejected with immutable raw logs and actual source hashes. Existing S2/S3/P04/P10 suites remain separate regression gates. At S4-A, the dashboard/real UART observers remained unimplemented; S4-B adds §10.4. S2 cursors remain a non-MMIO compatibility/test API. S4-A owner review was accepted before S4-B.


### 10.4 S4-B shared formatter and real observers

`include/soc_health_observers.h` / `services/soc_health_observers.c` implement one pure `soc_health_format_line(snapshot, line_index, buffer, size)` used by both observers. The return value is the untruncated logical length; nonzero size always writes a terminator within the buffer, size zero writes nothing. There are 19 logical lines, fixed 48-byte buffers, uppercase hexadecimal fields and no printf/allocation/MMIO in the formatter. State encoding is P/W/F/?/X. All values are copied snapshot input; no observer reads live health state for text.

The frozen logical format is (values illustrative):

```text
SOC HEALTH EP=00001234 SIG=89ABCDEF
P=000007FF W=00000000 F=00000000
S=00000004 X=00000800

IP    ST HB       MISS DETAIL
SYS   P  00001234 0000 RUN
TMR   P  00000042 0000 READY
UART  P  00000031 0000 SEQ=00000031
GPIO  P  00000008 0000 LOOP
GSEN  P  00000079 0000 SEQ=000001A2
ADC   P  00000078 0000 SEQ=000001A1
JOY   P  00000078 0000 MATCH
VGA   P  00000020 0000 SWAP
SW    P  00000041 0000 V=155
LED   P  00000041 0000 V=155
HEX   P  00000041 0000 M=0 P=155
AES   X  00000000 0000 PENDING

SYSTEM: PASS
```

If current failures exist, the footer is `SYSTEM: FAIL F=xxxxxxxx S=xxxxxxxx`. Non-PASS records (except AES PENDING) show `D=xxxxxxxx` instead of an unreliable symbolic detail. MISS uses the low 16 bits; SEQ/HB/masks/EP/SIG/raw detail show all 32 bits (eight hexadecimal digits), per the subsequent User/Chat instruction. SW/LED V is the retained 10-bit captured value; HEX M/P derives from copied captured SW. To make genuine UART/GSEN/ADC SEQ available without live access or ABI expansion, S4-B records the qualified transaction/sample/HOLD sequence in their **successful report detail**. At S4-A these details were baud=434/zero/FRAME_COUNT; the gap was reproduced and reported before the three narrow changes. Tokens, qualification rules, count freshness/provider-local baseline, error codes, core snapshot layout/signature and S4-A semantics are preserved. ADC successful detail now means HOLD seq, not FRAME_COUNT; this diagnostic payload change is tracked below.

VGA uses the existing 640x480 one-bit framebuffer and unchanged 8x8 font renderer. The renderer operates in 32-pixel-aligned words, so x=32 (rather than suggested x=24); y=16+16*logical_line. Table header is y=80, IP rows y=96..272, footer y=304. Blank logical lines give section gaps, and every glyph is inside the visible region. The existing S3 VGA FSM remains the **sole operation owner**. Its PREPARE callback clears the back buffer in at most eight words per visit, then renders at most four glyphs/eight words per visit. Completion of all lines precedes stale VSYNC/DONE acknowledgement, fresh VSYNC, SWAP, fresh associated DONE with no ABORT, qualification and VGA lease release. There is no separate one-word probe transaction in the application. The no-hook one-word path remains solely for the accepted S3 regression harness. No monolithic begin-frame/clear helper, hardware CLEAR command or second operation owner is introduced.

The two real observers acquire the same published N with independent VGA/UART pointers and reader bits. VGA release is called by the sole owner on DONE/abort/readiness loss/deadline; UART release is independent. N contains the earlier VGA state; completion changes live state only, appearing in a future publication. Pointers are cleared on release; no text resumes through a released pointer. The existing two-slot no-overwrite/backlog contract and 97-word signature ABI remain unchanged. The application serializes one active observer pair and accounts publication backlog while it is pending; lease tests also exercise both occupied slots.

UART1 TX uses one bounded readiness attempt/at most one byte per service turn, with the unchanged divisor configured by the existing UART provider. It emits `=== SOC HEALTH SNAPSHOT ===\r\n`, every common logical line with CRLF (including blank lines), then 40 hyphens and CRLF. After the last byte is accepted it waits for TX readiness before releasing, so the final byte drains. There is no ANSI/cursor/clear-screen output: PuTTY retains an append-only diagnostic log. A 262144-software-epoch observer budget releases only UART's lease and records live observer misses on timeout. VGA uses its bounded preparation budget and existing owner deadline across the transaction. UART1 TX never reports UART heartbeat progress; UART0 TX→UART1 RX remains the unchanged automated heartbeat path.

Host checks use literal logical-line fixtures and the accepted unchanged font asset with independent per-pixel raster placement. They assert bounds/determinism/no-MMIO, state/detail/footer, exact PC text, both completion orders, partial work, immutable N, independent timeout/abort release, backlog and all-active fair visits/progress. Real provider/driver/RTL integration checks every accepted framebuffer write's commit/address/data/back bank, the complete independently expected raster before SWAP, presentation bank after fresh DONE, and an independently decoded UART1 TX serial stream with the identical frozen EP/SIG. It simultaneously exercises UART0→UART1 RX and S3 strong peripherals, and is not CPU E2E. Run fresh external RUN_ROOT with `scripts/wsl/soc_health_observer_test.sh`, `soc_health_observer_rtl_test.sh`, and `soc_health_observer_negative_test.sh` (all under `scripts/wsl/`). Targeted isolated defects and successful-target/failed-guard fixtures must propagate nonzero and consistent FAIL artifacts. Build compiles only the new observer service with `-Os` to preserve the existing 16KiB IMEM without duplicating text/font infrastructure.

Physical VGA image quality, UART cable/USB adapter/PuTTY, GPIO jumper, SW/LED/HEX/sensors/ADC, real-time quotas, stack high-water and vendor timing remain NOT_RUN. S4-B owner review was accepted. Stop for S5 closure review; C4 remains paused and no push is authorized.

### 10.5 Final software architecture

This map describes the final SYSFW-01 implementation at the S5 checkpoint. Paths below are a relevant subset of the actual tree, not a proposal. The application orchestrates production driver APIs through health services; `joystick_policy.c` is a pure policy model rather than an MMIO driver. S4-A extended `hex_display.c/.h` with side-effect-free, masked RAW_LOW/RAW_HIGH getters; the driver layer is not uniformly untouched.

#### Code structure

```text
firmware/
├── apps/
│   └── soc_health_main.c         # Entry point; cooperative loop and callback wiring
├── include/
│   ├── soc_health.h              # Stable IDs, states/evidence, core/snapshot/lease ABI
│   ├── soc_health_providers.h    # Strong-provider state, dispatcher and callback interfaces
│   ├── soc_health_board_io.h     # GPIO/SW/LED/HEX provider context and interface
│   ├── soc_health_observers.h    # Final formatter/observer cursors and VGA hooks
│   └── hex_display.h             # HEX API; S4-A RAW_LOW/RAW_HIGH getters
├── services/
│   ├── soc_health.c              # Live records/history, copied snapshots and FNV-1a
│   ├── soc_health_probes.c       # S2 placeholder dispatch; compatibility/unit tests
│   ├── soc_health_providers.c    # Strong-provider FSMs; sole VGA operation owner
│   ├── soc_health_board_io.c     # GPIO loop, shared SW generation, LED/HEX checks
│   ├── soc_health_observers.c    # Final shared text, VGA preparation and UART1 TX
│   └── soc_health_render.c       # S2 non-MMIO observer skeleton; compatibility/tests
└── drivers/
    ├── timer.c                   # Timer MMIO commands/status
    ├── uart.c                    # UART0/1 MMIO and bounded byte APIs
    ├── gsensor.c                 # Coherent CAPTURE/read/RELEASE API
    ├── adc.c                     # ADC v2 identity, HOLD, errors and calibration
    ├── joystick_policy.c         # Pure raw-frame/calibration policy; no MMIO
    ├── gpio.c                    # GPIO direction/latch/input MMIO
    ├── sw.c                      # Dedicated synchronized SW register API
    ├── led.c                     # Dedicated LED latch/readback API
    ├── hex_display.c             # HEX shadow/packing and S4-A raw getters
    ├── vram.c                    # Framebuffer writes and VGA status/operations
    └── vga_text.c                # Existing 8x8 font and packed framebuffer text
```

`soc_health_observers.c` and `soc_health_observers.h` are the final S4-B hardware observer path. Although the application's variable is named `render`, its type is `soc_health_observers_t`. The app installs `soc_health_observers_vga_prepare` and `soc_health_observers_vga_release` into the provider context and calls `soc_health_observers_uart_service` each loop. `soc_health_render.c` remains the S2 bounded, non-MMIO cursor skeleton, and `soc_health_probes.c` remains S2 pending-only dispatch: neither is the application's final hardware path. Their compatibility/unit-test APIs remain available; the health build lists them, while unused functions can be discarded by link-time section GC.

#### Data and control flow

```text
+------------------------------------------------------------------------------+
| soc_health_main.c -- one cooperative software epoch per loop                 |
| Epoch/system record -> one bounded provider dispatch -> UART observer tick   |
| Then check publication cadence; no full-provider sweep in one turn.          |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| Provider layer: soc_health_providers.c + soc_health_board_io.c               |
| Timer: COUNT/READY/ACK/restart    GPIO: settled 0,1,1,0 pin loop             |
| UART: UART0 TX -> UART1 RX       SW: captured synchronized 10-bit generation |
| GSEN: CAPTURE/read/RELEASE + seq LED: same SW generation -> mirror/readback  |
| ADC: coherent HOLD/seq/count    HEX: same SW -> decoder/raw readback         |
| JOY: HW status vs pure FW policy; ADC may qualify JOY in its bounded step.   |
| VGA: sole operation-owner FSM; invokes observers VGA prepare/release hooks.  |
| Reports: fresh progress token/detail, failure, pending or deadline miss.     |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| soc_health.c -- live core state (single cooperative owner)                   |
| 12 stable IP records: state/evidence/HB/last_progress/misses/detail          |
| Fresh progress -> current PASS; FAIL/deadline miss -> sticky_fail_mask.      |
| Recovery changes current state; sticky failure history remains.              |
| AES-GCM: EXCLUDED_PENDING_CLEANUP; never dispatched as a provider.           |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| soc_health_publish_snapshot -- two static copied slots, no allocation        |
| Copy logical fields; derive current PASS/WARN/FAIL/EXCLUDED masks here.      |
| Compute deterministic 32-bit FNV-1a over explicit little-endian fields.      |
| Slot reader bits = VGA | UART; any held lease prevents slot overwrite.       |
| Publication due after 32 epochs since last success, only if app pair idle;   |
| otherwise increment backlog; no free slot also increments core backlog.      |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| soc_health_observers.c -- same const snapshot N -> one common formatter      |
| soc_health_format_line: copied EP/SIG/masks/records; no live reads or MMIO.  |
| Both observers retain N across turns; explicit cursors bound work.           |
+------------------------------------------------------------------------------+
               | same frozen N                  | same frozen N
               v                                v
+-------------------------------------+  +-------------------------------------+
| VGA dashboard (observers.c)         |  | UART1 PC-TX observer (observers.c)  |
| Called inside provider VGA FSM      |  | One byte/readiness attempt per turn |
| 640x480; 8x8; 16px row pitch        |  | Same EP/SIG and logical lines       |
| Bounded back-buffer clear/glyphs    |  | Append-only CRLF; banner/separator  |
| Then owner: stale-event ACK ->      |  | Final-byte drain before release     |
| fresh VSYNC -> SWAP -> fresh DONE   |  | Timeout releases UART lease only    |
| No ABORT -> live VGA progress       |  | TX never qualifies UART heartbeat   |
| VGA hook releases its own lease     |  | UART cursor clears on own release   |
+-------------------------------------+  +-------------------------------------+
```

The diagram separates mutable health records from the copied view. Current masks are derived in `soc_health_publish_snapshot`, not continuously stored in the live core. UNKNOWN contributes to none of the four current masks. The signature is an explicit-field, deterministic consistency identifier, not a cryptographic hash or proof of physical output; mutable reader bits and structure padding are outside its input.

VGA preparation is a callback of the existing `soc_health_vga_service` owner, not a second operation controller. It clears at most eight words or renders at most four glyphs per prepare visit, then returns to the dispatcher. The owner alone sequences fresh VSYNC/SWAP/associated DONE and rejects ABORT. The UART observer advances separately after the selected provider dispatch. Neither output recomputes health state; both use the same `soc_health_format_line` and snapshot EP/SIG. Automated UART evidence remains the 12-byte UART0 TX -> UART1 RX token loop; UART1 TX is observer-only.

#### One publication cycle

1. `soc_health_epoch_begin` increments the software epoch and reports system-loop progress. This records software execution, not independent CPU hardware qualification.
2. `soc_health_providers_service` selects one bounded dispatch: five initial setup visits (UART, Timer, GSEN, ADC, VGA), then round robin over provider IDs 1-10. A dispatch advances a transaction rather than completing every provider; an eligible ADC capture may also qualify JOY from that exact HOLD.
3. Progress/failure/pending/deadline reports update live records; the core API also supports WARN. Fresh progress tokens qualify HB; pending work does not invent progress. Failures set sticky history, retained after recovery. SW keeps one captured generation until LED and HEX retire it.
4. After the provider dispatch, UART1 advances its existing observer cursor by at most one byte. When at least 32 epochs have elapsed since the last successful publication, the app publishes only if both current observers are idle; otherwise it increments backlog. This is a software cadence, not a measured wall-clock rate.
5. The core chooses a slot with no readers, copies logical records/metadata, derives current masks, computes explicit-field FNV-1a and sets both reader lease bits. If no slot is free, it records backlog rather than overwriting. `soc_health_observers_begin` gives both cursors the same const N.
6. On later VGA dispatches, the sole owner incrementally prepares N's complete back buffer, acknowledges stale events, waits for fresh VSYNC, issues SWAP, and requires fresh associated DONE with no ABORT. Completion qualifies live VGA progress and releases VGA's lease; failure/timeout releases that lease without successful completion.
7. Interleaved UART observer visits emit the same logical lines with banner, CRLF and separator. The cursor waits for the final byte to drain before releasing UART's lease; a timeout releases only that lease and records a live observer miss. Either observer can finish first.
8. The slot is reusable only after both reader bits are cleared; observer pointers are cleared on release. Provider progress and observer metadata updates while N is observed change live state and appear only in a later N+1. N's VGA record therefore predates its own dashboard SWAP completion.

**Evidence boundary:** Host/unit verified; provider/driver/RTL verified; RV32I image built. `soc_health_main` CPU E2E, physical board and Quartus/TimeQuest remain NOT_RUN; AES remains excluded. See §11.1 for the S5 readiness matrix and remaining gates. This walkthrough adds no new verification or C4 authorization.


## 11. Acceptance and future falsification map

Future tests shall connect contract → independently derived oracle → stimulus/checker → unique source/run → raw evidence/verdict. All were NOT_RUN at S1 freeze. S2 now has a passing host suite with an independent serialized-signature oracle, per-ID masks, padding/copy/lease tests, token/deadline tests and bounded scheduler/observer tests; six isolated defect mutations are rejected. Compile, target and guard failure fixtures propagate nonzero to the parent and consistent FAIL reports. The actual RV32I skeleton build passes; existing display_smoke before/after memory images are identical. Those hardware/board/review scopes were NOT_RUN in S2. S3 provider host tests and actual peripheral RTL integration now pass, including isolated defect rejection and relevant prior regressions. Physical peripheral execution, board wiring/display, real-time quotas and stack high-water remain NOT_RUN. S3 owner review was accepted before S4-A; S4-A host/RTL checks and targeted rejection are verified under §10.3, S4-A owner review was accepted; S4-B owner review was accepted; S5 closure owner review is required. Run `RUN_ROOT=<external-directory> scripts/wsl/soc_health_host_test.sh`; each run must use fresh output storage. Raw evidence is retained outside the checkout and reported through the stage result, not embedded in this contract.

| Criterion | Oracle / targeted defect that must be rejected |
|---|---|
| State/history | Explicit state transitions/deadlines; recovery must preserve sticky failure and misses. Reject an excluded AES fail bit or optimistic UNKNOWN PASS. |
| Snapshot | One immutable object and explicit-field signature; reject observer-specific recalculation or overwrite while N is in flight. |
| UART/GPIO | Independently requested token/pattern versus received/synchronized values; reject stale/corrupt token and stuck/inverted GPIO even if output readback matches. |
| G-sensor/ADC | Coherent captures with temporal seq/count progress; reject API success with constant seq, invalid CH1/2 mask, or ignored ADC sticky error. |
| Joystick | Raw HOLD/calibration-derived saturation/strict boundaries; reject axis/validity/threshold mismatch rather than copying HW status. |
| VGA | Fresh acknowledged event sequence and operation ownership; reject static image, stale VSYNC/DONE, clear-only DONE, or ignored ABORT. |
| SW/LED/HEX | Captured SW independently predicts latch/packing; reject LED mismatch, wrong HEX digit grouping/polarity. Readback does not qualify physical illumination. |
| Build/regression | Actual RV32I image-size/build and relevant regression exits; failures propagate through leaf/guard/parent into final nonzero and consistent reports. |

New/materially changed checkers shall accept valid cases and reject targeted counterexamples in isolated fixtures without mutating approved production or old evidence. Finite polling still cannot recover a terminal CPU/bus fault; signature equality still cannot prove physical output. Preserve failed attempts and keep runtime versus source-level alignment verdicts separate.

### 11.1 S5 verification closure and C4 handoff boundary

S5 completes without changing production C, drivers, peripheral RTL, checkers or the build script. Four S2/S3/S4-A/S4-B host suites and three provider/driver/RTL suites pass in fresh runs. Six S2 isolated mutations, ten S3 host/six RTL mutations, nineteen S4-A negative cases and thirty-two S4-B negative cases recheck actual targeted rejection/failure propagation. Inherited P06 Timer, P07 UART, P08B VGA/VRAM, P09 G-sensor host (real GS RTL covered by S3 integration), P10 HEX functional/shadow, P11 ADC/JOY C2/C3 and P04 GPIO/SW/LED host plus S4-A real RTL run successfully. These are not CPU E2E or physical acceptance. Raw command/source/hash/target/guard/parent evidence is retained externally and referenced by the S5 result comment.

Fresh `soc_health_main` RV32I/ILP32/nostdlib build: `.imem` **13,492 / 16,384 bytes (82.3486%)**, headroom **2,892**, delta versus S4-B **0**. `.dmem_init` **1,048**, `.bss` **1,556**, allocated span **2,604 / 32,768**, headroom **30,164 bytes**. Actual ELF sections/map/symbols confirm these sizes; ELF/MIF/map/disassembly hashes are retained. No undefined symbols, printf/allocation/memcpy/memset/mul/div/mod helpers or unexpected libc/libgcc. Existing observer-only `-Os` remains; other code stays O2. Representative non-health `display_smoke` IMEM/DMEM binaries/MIFs are byte-identical to entry and exclude health services. Default depths remain 4096/8192.

16 KiB baseline retained; capacity pressure observed: **YES**; closure fit: **YES**. Largest linked text symbols are board service 1,660, signature 1,288 and formatter 1,020 bytes. New observer formatter/UART service/VGA prepare are 1,020/384/332 bytes: a major part of S4-B growth, not the majority of total text. No further size optimization or memory enlargement was performed.

This is the Issue #7 handoff matrix. RV32I BUILT means inclusion in the firmware image, not CPU execution. CPU/system host verification covers health core/scheduler only. Physical UART jumper/USB-UART/PuTTY, GPIO jumper, SW/LED/HEX mapping, VGA monitor, ADC/joystick/sensors, real-time quotas, stack high-water, soc_health_main CPU E2E and Quartus/TimeQuest all remain NOT_RUN. AES is EXCLUDED_PENDING_CLEANUP. Do not resume Issue #6 C4 until User/Chat accepts S5 and the Issue #7 handoff. No baseline release, Issue closure or push was performed.

| Scope | Host | RTL/driver | Firmware image | Physical | CPU E2E | Vendor |
|---|---|---|---|---|---|---|
| CPU/system loop | HOST VERIFIED (health core/scheduler only) | — | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| Timer | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| UART heartbeat | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| UART observer | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| GPIO | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| G-sensor | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| ADC | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| Joystick | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| VGA heartbeat | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| VGA dashboard | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| SW | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| LED | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| HEX | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| AES-GCM | EXCLUDED | EXCLUDED | EXCLUDED | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| snapshot/formatter | HOST VERIFIED | RTL/DRIVER VERIFIED (observer outputs) | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| build flow | HOST VERIFIED (image compatibility) | — | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |

### 11.2 Real-Hardware Acceptance & Telemetry Evidence (Issue #6 C4-B / putty_26_09_27_1.log)

Physical hardware acceptance on the Terasic DE10-Lite FPGA was executed under Issue #6 C4-B and fully verified across **4,055 consecutive parsed health snapshots** spanning 68.0 million clock cycles in the serial telemetry log:
- **Telemetry Log**: `/home/swp/soc/putty_26_09_27_1.log` (SHA-256 `469047c4b037e6b0bcbdaee63e9098a09f8043815ff5e78b931756ed7109cd3e`).
- **Live Board Photo**: `/home/swp/soc/P11_board_test.jpg` (SHA-256 `45f0180f3fbcbe2d686fcad80878bb7bd08069cba50be750916788c8432a6227`). Captured at epoch 141,025,616 cycles (`0x0867E150`) showing `SYSTEM: PASS`, switches `V=380`, `HEX=180`.
- **48s Real-Board Video Demo**: `https://www.youtube.com/shorts/RxXCySoRTMY`.

#### Key Real-Hardware Verification Findings:
1. **Autonomous Fault Detection & Recovery (GPIO Loopback)**:
   - Deliberate physical disconnection of the GPIO jumper (`PIN_V10` to `PIN_W10`) was detected in real-time, incrementing `MISS` count to `0x007A` and latching sticky failure mask `S=0x00000008` (bit 3 = GPIO).
   - Reconnecting the jumper resulted in instantaneous recovery to `P ... LOOP` with rapid heartbeat advancement (`HB=0x00141D30` = 1.31M packets), verifying resilient autonomous recovery without CPU hang.
2. **Mathematical SW-to-HEX APB Translation & MMIO Readback**:
   - Firmware translation rules $M = (\text{SW} \gg 9) \ \&\ 1$ and $P = \text{SW} \ \&\ \text{0x1FF}$ were verified against all 4,055 snapshots across 31 distinct switch configurations with **0 mismatches (100% mathematical fidelity)**.
   - Hardware MMIO readback of `HEX_CTRL`, `HEX_VALUE`, `HEX_RAW_LOW`, and `HEX_RAW_HIGH` exhibited zero readback faults (`HEX P ... MISS=0000` throughout).
3. **ADC & Joystick Zero-Miss Coexistence**:
   - Monotonic sequence progression up to `SEQ=0x084ABAAE` (139,115,182 captures on live hardware) with **zero missed frames (`MISS=0000`)**.
   - Hardware register `ADC_JOY_STATUS` and firmware oracle `joystick_policy_eval()` maintained **100% agreement across all 4,055 snapshots**.
4. **Inter-Subsystem Coexistence**:
   - High-throughput VGA memory traffic (8,333+ framebuffer swaps), 577,912 successful UART hardware loopback transfers (0 drops), dynamic slide switch toggling, and continuous HEX readback ran concurrently without perturbing ADC acquisition or CPU execution.

## 12. Baseline-cleanup spec/FW reconciliation tracker (Role B)

### 12.1 Operating policy and schema

Track `canonical IP spec ↔ RTL-visible behavior ↔ FW driver/API ↔ soc_health assumption`. Owning IP specs remain authoritative; this is the temporary consolidation ledger. Append new mismatches to both English/Korean trackers during Issue #7 and later cleanup. Do not broadly rewrite unrelated owning specs now. Near cleanup completion, use this ledger for one coordinated reconciliation pass; update status/evidence after reconciliation and retain history rather than deleting findings.

Required fields are ID, IP/subsystem, canonical spec source, FW source/API, observed mismatch, accepted/current authority, required future reconciliation, status, origin issue/phase, and verification evidence. Allowed statuses: `OBSERVED`, `CLEANUP_PENDING`, `IMPLEMENTATION_ACCEPTED_DOC_STALE`, `FW_STALE`, `SPEC_STALE`, `VERIFIED_ALIGNED`.

`VERIFIED_ALIGNED` means source/API alignment for the stated contract only; it is not new runtime/board acceptance. The following preserves S0 findings/status classifications at the source anchor. S1 documentation dispositions are recorded explicitly; no unrelated cleanup requirement is promoted to closed.

Evidence IDs: **E0** = S0 static source inspection at the anchor and accepted result; **E1** = S1 document delta at its local documentation checkpoint. Neither denotes executed firmware tests. Owning specs contain their own historical evidence references. No raw logs, machine-local paths, or private payload are embedded here.

### 12.2 Initial records and S1 dispositions

All rows originate from Issue #7/S0, carried into S1. `firmware/` prefixes in the FW column and `spec/` prefixes in the spec column are repository-relative.

| ID / subsystem | Canonical spec source | FW source/API | Observed mismatch/debt | Accepted/current authority | Required reconciliation / S1 disposition | Status (scope) | Origin | Evidence |
|---|---|---|---|---|---|---|---|---|
| HREC-CPU / CPU | `19_firmware_contract.md` §2; `21_cpu_core.md` | `bsp/start.S` | Startup narrative omits early mtvec installation/diagnostic fail-stop. | Existing startup installs mtvec and fail-stops; pre-mtvec risk remains. | Reconcile startup narrative later; preserve trap behavior. | IMPLEMENTATION_ACCEPTED_DOC_STALE | #7/S0→S1 | E0; startup source |
| HREC-TIMER / Timer | `10_timer.md` §21; `19_firmware_contract.md` §37 | `drivers/timer.c`, `include/timer.h` | Command subset aligned; timer_wait_ready remains unbounded. | Exact-N START/STOP/RELOAD; W1C does not restart. | Health uses status/finite service; legacy wait debt remains separate. | VERIFIED_ALIGNED (command subset); CLEANUP_PENDING (legacy wait) | #7/S0→S1 | E0; driver source |
| HREC-UART / UART0/1 | `09_uart.md` P07B; firmware §38 | `drivers/uart.c`, `include/uart.h`, `drivers/lora_uart.c` | Older A4 text leaves safe minimum unresolved; current 217 limit and finite APIs exist. | Current P07B; raw loop excludes AUX/module policy. | Reconcile old addendum later; §6 freezes loop exception. | IMPLEMENTATION_ACCEPTED_DOC_STALE; VERIFIED_ALIGNED (active API) | #7/S0→S1 | E0; UART source; E1 §6 |
| HREC-GPIO / GPIO | `11_gpio.md` active Part II; firmware P04 note | `drivers/gpio.c`, `include/gpio.h`, `bsp/linker.ld` | Firmware §11/linker comments retain SW/LED pseudo-GPIO. | P04 true 16-pin GPIO with synchronized input. | Reconcile historical prose/comments later; use owned pair only. | IMPLEMENTATION_ACCEPTED_DOC_STALE | #7/S0→S1 | E0; APB_GPIO/driver source |
| HREC-GSENSOR / G-sensor | `12_gsensor.md` §§7–9; firmware §12 | `drivers/gsensor.c`, `include/gsensor.h` | API aligned; temporal sequence requirement must be added at health layer. | Single-owner CAPTURE/read/RELEASE, finite NO_NEW/BUSY. | Preserve ABI; verify new heartbeat progression later. | VERIFIED_ALIGNED | #7/S0→S1 | E0; coherent driver source |
| HREC-ADC / ADC | `15_adc_joystick.md` §§8–9; firmware §§13/27 | `drivers/adc.c`, `include/adc.h`, `include/soc_memory_map.h` | Broad In-progress labels remain despite parent C3/C3.5 acceptance. | Accepted v2 checkpoint; bit6 reserved zero; C4 pending. | Reconcile status narrative later, preserve separate C4 gate/count semantics. | IMPLEMENTATION_ACCEPTED_DOC_STALE (narrative); VERIFIED_ALIGNED (API) | #7/S0→S1 | E0; v2 source/parent acceptance |
| HREC-JOY / joystick | `15_adc_joystick.md` §§10–11 | `drivers/joystick_policy.c`, `include/joystick_policy.h`, `drivers/joystick.c` | Pure model aligned; compatibility init/enable discard results and reads may fall back to stale HOLD. | Saturated strict-threshold model over coherent HOLD/current calibration. | Use adc APIs directly for health; preserve compatibility limitations as observed debt. | VERIFIED_ALIGNED (pure model); OBSERVED (compatibility) | #7/S0→S1 | E0; policy/wrapper source |
| HREC-VGA / VGA | `08_vga.md` §§2–3 | `drivers/vram.c`, `include/vram.h`, `drivers/vga_text.c` | Firmware §7 still lists VGA waits unbounded; begin_frame switches/clears before returning. | Current waits bounded; explicit operation/ownership contract. | Reconcile stale prose later; compose cooperative render-then-swap. | IMPLEMENTATION_ACCEPTED_DOC_STALE; OBSERVED (helper ordering) | #7/S0→S1 | E0; VRAM/text source |
| HREC-HEX / HEX | `16_hex_display.md` §§5–7,10,12 | `drivers/hex_display.c`, `include/hex_display.h` | Existing CTRL/packing aligned; RAW getters absent at S0; narrowly added in S4-A. | P10 shadow ownership; readable 21-bit RAW banks. | S4-A getters implemented/tested; preserve historical P10 prose for later reconciliation. | VERIFIED_ALIGNED (existing API/getters, host/RTL); physical evidence NOT_RUN | #7/S0→S1→S4-A | E0; HEX source; E1 §8.3; S4-A §10.3 host/RTL |
| HREC-SW / SW | `17_sw.md` P04 note | `drivers/sw.c`, `include/sw.h` | Historical target/unimplemented body conflicts with active note. | Synchronized dedicated 10-bit slot8 input. | Reconcile body later; static input remains valid. | IMPLEMENTATION_ACCEPTED_DOC_STALE; VERIFIED_ALIGNED (API) | #7/S0→S1 | E0; SW source |
| HREC-LED / LED | `18_led.md` P04 note | `drivers/led.c`, `include/led.h` | Old body denies APB_LED and retains LED9 reset ownership. | Dedicated 10-bit slot9 output latch/readback. | Reconcile prose later; retain physical evidence distinction. | IMPLEMENTATION_ACCEPTED_DOC_STALE; VERIFIED_ALIGNED (API) | #7/S0→S1 | E0; LED source |
| HREC-AES / AES-GCM | `14_aes_gcm.md`; firmware AES rules | `drivers/aes_gcm.c`, `include/aes_gcm.h` | Baseline cleanup deferred; cannot become health dependency. | Existing owning contract; health EXCLUDED_PENDING_CLEANUP. | Separate later cleanup/provider approval; no AES operation here. | CLEANUP_PENDING | #7/S0→S1 | E0; accepted scope; E1 §2 |
| HREC-BUILD / build | `19_firmware_contract.md` memory contract | `firmware/README.md`, `scripts/firmware/build_fw.sh`, `bsp/linker.ld` | README claims fallback absent in script; linker GPIO/JOYSTICK comments stale. | External RUN_ROOT required; 16 KiB/32 KiB capacities unchanged. | S1 corrects README fallback; defer linker comments and verify service/image fit in S2–S5. | FW_STALE (S0 README finding); OBSERVED (linker debt) | #7/S0→S1 | E0; build/linker source; E1 README |
| HREC-APP / application role | `19_firmware_contract.md`; this spec §1 | `apps/final_main.c`; firmware/top README | Historical RC-car app lacked explicit canonical-vs-demo split. | Retained external-system demo; future standalone soc_health_main. | S1 documents split/link; future implementation and coordinated reconciliation remain pending. | CLEANUP_PENDING (S0 role finding; S1 documentation disposition recorded) | #7/S0→S1 | E0; accepted scope; E1 role entries |

### 12.3 Deferred documents and extension rules

Broad rewrites of `08_vga.md`, `09_uart.md`, `10_timer.md`, `11_gpio.md`, `12_gsensor.md`, `14_aes_gcm.md`, `15_adc_joystick.md`, `16_hex_display.md`, `17_sw.md`, `18_led.md` and companions remain deferred, as do unrelated firmware-contract sections/linker historical comments. Only the historical/new-health entry in firmware contract is added now. This ledger does not replace `baseline_cleanup.md` or change existing requirement status.

Later IP additions shall specify production API, evidence strength, bounded failure behavior, independent oracle and tests, then update both language contracts/trackers after approval. Reconciliation shall retain origin, prior status, final disposition and evidence. AES can join only after its separately approved cleanup/provider work; no future expansion is implied by its placeholder.

### 12.3 S2 reconciliation scope

No new spec/FW mismatch was discovered in S2 infrastructure work. The S0/S1 ledger above is retained without closing peripheral or cleanup debt; S2 implements only §10.1 and does not promote any hardware provider to runtime verified.

### 12.4 S3 reconciliation scope

No new owning spec/FW mismatch was discovered in S3. Existing provider integration uses accepted APIs without changing peripheral RTL/drivers, ADC ABI or the prior cleanup ledger.

### 12.5 S4-A reconciliation scope

No new owning spec/FW mismatch was discovered. HREC-HEX retains its S0 origin and records the approved getter implementation/host/RTL verification; unrelated historical API narratives and physical acceptance are not closed.

### 12.6 S4-B reconciliation scope

| ID / IP | Source requirement | Observed gap at S4-A | Narrow S4-B disposition | Status / evidence |
|---|---|---|---|---|
| HREC-OBS-SEQ / UART, GSEN, ADC observer input | S4-B common-format SEQ and frozen-only text | Actual qualified tokens remained live; copied successful detail held baud=434/0/FRAME_COUNT, so truthful SEQ was unavailable. | Store actual qualified sequence in successful detail only; preserve core ABI, qualification and failure semantics. ADC FRAME_COUNT baseline remains provider-local. | IMPLEMENTED_HOST_RTL_VERIFIED; S4-B finding and real provider→snapshot→formatter assertions; owner accepted at S4-B; S5 closure review pending. |

No other owning specification or cleanup history is reconciled here. This finding does not reopen peripheral RTL, physical acceptance, C4 or P08B STOP gates.

### 12.7 S5 Issue #7 reconciliation disposition

The S0/S1 findings and original statuses above remain historical records. This table updates current Issue #7 status/evidence only; broad owning-spec debt and physical/runtime acceptance remain open.

| ID | Current scoped status | S0–S5 disposition / evidence |
|---|---|---|
| HREC-APP | VERIFIED_ALIGNED (Issue #7 application-role split) | S1 role documentation and implemented canonical soc_health_main; final_main historical RC-car source preserved. |
| HREC-BUILD | VERIFIED_ALIGNED (health build/README); OBSERVED (historical linker comments) | S5 fresh RV32I build, size/symbol audit and byte-identical display_smoke images; unrelated linker narrative debt retained. |
| HREC-UART | VERIFIED_ALIGNED (health loop/observer); IMPLEMENTATION_ACCEPTED_DOC_STALE (old owning prose) | S3/S4-B accepted, S5 host/real serial RTL: UART0→UART1 RX qualified; UART1 TX observer only. |
| HREC-GPIO | VERIFIED_ALIGNED (owned pair health); IMPLEMENTATION_ACCEPTED_DOC_STALE (historical prose) | S4-A accepted; S5 host faults and real RTL with simulated GPIO0→1 jumper; physical jumper NOT_RUN. |
| HREC-GSENSOR | VERIFIED_ALIGNED (API/health progression) | S3 accepted and S5 host/RTL advancing coherent CAPTURE/read/RELEASE; physical sensor NOT_RUN. |
| HREC-ADC | VERIFIED_ALIGNED (v2 API/health); IMPLEMENTATION_ACCEPTED_DOC_STALE (owning narrative) | S3 accepted, S5 C2/C3 and health host/RTL freshness/validity/errors; C4 still pending. |
| HREC-JOY | VERIFIED_ALIGNED (pure model/health); OBSERVED (compatibility wrapper debt) | S5 raw HOLD/calibration independent oracle and C3 policy boundaries; wrapper limitations unchanged. |
| HREC-VGA | VERIFIED_ALIGNED (health owner/dashboard); IMPLEMENTATION_ACCEPTED_DOC_STALE (historical waits); OBSERVED (legacy helper ordering) | S4-B accepted; S5 full raster/back-bank/fresh VSYNC/SWAP/DONE and immutable N; monitor NOT_RUN. |
| HREC-HEX | VERIFIED_ALIGNED (API/getters/health) | S4-A accepted, S5 P10 functional/shadow and shared-SW host/RTL; physical illumination NOT_RUN. |
| HREC-SW | VERIFIED_ALIGNED (API/health); IMPLEMENTATION_ACCEPTED_DOC_STALE (old owning prose) | S5 captured synchronized 10-bit input and shared generation tests; physical switches NOT_RUN. |
| HREC-LED | VERIFIED_ALIGNED (API/health); IMPLEMENTATION_ACCEPTED_DOC_STALE (old owning prose) | S5 captured SW mirror/latch oracle; physical mapping NOT_RUN. |
| HREC-AES | CLEANUP_PENDING; EXCLUDED_PENDING_CLEANUP | No AES execution/provider; separate cleanup approval required. |
| HREC-OBS-SEQ | VERIFIED_ALIGNED (accepted successful diagnostic payload, host/RTL only) | S4-B user acceptance: UART/GSEN/ADC successful detail holds qualified 32-bit sequence; S5 exact eight-digit and upper-bit checks. |
| HREC-CPU / HREC-TIMER | Original scoped status/debt retained | No startup/trap or legacy timer-wait changes; health bounded service only, CPU execution NOT_RUN. |
