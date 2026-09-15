# CPU Interface Contract

The CPU system-data boundary is the combination of `RV32I46F5SPMMIO` and `AHB_Master_Interface`. It is an AHB-Lite-derived project interface, not a claim of complete AMBA protocol compliance.

- EX-stage address/control initiates a load or store.
- Store data is aligned with the following bus data phase.
- `HSIZE` deterministically represents byte, halfword, or word transfers.
- `HREADY=0` freezes the required pipeline state until the transfer completes.
- A final ERROR response raises load/store access fault cause 5/7 with the faulting instruction PC in `mepc`.
- A failed load cannot update its destination register; a failed store cannot create the requested peripheral or memory side effect.
- Misaligned load/store causes 4/6 take priority over a downstream bus error.

The instruction-fetch path is local and does not use this system-data interface.
