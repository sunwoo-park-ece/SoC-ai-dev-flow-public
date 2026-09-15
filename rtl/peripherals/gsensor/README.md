# G-sensor publication boundary

`APB_GSENSOR_MB.v`, `reset_delay.v`, and `spi_ee_config.v` are project-authored RTL. The active controller uses one PCLK domain and a registered Mode-3 SPI clock.

Historical Terasic reference helpers and private vendor PLL material are intentionally excluded. Their names do not identify the current project-authored replacements as vendor-generated code.
