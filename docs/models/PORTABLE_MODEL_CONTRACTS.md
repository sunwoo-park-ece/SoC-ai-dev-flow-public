# Portable Model and Replacement Contracts

Status: Phase 3 implementation contract. These models are project-owned and derived from the public SoC specifications and module interfaces. They are not copies of excluded vendor or reference HDL.

## Build profiles

- `OPEN_SIM` compiles public RTL, portable models, project-owned replacements, and a tool-appropriate AES integration. It must not compile vendor payload.
- `PRIVATE_QUARTUS` compiles the same project RTL but binds private Intel/Altera memories, PLLs, and `adc_qsys`. Portable model files are excluded.
- The dormant `system_pll` remains disabled. If enabled later, its contract is a private implementation clock generator whose public simulation substitute must expose the same ports and configured frequency.

## IMEM

Compatibility module: `IMEM`.

- 4096 words × 32 bits, addressed by a 12-bit word address.
- `address` is captured on a rising `clock` edge when `clken=1`; `q` reflects that captured word, giving the fetch path one-cycle synchronous behavior.
- `aclr` clears the captured address/output state, not the ROM array.
- Optional `INIT_FILE` is a plain text image with one hexadecimal 32-bit word per line; empty means NOP-filled (`0x00000013`). Quartus MIF is deliberately not accepted by this model.
- The model fatally rejects a missing explicitly requested file, invalid word, or more than 4096 words.

## DMEM

Compatibility module: `memory`.

- 8192 words × 32 bits; 13-bit word read/write addresses.
- Rising-edge writes, with `byteena_a[0]` mapping to bits 7:0 and `[3]` to bits 31:24.
- A rising edge with `rden=1` captures the addressed word into `q`; with `rden=0`, `q` holds.
- Deterministic same-edge same-address behavior is read-first: `q` observes the pre-write word. The AHB wrapper's explicit byte merge provides architectural store-to-load forwarding.
- Optional plain-text hexadecimal word image with the same diagnostics as IMEM; empty means zero initialized. Reset does not erase the array.

## VRAM

Compatibility module: `VRAM`.

- One 524,288-bit memory, viewed as 16,384 × 32 bits on the write port and 524,288 × 1 bit on the read port.
- `data[n]` written at word address `w` maps to bit address `{w,n}`; equivalently `memory[word_address][bit_index]`.
- Independent write/read clocks. The read address is sampled on `rdclock` and `q` is registered for one read-clock latency.
- `rd_aclr` clears only read-side output/address state and never scrubs storage.
- Cross-clock simultaneous access to the same word is not used as a portable data-coherency primitive; tests avoid collisions or synchronize at a higher layer.

## VGA clocks and timing

Compatibility clock module: `vga_pll`. In `OPEN_SIM`, it divides the 50 MHz input by two to model an approximately 25 MHz pixel clock. It is simulation/inference support, not a production PLL substitute. `PRIVATE_QUARTUS` binds the private PLL.

Project-owned replacement: `VGA_SyncGen`.

- Active-low reset `iRSTn`; counters update on `iPCLK`.
- Horizontal counter 0..799 and vertical counter 0..524.
- Visible window: horizontal 0..639 and vertical 0..479.
- Active-low HS over horizontal counts 656..751 (96 pixels).
- Active-low VS over vertical counts 490..491 (2 lines).
- `oVideoOn` is true only in the visible window. Counter outputs represent the pixel being evaluated in the current cycle.

## ADC

Compatibility module: `adc_qsys`.

- Functional command/response model only; it does not model MAX 10 analog conversion accuracy or physical timing.
- The public `clock_bridge_sys_out_clk_clk` follows `clk_clk` for a single deterministic simulation domain.
- Accepted command condition is `command_valid && command_ready`; SOP/EOP must accompany each single-beat command.
- Configurable fixed response latency, channel-preserving responses, and deterministic per-channel sample injection through parameters plus simulation tasks.
- Reset cancels pending responses and clears response-valid. Channels 1 and 2 have deterministic default samples.

## SPI clock and GSensor helpers

Historical compatibility clock module: `spi_pll`. Its open model remains for
the standalone clock-model regression, but the active single-PCLK G-sensor
controller no longer instantiates it. `PRIVATE_QUARTUS` no longer binds the
private SPI PLL QIP; the historical IP remains in the private vault.

Project-owned replacements retain the compatibility names `reset_delay` and `spi_ee_config` to avoid top-level churn.

- `reset_delay` asserts `oRST=1` when `iRSTN=0`, counts `2^DELAY_BITS` input-clock cycles after release, then deasserts without clearing external storage.
- The GSensor transport is dedicated ADXL345 four-wire SPI, not a generic APB SPI controller.
- SCLK idles high and transactions use mode 3 semantics: MOSI changes on the falling edge and MISO is sampled on the rising edge. Data is MSB first and CS is active low.
- Initialization performs the eleven writes defined by `spec/12_gsensor.md`, ending with `POWER_CTL=0x08`.
- Acquisition sends command `0xF2` (`read | multi-byte | DATAX0`) and receives DATAX0..DATAZ1. Outputs are little-endian 16-bit axis samples.
- A read begins from the configured interrupt input or a periodic fallback. The reset state drives CS high, SCLK high, MOSI low, and axis outputs zero.
- The controller updates/samples state on `iSPI_CLK` and gates the phase-related `iSPI_CLK_OUT` onto SCLK. The required phase relationship places the state/sample edge after the external rising edge and before the following falling launch edge.

## Diagnostics and non-goals

Models favor deterministic portable behavior. They do not claim cycle-exact analog behavior, PLL lock behavior, metastability, or undocumented vendor `DONT_CARE` collision semantics. Raw tool outputs belong under `$RUN_ROOT`.
