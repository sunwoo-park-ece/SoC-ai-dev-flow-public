# SoC Architecture

The current public baseline targets the DE10-Lite MAX 10 device and integrates a five-stage RV32I CPU, local instruction memory, a single-master project AHB-style data path, and an APB peripheral subsystem. The external system clock is 50 MHz.

```text
RV32I CPU + local IMEM
          |
    AHB master interface
          |
  +-------+--------+----------------+
  |                |                |
DMEM          VGA / VRAM       AHB-APB bridge
                                    |
                                   APB
```

Instruction fetch does not traverse the system data bus. Load/store operations reach the 32 KiB DMEM, the VGA framebuffer/control region, or one of the APB slots. The bus is single-master and uses single transfers; caches, arbitration, DMA, AXI, and an active PLIC are outside this baseline.

The APB subsystem integrates two UARTs, bidirectional GPIO, a timer, a G-sensor SPI controller, AES-GCM, ADC joystick control, HEX display, switches, and LEDs. VGA and ADC integration retain vendor-IP boundaries; generated vendor payload is not part of this public preview.
