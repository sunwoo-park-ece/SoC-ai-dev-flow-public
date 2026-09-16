# GSensor Publication Boundary

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
