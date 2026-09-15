# Representative verification

This preview includes a small set of readable, self-checking tests selected from the passing open regression. Vendor-IP simulation collateral and raw logs are intentionally omitted.

| Test | What it verifies | Self-checking? | Current result |
|---|---|---:|---:|
| `directed/cpu/tb_trap_precision_interaction.sv` | Precise trap, commit, stall, and competing-event ordering | Yes | PASS |
| `directed/bus/tb_ahb_apb_bridge_fault.sv` | APB decode, waits, invalid accesses, and AHB error response | Yes | PASS |
| `directed/bus/tb_p04_boardio.sv` | GPIO, switch, LED, and local IRQ MMIO integration | Yes | PASS |
| `directed/models/gsensor/tb_gsensor_single_pclk.sv` | Mode-3 SPI timing, transfers, polling, and interrupt behavior | Yes | PASS |
| `directed/reset_clock/tb_p05b_reset_adc_aux.sv` | Reset release, ADC command/reset boundary, and synchronized LoRa AUX input | Yes | PASS |

`models/memory/IMEM.sv` is included as the small public instruction-memory model used by CPU-level simulation.
