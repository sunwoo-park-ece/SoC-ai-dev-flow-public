# FPGA Boundary

Public FPGA content captures design intent and reproducible bindings without publishing complete vendor-generated project state.

- [Quartus boundary and current status](quartus/README.md)
- [Quartus IP manifest](quartus/ip_manifest.yml)
- [Quartus source manifest](quartus/source_manifest.yml) and [build profiles](quartus/build_profiles.json)
- [DE10-Lite timing constraint](quartus/constraints/de10_lite.sdc)
- [DE10-Lite pin intent](quartus/constraints/de10_lite_pins.tcl)
- [Vivado boundary](vivado/README.md)

The complete vendor project, generated HDL, Qsys/Platform Designer collateral, simulator setup files, and raw outputs remain under `$VENDOR_ROOT` or `$RUN_ROOT`. Phase 3 added public simulation substitutes and variable-driven build entry points. A private Quartus full compile still requires the private IP vault; this tree does not claim a vendor-free FPGA build.
