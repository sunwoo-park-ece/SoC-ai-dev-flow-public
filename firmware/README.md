# Firmware

Bare-metal startup code, linker configuration, drivers, protocol helpers, and application sources live here. WSL Ubuntu + Codex owns implementation and reproducible build execution; software-visible behavior must agree with `spec/` and the corresponding RTL.

```text
firmware/
├─ apps/
├─ bsp/
├─ drivers/
├─ include/
└─ protocol/
```

Use `scripts/firmware/build_fw.sh <app-name>` with an RV32I cross-toolchain. `$RUN_ROOT` is required and must be outside the source tree; there is no fallback build directory. ELF, binary, disassembly, map, and MIF outputs are written under `$RUN_ROOT/fw/<app-name>`. Generated MIF files are runtime inputs, not public vendor-project state.

## Application roles and future health firmware

`apps/final_main.c` is **HISTORICAL RC-CAR SYSTEM DEMO FIRMWARE**: retained for provenance/demo reproduction, dependent on the external STM32-based RC-car system, and not the canonical standalone SoC integration-test firmware. See the owner-provided [FPGA SoC + STM32 RC-car demo](https://www.youtube.com/shorts/XYbi3uSHmUU). Its source and historical behavior are preserved.

The future canonical standalone application is `apps/soc_health_main.c`, governed by [SoC health firmware contract and reconciliation tracker](../spec/22_soc_health_firmware.md) and its [Korean companion](../spec/kor/22_soc_health_firmware.ko.md). S1 freezes documentation only; the app, reusable `services/` layer, header and build integration start in S2 or later. `soc_health_main` is not yet a supported build target. After Issue #7 completion/review, it replaces `final_main` as the Issue #6 C4-A/C4-B firmware basis; C4 remains paused in S1.

The health contract excludes AES-GCM as `EXCLUDED_PENDING_CLEANUP`. UART0 TX → UART1 RX and GPIO0 → GPIO1 require physical jumpers; UART1 TX observes the same frozen snapshot as VGA and never qualifies the UART heartbeat. SW mirrors LED, and SW selects the HEX dual-mode board test. Future service builds must retain RV32I/ILP32, 16 KiB IMEM/32 KiB DMEM and external RUN_ROOT. Broad per-IP spec/FW reconciliation debt belongs in spec 22 until the later coordinated cleanup pass.

Benchmark and Dhrystone application sources are intentionally excluded from this public snapshot. `dhrystone_main` and `dhrystone_t410n` are not supported build targets, and the project-specific `benchmark_main` workload is not published. Any later performance report is a separately reviewed derivative and must not describe the project's Dhrystone-style case as official Dhrystone 2.1.

For each peripheral, keep the register map, C header/driver, smoke test, and RTL aligned with the approved specification. Firmware must not invent behavior absent from the specification.
