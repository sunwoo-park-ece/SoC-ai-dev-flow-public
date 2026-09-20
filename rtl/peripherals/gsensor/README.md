# GSensor Publication Boundary

**Current Public integration state:** the P09B implementation described here is published with its matching source and documentation commits. Earlier A6/Stage 1/candidate wording below is historical provenance only; it does not limit the current implementation contract.

`APB_GSENSOR_MB.v` is project-authored APB/integration RTL and is public.

The historical lower-level `reset_delay`, `spi_controller`, `spi_ee_config`,
and `spi_param.h` sources correspond to modified Terasic DE10-Lite GSensor
reference code whose redistribution permission is too restrictive for this
public repository. They remain excluded and are classified `REPLACE`.

The current `reset_delay.v` and `spi_ee_config.v` are spec-driven project-owned
replacements. The latter integrates the dedicated SPI transport rather than
adding a generic SPI_MASTER or a copied `spi_param.h`. The active controller
uses one PCLK domain and a registered Mode-3 SCLK; it no longer instantiates
`spi_pll`. The historical private IP and public clock-model test remain
archived, not bound to this active build. See `docs/models/PORTABLE_MODEL_CONTRACTS.md`.

Historical Stage 1 was specification-only. The P09B paired publication update implements the 12-write 50 Hz/INT1 setup, 30 ms watchdog, LIVE/HOLD/SEQ/VALID registers and CPU-visible snapshot commands described in `spec/12_gsensor.md` and `spec/kor/12_gsensor.ko.md`. It becomes the Public source/documentation state only when the approved paired commits are published; before then pinned Public `main` is unchanged.

Reset wiring is also **historical A6 versus P09B publication update**: pinned A6 instantiated `reset_delay` after shared `PRESETn`, so initialization began after an extra 2^20 PCLK. The P09B implementation directly connects `spi_ee_config.iRSTN=PRESETn` and uses the same reset for banks/scheduler, with no second release timer. `reset_delay.v` is neither edited nor deleted. Scoped `GS-002` digital evidence supports full-byte XYZ extraction; the old inserted-zero Z algorithm belongs to historical reference code.

The wrapper is the only current production RTL instance found, but `verification/directed/models/gsensor/tb_gsensor_replacements.sv` directly instantiates `reset_delay`, and the module remains listed in `fpga/quartus/source_manifest.yml`, `verible.filelist`, and current test runners. Stage 2 must recheck these dependencies and request exact allowlist authority before changing a test or filelist; presence here is not permission to delete the module.
