# SoC Health Firmware Contract and Reconciliation Tracker

> **Status:** S1 contract preserved; S2 health core/snapshot/scheduler skeleton implemented and locally host-tested/built for RV32I. Peripheral providers and hardware observers remain unimplemented; no board, timing, or Clean Baseline acceptance.
> **Language:** English is canonical; [Korean companion](kor/22_soc_health_firmware.ko.md) mirrors this contract.
> **Roles:** Role A defines the standalone health firmware. Role B consolidates baseline-cleanup spec/FW reconciliation debt without replacing owning IP specifications.
> **Source anchor:** `390db6da2dcc8bbfa1c93b444525b0ba1e852056`. Trace IDs: Issue #7 S0 result `5845036298`, S0 acceptance `5845199371`, S1 task `5845199693`; these are internal governance locators, not public runtime evidence.

## 1. Status, purpose, and historical split

`firmware/apps/final_main.c` is **HISTORICAL RC-CAR SYSTEM DEMO FIRMWARE**. It is retained for provenance and demo reproduction, depends on the external STM32-based RC-car system, and is not the canonical standalone SoC integration-test firmware. After Issue #7 completes and is reviewed, it is not the basis for Issue #6 C4-A/C4-B.

Owner-provided demonstration: [FPGA SoC + STM32 RC-car demo](https://www.youtube.com/shorts/XYbi3uSHmUU). The link documents provenance; it does not independently qualify the future health monitor.

The future canonical application is `firmware/apps/soc_health_main.c`. It shall run standalone without the external RC-car system, exercise production peripheral contracts, report progress and failures, and freeze one snapshot for VGA and PC UART observers. It remains a reusable system diagnostic rather than an ADC-only test.

S1 changes documentation only. The application, services, providers, scheduler, and HEX raw getters do not exist as S1 deliverables. S2 now adds only the infrastructure described in §10.1. S2 results require owner review before S3; Issue #6 C4 remains paused. Owning IP specifications remain authoritative for registers, hardware behavior, and existing acceptance scope. Preserve all existing STOP gates; this document does not reopen P08B, add interrupts/PLIC, redesign ADC/peripheral RTL, change pins, or close global cleanup/STA/board requirements.

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

The following paths now exist for S2 infrastructure and host verification:

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

The services layer is application service code, not a hardware driver. The minimal `scripts/firmware/build_fw.sh` change includes the three health services only for the new app; existing app flows are preserved. Builds require external RUN_ROOT; the supported command is `scripts/firmware/build_fw.sh soc_health_main` with that environment set. Preserve RV32I/ILP32 freestanding behavior, existing startup/trap, **16 KiB IMEM / 32 KiB DMEM**, and explicit paired memory-image identity. Memory capacity and startup/trap are unchanged. S2 builds the skeleton; peripheral acceptance remains deferred.

| Stage | Approved future boundary |
|---|---|
| S2 HEALTH CORE | App skeleton, services, records/current masks/sticky history, immutable snapshot/signature, cooperative bounded scheduler. |
| S3 STRONG PROVIDERS | Timer, UART loopback, G-sensor, ADC, joystick consistency, VGA progress. |
| S4 BOARD I/O + OBSERVERS | GPIO0→1, SW, SW-mirrored LED, HEX dual mode/raw getters, VGA and PC UART shared-snapshot rendering. |
| S5 CLOSURE | Host/unit tests, RV32I build/image-size check, relevant existing regressions, clean local checkpoint. |

S1 implemented none of S2–S5. S2 infrastructure is now implemented; stop for owner review before S3. After S5, stop for review before Issue #6 C4-A/C4-B resumes. No push, vendor execution, baseline release, or global tracker closure is implicitly authorized.

### 10.1 S2 core ABI, ownership and deterministic signature

Stable IDs are SYSTEM_SERVICE=0, TIMER=1, UART_LOOP=2, GPIO=3, GSENSOR=4, ADC=5, JOY_POLICY=6, VGA=7, SW=8, LED=9, HEX=10, AES_GCM=11. Mask bit `1u << id` is fixed. State and evidence enum order matches §2. Each record stores state, evidence, heartbeat_count, last_progress_epoch, miss_count and detail. Current masks are derived from copied records at publication; UNKNOWN contributes no bit. FAIL sets sticky history; recovery does not clear it. No runtime sticky-clear API exists.

One cooperative owner advances a software epoch without Timer. Each turn visits one of ten round-robin pending providers (IDs 1–10) and at most two observer characters. SYSTEM_SERVICE progress means only that the software service turn ran. All peripheral placeholders stay UNKNOWN with `SOC_HEALTH_NOT_IMPLEMENTED` (0x4e4f5451, NOT QUALIFYING HARDWARE EVIDENCE). AES remains EXCLUDED_PENDING_CLEANUP with no provider/callback; all report attempts for AES are rejected. Production S2 code performs no MMIO.

Progress and deadline-miss tokens are deduplicated per IP/event stream. After the first event, a token must advance modulo 2^32 by a nonzero amount less than 2^31; replay/old completion cannot recover FAIL. PENDING updates detail only. An armed deadline uses unsigned epoch elapsed time, budget less than 2^31, and disarms after one expiry. These are bounded software-turn budgets, not physical time measurements; callers must service deadlines before an entire epoch wrap elapses. Terminal CPU/bus faults remain outside recovery guarantees.

Two static snapshot slots hold copied logical records and metadata. Publishing acquires both observer leases; occupied slots are never overwritten. If both are occupied, publication returns null and increments live backlog. Each observer releases exactly its own lease on completion or timeout; the slot can be reused only after both releases. A pointer is valid only for its acquired lease lifetime, and must not be used after release/reinitialization. There is no concurrent/interrupt ownership protocol. Live updates and releases change future-snapshot metadata, never published content. Observer completion tracks placeholder consumption, not physical display or UART delivery.

The two const-input cursors consume the same snapshot pointer, epoch and signature. Each ready cursor emits one character of `EPOCH=xxxxxxxx SIG=xxxxxxxx` per service call. A 64-epoch budget releases a stalled observer and increments only live observer misses; the other observer can finish independently. The application requests publication every 32 software turns and retains an active render until completion/timeout. Full hardware presentation remains S3/S4 work.

Signature is 32-bit FNV-1a (seed 2166136261, prime 16777619), processing each explicit uint32 word as four little-endian bytes. Target prime multiplication is implemented with shifts/adds; no multiply/divide helper is required. Exact 97-word order:

1. Version tag 0x53483201, epoch, publication_id.
2. pass_mask, warn_mask, fail_mask, excluded_mask, sticky_fail_mask, publication_backlog.
3. observer_miss_count[0], [1], then observer_last_epoch[0], [1].
4. For each ID 0 through 11: ID, state, evidence, heartbeat_count, last_progress_epoch, miss_count, detail.

The signature itself, struct padding, pointers, slot leases and live deduplication tokens are excluded. Equal logical fields give equal signatures; this checksum is neither collision-free nor hardware acceptance evidence.

## 11. Acceptance and future falsification map

Future tests shall connect contract → independently derived oracle → stimulus/checker → unique source/run → raw evidence/verdict. All were NOT_RUN at S1 freeze. S2 now has a passing host suite with an independent serialized-signature oracle, per-ID masks, padding/copy/lease tests, token/deadline tests and bounded scheduler/observer tests; six isolated defect mutations are rejected. Compile, target and guard failure fixtures propagate nonzero to the parent and consistent FAIL reports. The actual RV32I skeleton build passes; existing display_smoke before/after memory images are identical. RTL regressions, actual peripheral execution, physical board tests and independent owner review remain NOT_RUN in S2. Run `RUN_ROOT=<external-directory> scripts/wsl/soc_health_host_test.sh`; each run must use fresh output storage. Raw evidence is retained outside the checkout and reported through the stage result, not embedded in this contract.

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
| HREC-HEX / HEX | `16_hex_display.md` §§5–7,10,12 | `drivers/hex_display.c`, `include/hex_display.h` | Existing CTRL/packing aligned; RAW getters absent for monitor readback. | P10 shadow ownership; readable 21-bit RAW banks. | S4-only narrow getters approved; not implemented in S1. | VERIFIED_ALIGNED (existing API); CLEANUP_PENDING (getters) | #7/S0→S1 | E0; HEX source; E1 §8.3 |
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
