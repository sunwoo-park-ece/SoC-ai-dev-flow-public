# Portfolio specification set

This directory contains a compact current-state snapshot of the public SoC contract. It intentionally omits cleanup trackers, governance, release planning, and historical migration material.

| Document | Scope |
|---|---|
| `00_soc_architecture.md` | Top-level SoC organization |
| `01_memory_map.md` | Canonical address allocation |
| `03_cpu_interface.md` | CPU-to-system-data-bus contract |
| `04_ahb_fabric.md` | AHB-style decode, response, and error behavior |
| `05_apb_subsystem.md` | APB bridge and peripheral slots |
| `07_interrupt_architecture.md` | Implemented synchronous traps and deferred interrupt scope |
| `21_cpu_core.md` | Five-stage CPU microarchitecture contract |

These portfolio copies preserve the canonical filenames while removing internal project-history prose. Detailed register-level peripheral specifications remain outside this preview.
