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

The standalone health application is `apps/soc_health_main.c`, governed by [SoC health firmware contract and reconciliation tracker](../spec/22_soc_health_firmware.md) and its [Korean companion](../spec/kor/22_soc_health_firmware.ko.md). S2 implements the immutable snapshot/core and non-MMIO observer cursors; S3 adds bounded real Timer/UART loopback/G-sensor/ADC/joystick/VGA providers. S4-A adds GPIO0→1 loopback, one captured SW generation shared by LED mirror/HEX dual mode, and side-effect-free HEX raw readback getters. GPIO qualification needs a full settled `0,1,1,0` cycle; SW counts observations, LED/HEX count completed register readback transactions, with physical illumination/jumpers still unverified. AES remains EXCLUDED. Build with `RUN_ROOT=<external-directory> scripts/firmware/build_fw.sh soc_health_main`. Run host/core/provider/board suites with fresh external RUN_ROOT: `scripts/wsl/soc_health_host_test.sh`, `soc_health_provider_test.sh`, `soc_health_provider_rtl_test.sh`, `soc_health_board_io_test.sh`, `soc_health_board_io_rtl_test.sh`, `soc_health_board_io_negative_test.sh` (all under `scripts/wsl/`). Board RTL integration uses production peripherals and a simulated GPIO jumper, with an independent external SW-derived segment/output oracle. Existing drivers are preserved except the two approved HEX getters; peripheral RTL is unchanged. S4-B adds one bounded snapshot-to-line formatter feeding the sole-owner VGA dashboard and UART1 TX, with identical frozen EP/SIG. The 640x480/8x8-font dashboard uses x=32, y=16 and 16px row pitch; back-buffer clear/render is chunked before fresh VSYNC/SWAP/DONE. UART1 emits an append-only CRLF snapshot log with a header and separator, one byte per turn, without ANSI or heartbeat qualification. Independent reader leases remain immutable and release on completion/timeout. Successful UART/GSEN/ADC detail now holds actual qualified SEQ displayed as all eight hexadecimal digits, retaining all qualification rules/core ABI. Run `scripts/wsl/soc_health_observer_test.sh`, `soc_health_observer_rtl_test.sh`, `soc_health_observer_negative_test.sh` (all under `scripts/wsl/`) with fresh external RUN_ROOT. Only the new observer service uses `-Os` to fit the unchanged 16KiB IMEM. Stop for S4-B review before S5. Actual board, timing and physical sensor/display acceptance remain deferred. After Issue #7 completion/review, this replaces `final_main` as the Issue #6 C4-A/C4-B firmware basis; C4 remains paused.

The health contract excludes AES-GCM as `EXCLUDED_PENDING_CLEANUP`. UART0 TX → UART1 RX and GPIO0 → GPIO1 require physical jumpers; UART1 TX observes the same frozen snapshot as VGA and never qualifies the UART heartbeat. SW mirrors LED, and SW selects the HEX dual-mode board test. Service builds retain RV32I/ILP32, 16 KiB IMEM/32 KiB DMEM and external RUN_ROOT. Broad per-IP spec/FW reconciliation debt belongs in spec 22 until the later coordinated cleanup pass.

Benchmark and Dhrystone application sources are intentionally excluded from this public snapshot. `dhrystone_main` and `dhrystone_t410n` are not supported build targets, and the project-specific `benchmark_main` workload is not published. Any later performance report is a separately reviewed derivative and must not describe the project's Dhrystone-style case as official Dhrystone 2.1.

For each peripheral, keep the register map, C header/driver, smoke test, and RTL aligned with the approved specification. Firmware must not invent behavior absent from the specification.
