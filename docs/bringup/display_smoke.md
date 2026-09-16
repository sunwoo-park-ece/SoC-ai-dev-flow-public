# VGA / HEX / LED diagnostic firmware v1

Application: `firmware/apps/display_smoke.c`. FPGA RTL, pins and timing constraints are unchanged from the migrated baseline. Only the selected instruction/data memory images change. PLIC is not integrated.

## Visible behavior

1. HEX briefly shows `b00701` and all ten LEDs light during startup.
2. VGA shows `VGA HEX LED TEST V1`, STEP, expected HEX value, LED MASK, FRAME and ten LED boxes. The boxes represent LED0 through LED9 from left to right; a bottom checker pattern helps identify visible framebuffer output.
3. HEX repeats one hexadecimal digit across all six displays: `000000`, `111111`, ... `999999`, `AAAAAA`, ... `FFFFFF`, then wraps.
4. Steps 0–9 walk a single LED from LED0 to LED9. A/E light all LEDs, B/F turn all off, C/D alternate LED bits (`0x155` / `0x2AA`). The corresponding VGA boxes show the same pattern.

Step duration is set by a software delay loop and depends on CPU clock and pipeline execution. No UART/LoRa peer, ADC input, timer peripheral or interrupts are required. The frame is drawn into the back buffer and published with SWAP after a bounded VSYNC wait. Clearing is performed in software; this test does not exercise the hardware-clear engine used by the original demo.

## Diagnostic codes

| HEX5..HEX0 | Meaning |
|---|---|
| `b00701` briefly | Startup marker |
| `E1000n` | VSYNC flag did not arrive within the poll budget; n is step |
| `E2000n` | GPIO output register readback mismatch |
| `E3000n` | HEX value register readback mismatch |

The latter codes indicate software/register observations, not proof of physical pin operation. LED/HEX progression continues after a VSYNC timeout if MMIO accesses complete. A permanent startup marker means execution has not completed the first frame; report that separately from a displayed error code.

## Build

```bash
RUN_ROOT=/path/to/runs bash scripts/wsl/display_smoke_host_test.sh
RUN_ROOT=/path/to/runs bash scripts/firmware/build_fw.sh display_smoke
```

The first public source snapshot supports the host test and firmware build only. It does not publish an image-selection helper, a full vendor-build wrapper, a SOF, or a board-result record. Vendor regeneration and physical board acceptance therefore remain private/user-operated work and are not claimed as reproducible public evidence here.

The host test uses production GPIO/HEX/VGA/VRAM drivers with mocked MMIO and checks the 16 steps plus wrap, framebuffer bounds, SWAP-only operation, VSYNC timeout progress, and GPIO/HEX readback fault codes with address/undefined-behavior sanitizers. It does not simulate the CPU/RTL or replace board observation.

For a future board run, record whether the title appears, FRAME increments, HEX matches the displayed expected value, and physical LEDs match the ten boxes. Report any stable error code or the last visible step. No board result is included in this snapshot, and no root cause for the original demo's changed behavior is assumed by this diagnostic.
