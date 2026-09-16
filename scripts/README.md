# Scripts

Scripts in this directory are public automation building blocks. They must accept repository-relative paths or explicit variables and write generated output under `$RUN_ROOT`.

Current disposition:

| Area | Disposition | Notes |
|---|---|---|
| `firmware/build_fw.sh`, MIF converters | KEEP | firmware build/conversion helpers; generated files remain outside Git |
| `analysis/` | KEEP | text and waveform analysis helpers |
| `serial/` | KEEP | host-side serial utilities |
| `wsl/display_smoke_host_test.sh` | KEEP | host smoke-test entry point |
| AES wrapper timing run script | KEEP | focused directed check with corrected public RTL path |
| old firmware image selector | REWRITE_PHASE3 | removed; it mixed public source with private generated memory state |
| old Quartus build entry point | REWRITE_PHASE3 | removed; it required the absent private project layout |
| old legacy regression | ARCHIVE | excluded because it targets the private historical snapshot |
| `wsl/open_sim.sh` | KEEP | Verilator, Icarus directed tests, focused AES APB test, GHDL analysis |
| `wsl/modelsim_mixed.sh` | KEEP | actual VHDL AES + Verilog SoC structural smoke |
| `wsl/private_quartus.py` | KEEP | disposable run-directory project consuming public RTL and private QIPs |

No removed legacy command is claimed to work in this public candidate. The private build inputs are this public checkout, `$VENDOR_ROOT`, local tool configuration, and a fresh `$RUN_ROOT` directory. See [Quartus instructions](../fpga/quartus/README.md).
