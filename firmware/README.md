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

The standalone health application skeleton is `apps/soc_health_main.c`, governed by [SoC health firmware contract and reconciliation tracker](../spec/22_soc_health_firmware.md) and its [Korean companion](../spec/kor/22_soc_health_firmware.ko.md). S2 implements the app, reusable `services/` layer, header, immutable double-buffered snapshot, bounded observer/provider skeletons and build integration. Build it with `RUN_ROOT=<external-directory> scripts/firmware/build_fw.sh soc_health_main`; run host checks with `RUN_ROOT=<fresh-external-directory> scripts/wsl/soc_health_host_test.sh`. The S2 skeleton performs no MMIO: peripheral placeholders remain UNKNOWN, AES remains EXCLUDED, and only software service progress qualifies. Host tests and an actual RV32I build pass; physical providers/output and board acceptance remain deferred to S3/S4. After Issue #7 completion/review, it replaces `final_main` as the Issue #6 C4-A/C4-B firmware basis; C4 remains paused pending the later stage gates.

The health contract excludes AES-GCM as `EXCLUDED_PENDING_CLEANUP`. UART0 TX → UART1 RX and GPIO0 → GPIO1 require physical jumpers; UART1 TX observes the same frozen snapshot as VGA and never qualifies the UART heartbeat. SW mirrors LED, and SW selects the HEX dual-mode board test. Service builds retain RV32I/ILP32, 16 KiB IMEM/32 KiB DMEM and external RUN_ROOT. Broad per-IP spec/FW reconciliation debt belongs in spec 22 until the later coordinated cleanup pass.

Benchmark and Dhrystone application sources are intentionally excluded from this public snapshot. `dhrystone_main` and `dhrystone_t410n` are not supported build targets, and the project-specific `benchmark_main` workload is not published. Any later performance report is a separately reviewed derivative and must not describe the project's Dhrystone-style case as official Dhrystone 2.1.

For each peripheral, keep the register map, C header/driver, smoke test, and RTL aligned with the approved specification. Firmware must not invent behavior absent from the specification.
