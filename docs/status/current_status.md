# Current Public Status

- Public source revision: `f28e95df2eafcb939e04ffaca728c44f74c90612`
- Baseline cleanup: **IN PROGRESS**
- P08B VGA functional scope (`VGA-001..006`): **OWNER ACCEPTED / VERIFIED**
- Clean Baseline release: **NOT RELEASED**
- Vendor/board acceptance: **NOT CLAIMED BY THIS SNAPSHOT**

The source revision above is the frozen P08B source snapshot. The VGA acceptance is functional scope only; it does not redefine release identity or claim CDC/STA sign-off.

CPU precise store-access-fault handling is **PASS**: the faulting store raises `mcause = 7` with `mepc = 0x00000008`, does not retire normally, and no younger `x3` commit occurs. The firmware safe trap endpoint is **BLOCKED** because the current default trap vector is incompatible with the tested 16 KiB instruction-memory alias behavior. The detector exits successfully when it reproduces that incompatibility; it does not establish a safe boot/runtime endpoint. P08B must remain stopped until the architecture/firmware decision is approved and implemented.

P08B board-visible smoke evidence is published with the exact-count RTL/DV distinction in [CS-009](../engineering/CS-009-p08b-vga-hwclear-w1c.md). `CDC-001` remains unresolved/not run for static sign-off, `STA-001` is in progress, `STA-002` is blocked, two VGA/ADC warnings remain open, the reset window is a known risk, and programmer identity was not captured. Other ADC, G-sensor, HEX, firmware, STA, and board work also prevents release closure. Consult `spec/baseline_cleanup.md` for authoritative item-level status.

Benchmark and Dhrystone source files are intentionally absent from the first snapshot. Any later performance report will be reviewed and published separately with explicit methodology and terminology.
