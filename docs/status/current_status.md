# Current Public Status

- Public source revision: `PENDING_PUBLIC_COMMIT`
- Baseline cleanup: **IN PROGRESS**
- P08B VGA implementation: **NOT STARTED — GATE 0 STOP**
- Clean Baseline release: **NOT RELEASED**
- Vendor/board acceptance: **NOT CLAIMED BY THIS SNAPSHOT**

The CPU hardware path passes the focused trap-policy detector, but the current default firmware trap-vector endpoint is incompatible with the tested 16 KiB instruction-memory alias behavior. The detector exits successfully when it reproduces that incompatibility; it does not establish a safe boot/runtime endpoint. P08B must remain stopped until the architecture/firmware decision is approved and implemented.

Phase 4A has accumulated focused open-simulation and selected vendor-build evidence, but remaining VGA, ADC, G-sensor, HEX, firmware, STA, and board acceptance work prevents release closure. Consult `spec/baseline_cleanup.md` for authoritative item-level status.

Benchmark and Dhrystone source files are intentionally absent from the first snapshot. Any later performance report will be reviewed and published separately with explicit methodology and terminology.
