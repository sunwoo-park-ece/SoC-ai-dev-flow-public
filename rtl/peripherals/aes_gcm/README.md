# AES-GCM Core Provenance

The AES-GCM core used in this repository is based on:

- Upstream: https://github.com/BLu85/AES-GCM-128-192-256-bits
- License: Apache License 2.0
- Current upstream audit reference: `177e32a17ab06608870824df32be52ff65ed22e8`

The upstream project provides the AES-GCM cryptographic VHDL core. This SoC repository integrates that core with project-specific APB/MMIO control logic and firmware-visible register semantics.

Project-local integration includes:
- APB register/control wrapper logic
- SoC-level control and data-path integration
- firmware-visible programming model
- SoC-specific packet/header/transaction handling where implemented

During the 2026-09 license audit, multiple VHDL core files in this directory were confirmed to match the corresponding upstream Git blobs exactly. `apb_aes_gcm_ip.v` is treated as project-local SoC integration logic rather than an upstream AES-GCM source file.

For attribution and license details, see:

- [`THIRD_PARTY_NOTICES.md`](../../../THIRD_PARTY_NOTICES.md)
- [`licenses/BLu85-AES-GCM-Apache-2.0.txt`](../../../licenses/BLu85-AES-GCM-Apache-2.0.txt)

Third-party source remains subject to its upstream Apache License 2.0 terms, including preservation of applicable attribution and change notices for modified upstream files.
