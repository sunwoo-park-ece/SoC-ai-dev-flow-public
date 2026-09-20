# Current Public Status

- Public `main` revision (remote-read, 2026-09-21): `fe2daa7a0734b396cb4a56c5b97a40a9c0df8116`
- Frozen P08B source snapshot: `f28e95df2eafcb939e04ffaca728c44f74c90612`
- Baseline cleanup: **IN PROGRESS**
- P08B VGA functional scope (`VGA-001..006`): **OWNER ACCEPTED / VERIFIED**
- Clean Baseline release: **NOT RELEASED**
- Vendor/board acceptance: **NOT CLAIMED BY THIS SNAPSHOT**

The frozen P08B snapshot is distinct from the current Public `main` revision above. The VGA acceptance is functional scope only; it does not redefine release identity or claim CDC/STA sign-off.

CPU precise store-access-fault handling is **PASS**: the faulting store raises `mcause = 7` with `mepc = 0x00000008`, does not retire normally, and no younger `x3` commit occurs. The earlier Gate 0 detector showed that reset-default `mtvec = 0x00006d60` lay outside canonical 16 KiB instruction memory; that detector result is historical pre-fix evidence, not the current endpoint status. Frozen [startup code](../../firmware/bsp/start.S) installs the in-range `__trap_entry` before stack, BSS, application, or VGA MMIO work and routes traps to terminal `__trap_fail_stop`. Gate 0 is therefore **SCOPED PASS only after the startup `mtvec` write commits**. Before that commit, `RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT` remains a **KNOWN RISK / OPEN** interval; safe trapping from the first reset fetch and general CPU/firmware sign-off are not claimed. See the [interrupt](../../spec/07_interrupt_architecture.md) and [firmware](../../spec/19_firmware_contract.md) contracts for the bounded policy.

P08B board-visible smoke evidence is published with the exact-count RTL/DV distinction in [CS-009](../engineering/CS-009-p08b-vga-hwclear-w1c.md); the photographs support only bounded visible transitions. `VGA-007` remains open, `CDC-001` remains unresolved/not run for static sign-off, `STA-001` is in progress with internal `SCOPED_PASS` only, `STA-002` is blocked, two VGA/ADC warnings remain open, the pre-`mtvec` reset window remains a known risk, and independent programmer/JTAG identity was not captured. Other ADC, G-sensor, HEX, firmware, STA, and board work also prevents release closure. Consult [the cleanup tracker](../../spec/baseline_cleanup.md) for authoritative item-level status.

Benchmark and Dhrystone source files are intentionally absent from the first snapshot. Any later performance report will be reviewed and published separately with explicit methodology and terminology.

P09B Public integration is implemented by the paired source and documentation commits containing this update; the repository Git history is the authoritative revision record, so this self-referential document does not guess a commit SHA. It implements the 12-write 50 Hz/INT1 sequence, 30 ms watchdog, LIVE/HOLD snapshot ABI, direct shared `PRESETn`, firmware lifecycle and focused/CPU/host checkers. Private fit/STA evidence and a board-display observation remain scoped evidence only. `STA-002`, external timing/electrical, physical INT1/orientation/calibration, Stage 3 deferred work, unexpected-APB fatal negative branch and delayed trap-side-effect checks remain open or NOT_RUN. Publication does not grant tracker VERIFIED, release, or board acceptance.
