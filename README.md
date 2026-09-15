# RISC-V SoC on FPGA

**Status: Portfolio Preview**
**Release: v0.1-portfolio-preview**

FPGA-oriented RV32I SoC project integrating a 5-stage CPU, an AHB-Lite-derived/APB interconnect, memory-mapped peripherals, directed self-checking verification, and Quartus/TimeQuest implementation.

## Architecture

```text
                         RV32I 5-stage CPU
                         /               \
                 local IMEM        project AHB-style bus
                                      /      |      \
                               32 KiB DMEM  VRAM   AHB-APB bridge
                                                     |
                                                    APB
                +----------+----------+----------+----------+
                | UART0    | GPIO     | Timer    | G-sensor |
                | AES-GCM  | ADC      | UART1    | HEX      |
                | SW       | LED      |          |          |
                +----------+----------+----------+----------+
```

The active baseline is a single-master SoC. Instruction fetch uses local memory; CPU load/store traffic reaches DMEM, the VGA framebuffer, and APB peripherals through the project AHB-style data path. No PLIC, AXI fabric, DMA, or cache is claimed as implemented.

## Engineering highlights

- RV32I five-stage pipeline integration with hazards, forwarding, stalls, and precise synchronous trap handling
- Single-master AHB-Lite-derived data fabric and AHB-to-APB bridge with deterministic error paths
- Memory-mapped UART, GPIO, timer, G-sensor SPI, VGA, ADC, AES-GCM, switches, LEDs, and HEX display
- Commit-qualified architectural side effects and `minstret` accounting
- Directed, self-checking, regression-based verification including negative/error-path cases
- Reset release and asynchronous-input synchronization across system, VGA, and ADC boundaries
- Quartus FPGA implementation and TimeQuest static timing analysis on DE10-Lite

## Authorship and provenance

Project-owned SoC integration, peripheral wrappers/controllers, reset infrastructure, and verification are kept distinct from third-party-derived components. The CPU and AES-GCM derivations and their licenses are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Intel/Altera-generated IP and private Quartus projects are intentionally omitted; public RTL keeps only authored integration boundaries.

## Verification

Verification combines directed scenarios, self-checking scoreboards, regression suites, and negative/error-path testing. The currently reviewed source-level P05B result is:

| Suite | Reviewed result |
|---|---:|
| Focused P05B reset/clock/async-input lanes | 3/3 PASS |
| Canonical open regression lanes | 22/22 PASS |
| CPU/AHB/APB/P04 regression lanes | 7/7 PASS |

Representative readable tests are included under `verification/`; raw run artifacts are omitted. **P05B vendor post-fit validation is pending.**

## FPGA and STA

| Item | Latest reviewed result |
|---|---:|
| Board / FPGA | DE10-Lite / MAX 10 |
| Tool | Quartus Prime 19.1 |
| FPGA checkpoint | P04 |
| Compile / Fit | PASS |
| Logic elements | 31,949 |
| Registers | 6,435 |
| Memory bits | 1,442,048 |
| Pins | 106 |
| PLLs | 2 |
| Slow 85C setup WNS | +0.542 ns |
| Worst reviewed hold slack | +0.093 ns |
| Constrained setup/hold TNS | 0 |

These figures describe the reviewed P04 post-fit checkpoint. External I/O timing/electrical closure and final Clean Baseline validation are still in progress.

## AI-assisted workflow

AI tools are used as engineering assistants for specification review, RTL implementation support, regression planning, and evidence reconciliation. Architecture decisions and acceptance gates remain explicit engineering review points.

## Current status

- Portfolio Preview
- Current P05B RTL/open verification: **PASS**
- Latest reviewed FPGA post-fit checkpoint: **P04 PASS**
- P05B Quartus post-fit validation: **pending**
- Clean Baseline v1: **in progress**

## Repository scope

This preview intentionally omits vendor-generated IP, private Quartus project files, firmware, raw run artifacts, internal migration/task records, and unreleased provenance-sensitive material. It is a recruitment preview, not the final Clean Baseline v1 release.
