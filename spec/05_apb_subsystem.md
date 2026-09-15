# APB Subsystem Contract

`AHB_APB_bridge` converts one accepted AHB request into APB SETUP and ACCESS phases. APB currently shares the 50 MHz system clock.

- Request address and controls remain stable through ACCESS and any `PREADY` wait.
- Completing `PSLVERR` propagates as the project AHB ERROR response.
- Alignment, transfer-size, canonical-offset, and slot validation occur before a real peripheral select is asserted.
- `PSEL[15:0]` decodes slots 0–15; slots 0–9 are implemented and slots 10–15 are reserved/error.
- Invalid requests do not assert a real peripheral select and cannot create a peripheral side effect.

| Slot | Peripheral |
|---:|---|
| 0 | UART0 / LoRa |
| 1 | 16-bit bidirectional GPIO |
| 2 | Timer |
| 3 | G-sensor SPI |
| 4 | AES-GCM |
| 5 | ADC joystick |
| 6 | UART1 / PC |
| 7 | HEX display |
| 8 | Switch input |
| 9 | LED output |
