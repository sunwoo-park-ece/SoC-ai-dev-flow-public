# Firmware

Bare-metal startup code, linker configuration, drivers, protocol helpers, and application sources live here. WSL Ubuntu + Codex owns implementation and reproducible build execution; software-visible behavior must agree with `spec/` and the corresponding RTL.

```text
firmware/
├─ apps/
├─ bsp/
├─ drivers/
├─ include/
├─ protocol/
└─ services/
```

Use `scripts/firmware/build_fw.sh <app-name>` with an RV32I cross-toolchain. `$RUN_ROOT` is required and must be outside the source tree; there is no fallback build directory. ELF, binary, disassembly, map, and MIF outputs are written under `$RUN_ROOT/fw/<app-name>`. Generated MIF files are runtime inputs, not public vendor-project state.

## Application roles and health firmware

`apps/final_main.c` is **HISTORICAL RC-CAR SYSTEM DEMO FIRMWARE**: retained for provenance/demo reproduction, dependent on the external STM32-based RC-car system, and not the canonical standalone SoC integration-test firmware. See the owner-provided [FPGA SoC + STM32 RC-car demo](https://www.youtube.com/shorts/XYbi3uSHmUU). Its source and historical behavior are preserved.

The standalone health application is `apps/soc_health_main.c`, governed by [SoC health firmware contract and reconciliation tracker](../spec/22_soc_health_firmware.md) and its [Korean companion](../spec/kor/22_soc_health_firmware.ko.md). S2 implements the immutable snapshot/core and non-MMIO observer cursors; S3 adds bounded real Timer/UART loopback/G-sensor/ADC/joystick/VGA providers. S4-A adds GPIO0→1 loopback, one captured SW generation shared by LED mirror/HEX dual mode, and side-effect-free HEX raw readback getters. GPIO qualification needs a full settled `0,1,1,0` cycle; SW counts observations, LED/HEX count completed register readback transactions, with physical illumination/jumpers still unverified. AES remains EXCLUDED. Build with `RUN_ROOT=<external-directory> scripts/firmware/build_fw.sh soc_health_main`. Run host/core/provider/board suites with fresh external RUN_ROOT: `scripts/wsl/soc_health_host_test.sh`, `soc_health_provider_test.sh`, `soc_health_provider_rtl_test.sh`, `soc_health_board_io_test.sh`, `soc_health_board_io_rtl_test.sh`, `soc_health_board_io_negative_test.sh` (all under `scripts/wsl/`). Board RTL integration uses production peripherals and a simulated GPIO jumper, with an independent external SW-derived segment/output oracle. Existing drivers are preserved except the two approved HEX getters; peripheral RTL is unchanged. S4-B adds one bounded snapshot-to-line formatter feeding the sole-owner VGA dashboard and UART1 TX, with identical frozen EP/SIG. The 640x480/8x8-font dashboard uses x=32, y=16 and 16px row pitch; back-buffer clear/render is chunked before fresh VSYNC/SWAP/DONE. UART1 emits an append-only CRLF snapshot log with a header and separator, one byte per turn, without ANSI or heartbeat qualification. Independent reader leases remain immutable and release on completion/timeout. Successful UART/GSEN/ADC detail now holds actual qualified SEQ displayed as all eight hexadecimal digits, retaining all qualification rules/core ABI. Run `scripts/wsl/soc_health_observer_test.sh`, `soc_health_observer_rtl_test.sh`, `soc_health_observer_negative_test.sh` (all under `scripts/wsl/`) with fresh external RUN_ROOT. Only the new observer service uses `-Os` to fit the unchanged 16KiB IMEM. S4-B was accepted; S5 verification/build/documentation closure is complete and awaits User/Chat review. Actual board, timing and physical sensor/display acceptance remain deferred. After Issue #7 completion/review, this replaces `final_main` as the Issue #6 C4-A/C4-B firmware basis; C4 remains paused.

The health contract excludes AES-GCM as `EXCLUDED_PENDING_CLEANUP`. UART0 TX → UART1 RX and GPIO0 → GPIO1 require physical jumpers; UART1 TX observes the same frozen snapshot as VGA and never qualifies the UART heartbeat. SW mirrors LED, and SW selects the HEX dual-mode board test. Service builds retain RV32I/ILP32, 16 KiB IMEM/32 KiB DMEM and external RUN_ROOT. Broad per-IP spec/FW reconciliation debt belongs in spec 22 until the later coordinated cleanup pass.

Benchmark and Dhrystone application sources are intentionally excluded from this public snapshot. `dhrystone_main` and `dhrystone_t410n` are not supported build targets, and the project-specific `benchmark_main` workload is not published. Any later performance report is a separately reviewed derivative and must not describe the project's Dhrystone-style case as official Dhrystone 2.1.

For each peripheral, keep the register map, C header/driver, smoke test, and RTL aligned with the approved specification. Firmware must not invent behavior absent from the specification.

## Implementation map / code structure

The relevant final SYSFW-01 files are shown below. `soc_health_main.c` wires one cooperative provider dispatch per epoch, the board callback and the final observers; each visit advances bounded work. Services orchestrate driver APIs and update the health core rather than duplicating a whole peripheral driver.

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

`soc_health_observers.c/.h` is the final VGA/UART1 observer implementation. The app's `render` variable uses `soc_health_observers_t`; `soc_health_render.c` and `soc_health_probes.c` retain only S2 non-MMIO observer/pending-dispatch compatibility and unit-test paths. `joystick_policy.c` is a pure model. S4-A intentionally added side-effect-free RAW_LOW/RAW_HIGH getters to `hex_display.c/.h`.

Runtime flow is **one bounded provider dispatch -> live records/sticky history -> copied two-slot snapshot -> common formatter -> VGA and UART1**. Both observers use the same frozen N and EP/SIG; updates during observation appear in a later N+1. The VGA preparation/release callbacks run inside the existing sole operation-owner FSM. UART1 TX advances separately and remains observer-only; automated UART heartbeat is the UART0 TX -> UART1 RX token loop. AES is EXCLUDED_PENDING_CLEANUP and has no active provider. See [Final software architecture](../spec/22_soc_health_firmware.md#105-final-software-architecture) for the ASCII diagram and publication walkthrough.

Host/unit and provider/driver/RTL are verified and the RV32I image is built; `soc_health_main` CPU E2E, physical board and Quartus/TimeQuest remain NOT_RUN. These are the existing [S5 closure boundaries](../spec/22_soc_health_firmware.md#111-s5-verification-closure-and-c4-handoff-boundary), not new test execution or permission to resume C4.

## SYSFW-01 S5 closure and handoff

Production C/drivers/RTL/build policy remain unchanged from accepted S4-B. Final host/provider-driver-RTL and narrow inherited regressions pass; accepted isolated defect/failure guards still reject counterexamples. Fresh RV32I image uses IMEM **13,492 / 16,384 bytes (82.3486%)**, headroom **2,892**, delta versus S4-B **0**; DMEM initialized **1,048** + BSS **1,556** = **2,604 / 32,768**, headroom **30,164 bytes**. No undefined/library/helper dependencies. Observer service retains its scoped `-Os`; unrelated `display_smoke` uses unchanged O2 and entry-identical memory images. **16 KiB baseline retained; capacity pressure observed: YES; closure fit: YES.**

Spec22 §11.1 contains the handoff readiness matrix; §12.7 updates Issue #7 HREC dispositions while retaining old findings and unrelated debt. Host/RTL verification and RV32I build do not prove `soc_health_main` CPU E2E, physical jumpers/USB-UART/PuTTY, switch/LED/HEX/VGA/ADC/sensors, real-time quotas, stack high-water or Quartus/TimeQuest; these remain NOT_RUN. AES remains EXCLUDED_PENDING_CLEANUP. Stop for S5/Issue #7 handoff review; Issue #6 C4 remains paused until explicit User/Chat acceptance. No push or baseline release is implied.
