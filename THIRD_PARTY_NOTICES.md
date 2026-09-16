# Third-Party Notices

This repository combines project-authored material with redistributable open-source components. Project-authored material is covered by the repository-level Apache License 2.0 unless stated otherwise; third-party components retain their original licenses.

## RISC-KC/basic_rv32s

- Upstream: https://github.com/RISC-KC/basic_rv32s
- Audit reference: `69f8f12cde96bbcbfbdf5f01dda8d4517d9fccca`
- License: MIT
- Copyright: Copyright (c) 2024 RISC-KC
- Local location: `rtl/core/v/**`, `rtl/core/vh/**`
- License copy: `licenses/RISC-KC-basic_rv32s-MIT.txt`

The local CPU is derived from the upstream RV32I46F_5SP design. Eleven files were byte-identical to the audit reference; the remaining CPU RTL/header files were locally modified, adapted, or added within that derivative core for SoC/AHB, memory timing, pipeline, hazard, exception, and integration needs. `rtl/core/README.md` is project documentation.

The source was introduced before this project's available Git/GitHub history. Therefore, the exact historical import revision is unavailable. The named revision is a provenance comparison reference, not a claim that it was the original import commit. Upstream identity, the matching MIT license, file structure, and source correspondence support redistribution with this notice.

## BLu85/AES-GCM-128-192-256-bits

- Upstream: https://github.com/BLu85/AES-GCM-128-192-256-bits
- Audit reference: `177e32a17ab06608870824df32be52ff65ed22e8`
- License: Apache License 2.0
- Local location: `rtl/peripherals/aes_gcm/pipe0/`
- License copy: `licenses/BLu85-AES-GCM-Apache-2.0.txt`

Ten VHDL files match upstream `src/` files at the audit reference byte-for-byte:

`aes_enc_dec_ctrl.vhd`, `aes_func.vhd`, `aes_gcm.vhd`, `aes_icb.vhd`, `aes_last_round.vhd`, `aes_pkg.vhd`, `gcm_gctr.vhd`, `gcm_ghash.vhd`, `gcm_pkg.vhd`, and `ghash_gfmul.vhd`.

Four VHDL files—`aes_ecb.vhd`, `aes_kexp.vhd`, `aes_round.vhd`, and `top_aes_gcm.vhd`—correspond to files produced/configured by the upstream project's generator flow and are published as upstream-derived/configured files under Apache-2.0. The project-authored `apb_aes_gcm_ip.v` wrapper and `rtl/peripherals/aes_gcm/README.md` are not represented as upstream core files.

This source also predates the available project Git history, so the exact historical import revision is unavailable. The official upstream identity, exact license match, byte-identical file subset, generator correspondence, and consistent headers support redistribution with this notice.

## Intentionally Excluded External and Vendor Material

The following dependencies are not redistributed in this repository:

- Terasic DE10-Lite GSensor reference helpers corresponding to `reset_delay`, `spi_controller`, `spi_ee_config`, and `spi_param.h`; their redistribution terms do not support inclusion here. The project-authored APB wrapper remains public, and clean replacements are planned.
- An externally sourced VGA synchronization generator whose upstream identity and redistribution license could not be established. A clean replacement is planned.
- Intel/Altera-generated memories, PLLs, Platform Designer ADC IP, complete Quartus projects, generated HDL, and simulator collateral. These remain private vendor dependencies.

Their absence does not change the ownership of project-authored wrappers and controllers. See `fpga/quartus/ip_manifest.yml` for the public/private interface boundary.

## Notice Boundary

No repository-level license overrides third-party terms. Source and corresponding license/notice material must remain together when redistributed. Audit-reference URLs and revisions were accessed for the Phase 2 review on 2026-09-12.
