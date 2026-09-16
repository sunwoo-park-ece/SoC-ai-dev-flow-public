# Current Public Status

- Public source revision: `2e681084c6e58578354734b1c88afb65aa5937c5`
- Baseline cleanup: **IN PROGRESS**
- P08B VGA implementation: **NOT STARTED — GATE 0 STOP**
- Clean Baseline release: **NOT RELEASED**
- Vendor/board acceptance: **NOT CLAIMED BY THIS SNAPSHOT**

The source revision above is Source Commit 1: the exact source snapshot exercised by the Gate 0 evidence. This status document is an evidence-layer update and does not redefine that source identity.

CPU precise store-access-fault handling is **PASS**: the faulting store raises `mcause = 7` with `mepc = 0x00000008`, does not retire normally, and no younger `x3` commit occurs. The firmware safe trap endpoint is **BLOCKED** because the current default trap vector is incompatible with the tested 16 KiB instruction-memory alias behavior. The detector exits successfully when it reproduces that incompatibility; it does not establish a safe boot/runtime endpoint. P08B must remain stopped until the architecture/firmware decision is approved and implemented.

Phase 4A has accumulated focused open-simulation and selected vendor-build evidence, but remaining VGA, ADC, G-sensor, HEX, firmware, STA, and board acceptance work prevents release closure. Consult `spec/baseline_cleanup.md` for authoritative item-level status.

Benchmark and Dhrystone source files are intentionally absent from the first snapshot. Any later performance report will be reviewed and published separately with explicit methodology and terminology.
