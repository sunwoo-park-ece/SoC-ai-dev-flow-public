# Directed Verification

Focused checks live here. Phase 3 provides runnable memory (including AHB
read-first/byte-merged bypass), VGA, ADC,
GSensor and CPU tests, the existing AES-GCM APB wrapper timing test, and
`fpga/tb_open_soc_smoke.sv` for actual mixed-language SoC structural
elaboration. The obsolete `tb_AMBA_SoC_TOP.v` referenced top-level ports
that no longer exist and was removed; it is recoverable from the Phase 1/2
baseline. The new smoke intentionally does not claim firmware or full-SoC
functional verification.

Testbench memory-image parameters default to an empty value so they do not contain a machine-specific path. Callers may provide a repository-relative or explicit configuration path.

Open simulation uses portable public models; private Quartus binds the actual
vendor memories, PLLs and ADC IP. Expected tool/model limitations must be
separated from parser, protocol, or logic failures.
