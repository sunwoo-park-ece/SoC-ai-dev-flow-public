# SoC Memory Map

The SoC uses a 32-bit, byte-addressed, little-endian address space. Only the ranges below are canonical; aliases and reserved addresses must not be used by software.

| Range / base | Resource | Notes |
|---|---|---|
| `0x0000_0000–0x0000_3FFF` | IMEM | 16 KiB, CPU-local instruction path |
| `0x1000_0000–0x1000_7FFF` | DMEM | 32 KiB data memory |
| `0x2000_0000–0x2000_95FF` | VGA back buffer | 640×480, 1 bit/pixel |
| `0x2001_0000` | VGA status | Status / W1C bit |
| `0x2001_0004` | VGA control | Swap / clear control |
| `0x4000_0000` | UART0 | LoRa-facing UART |
| `0x4001_0000` | GPIO | 16-bit bidirectional external GPIO |
| `0x4002_0000` | Timer | Polling timer |
| `0x4003_0000` | G-sensor | ADXL345/SPI control and samples |
| `0x4004_0000` | AES-GCM | Crypto accelerator wrapper |
| `0x4005_0000` | ADC joystick | MAX 10 ADC integration |
| `0x4006_0000` | UART1 | PC-facing UART |
| `0x4007_0000` | HEX | Six-digit seven-segment display |
| `0x4008_0000` | SW | Dedicated switch input |
| `0x4009_0000` | LED | Dedicated LED output |
| `0x400A_0000–0x400F_FFFF` | Reserved | Returns the project error response |

Unmapped AHB addresses, noncanonical APB offsets, reserved slots, and unsupported transfer sizes return an error. Framebuffer data accesses are naturally aligned 32-bit writes; framebuffer reads and subword writes fault.
