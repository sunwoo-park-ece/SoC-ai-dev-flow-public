# CPU Provenance

The CPU subsystem in this repository is based on the RV32I46F_5SP source from:

- Upstream: https://github.com/RISC-KC/basic_rv32s
- License: MIT License
- Copyright: Copyright (c) 2024 RISC-KC

This repository uses a locally modified and integrated variant of that CPU source for the FPGA SoC baseline.

Project-local work includes, among other changes:
- SoC/MMIO integration
- AHB-facing load/store interface adaptation
- pipeline/hazard behavior tuning
- FPGA BRAM-oriented memory-timing integration
- SoC-specific integration and architectural cleanup

Phase 3 local modification: `Register_File.v` uses a nonblocking assignment for
the clocked `debug_X4` update. This removes mixed blocking/nonblocking scheduling
semantics without changing the intended registered debug behavior.

The exact historical upstream import commit has not yet been reconstructed. The current license audit reviewed upstream `main` at commit `69f8f12cde96bbcbfbdf5f01dda8d4517d9fccca`; this is an audit reference, not a claim that the local CPU was originally imported from that exact revision.

For attribution and license details, see:

- [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md)
- [`licenses/RISC-KC-basic_rv32s-MIT.txt`](../../licenses/RISC-KC-basic_rv32s-MIT.txt)

The repository-level Apache License 2.0 does not replace the MIT license obligations that apply to the upstream-derived CPU material.
