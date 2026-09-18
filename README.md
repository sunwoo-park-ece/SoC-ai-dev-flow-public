# SoC AI Development Flow

This repository is the publishable source of truth for a personal FPGA SoC project. It contains specifications, project-authored RTL and firmware, redistributable third-party RTL with notices, portable verification sources, and reviewed reports.

The canonical engineering environment is WSL Ubuntu with Codex. RTL/firmware development, Verilator checks, vendor CLI invocation, ModelSim/XSim simulation, result analysis, and engineering-report generation originate there. Antigravity independently develops DV from the approved specifications. Windows Work consumes reviewed evidence for portfolio documents, PDF/PPT material, and interview preparation; it may assist with GUI-only vendor operations, but it is not the canonical build or engineering-report owner.

## Repository boundary

```text
$PUBLIC_REPO  publishable spec/RTL/FW/verification and reviewed reports
$VENDOR_ROOT private licensed/generated Quartus or Vivado project state
$RUN_ROOT    raw builds, logs, waves, reports, and temporary outputs
export/      reviewed artifacts intentionally handed to another environment
```

The private build relationship is:

```text
PUBLIC_REPO + PRIVATE_VENDOR_PROJECT + LOCAL_ENV + RUN_DIR
= PRIVATE FULL FPGA BUILD
```

The open-source relationship implemented in Phase 3 is:

```text
PUBLIC_REPO + PUBLIC BEHAVIORAL MODELS
= OPEN LINT / SIMULATION / ELABORATION
```

No complete vendor GUI project, generated vendor HDL, or vendor simulation collateral is published here. See [the FPGA boundary](fpga/README.md), [third-party notices](THIRD_PARTY_NOTICES.md), and [verification status](verification/README.md).

## Start here

- [Specifications](spec/README.md)
- [RTL](rtl/README.md)
- [Firmware](firmware/README.md)
- [Verification](verification/README.md)
- [Scripts](scripts/README.md)
- [Reports](reports/README.md)
- [Engineering case studies](docs/engineering/README.md)
- [Git workflow](docs/GIT_WORKFLOW.md)
- [Engineering roles](docs/AGENT_ROLES.md)
- [Current status](docs/status/current_status.md)
- [한국어 안내](README.ko.md)

## Current release status

This is an in-progress source snapshot, not Clean Baseline v1 and not a vendor-free FPGA bitstream build. The frozen P08B VGA functional scope (`VGA-001..006`) is owner accepted with directed RTL/DV and board-visible smoke evidence, while CDC/STA, warning, reset-window, programmer-identity, and release work remain open. The CPU trap-policy Gate 0 is a scoped pass only after the startup `mtvec` installation commits; the pre-`mtvec` reset window remains a known, unverified risk. See [current status](docs/status/current_status.md) and [CS-009](docs/engineering/CS-009-p08b-vga-hwclear-w1c.md).

CPU and AES-GCM open-source dependencies are present with their licenses. Public simulation models cover private Intel/Altera memories, PLLs and ADC IP, while project-owned replacements cover VGA sync and GSensor helpers. A disposable private Quartus build binds the same public RTL to private vendor IP. Benchmark and Dhrystone source files are intentionally excluded. Any later performance report must be separately reviewed and must distinguish official Dhrystone 2.1 from the project's Dhrystone-style workload. See [Quartus build profiles](fpga/quartus/README.md) and [model contracts](docs/models/PORTABLE_MODEL_CONTRACTS.md).

Project-authored material is licensed under [Apache License 2.0](LICENSE). Third-party files retain the licenses documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
