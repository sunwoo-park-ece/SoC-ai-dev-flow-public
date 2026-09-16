#include <stdint.h>

#include "hex_display.h"
#include "timer.h"
#include "uart.h"

static uint32_t pack_raw3(uint32_t hex0, uint32_t hex1, uint32_t hex2)
{
    return (hex0 & 0x7fu) | ((hex1 & 0x7fu) << 7) | ((hex2 & 0x7fu) << 14);
}

int main(void)
{
    uint32_t value = 0u;

    uart1_puts("\n=== APB HEX display test ===\n");
    uart1_puts("HEX5..HEX0 default decoder test, then raw segment blink.\n");

    hex_display_enable(1);
    hex_display_set_raw_mode(0);

    for (;;) {
        hex_display_write_monitor(1u,
                                  (uint8_t)((value >> 16) & 0x0fu),
                                  (uint8_t)((value >> 12) & 0x0fu),
                                  (uint8_t)((value >> 8) & 0x0fu),
                                  (uint8_t)((value >> 4) & 0x0fu),
                                  (uint8_t)(value & 0x0fu));

        if ((value & 0x0fu) == 0u) {
            uart1_puts("hex value=");
            uart1_put_hex32(hex_display_read_value());
            uart1_puts("\n");
        }

        timer_delay_cycles(5000000u);
        value = (value + 1u) & 0x00ffffffu;

        if ((value & 0xffu) == 0u) {
            hex_display_write_raw(pack_raw3(0x00u, 0x00u, 0x00u),
                                  pack_raw3(0x00u, 0x00u, 0x00u));
            hex_display_set_raw_mode(1);
            timer_delay_cycles(10000000u);
            hex_display_set_raw_mode(0);
        }
    }
}
