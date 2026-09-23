#include <stdint.h>

#include "hex_display.h"
#include "timer.h"
#include "uart.h"

/* At the 50 MHz baseline this is approximately 2.5 seconds plus loop overhead. */
#define HOLD_CYCLES 125000000u

/* Each packed field is {g,f,e,d,c,b,a}; the display outputs are active-low. */
static uint32_t pack_raw3(uint32_t hex0, uint32_t hex1, uint32_t hex2)
{
    return (hex0 & 0x7fu) | ((hex1 & 0x7fu) << 7) | ((hex2 & 0x7fu) << 14);
}

static void marker(const char *name)
{
    uart1_puts("S6_HEX:");
    uart1_puts(name);
    uart1_puts("\n");
}

static void marker_hex(const char *name, uint32_t value)
{
    uart1_puts("S6_HEX:");
    uart1_puts(name);
    uart1_puts(" 0x");
    uart1_put_hex32(value);
    uart1_puts("\n");
}

int main(void)
{
    const uint32_t raw_a_low = pack_raw3(0x7eu, 0x7du, 0x7bu);
    const uint32_t raw_a_high = pack_raw3(0x77u, 0x6fu, 0x5fu);
    /* B4 uses multi-segment active-low digit patterns 0,1,2,3,4,5. */
    const uint32_t raw_b_low = pack_raw3(0x40u, 0x79u, 0x24u);
    const uint32_t raw_b_high = pack_raw3(0x30u, 0x19u, 0x12u);

    /* Do not write a HEX register before this observation window. */
    marker("B0 RESET_EXPECTED_000000_OBSERVE");
    timer_delay_cycles(HOLD_CYCLES);

    /* Establish the documented driver shadow only after B0 was observable. */
    hex_display_init();
    hex_display_set_raw_mode(0);

    for (;;) {
        /* B6 leaves RAW mode enabled; restore decoder mode before each B1. */
        hex_display_set_raw_mode(0);
        marker_hex("B1 DECODER", 0x123456u);
        hex_display_write_value(0x123456u);
        timer_delay_cycles(HOLD_CYCLES);

        marker_hex("B2 DECODER", 0xabcdefu);
        hex_display_write_value(0xabcdefu);
        timer_delay_cycles(HOLD_CYCLES);

        marker_hex("B3 RAW_LOW", raw_a_low);
        marker_hex("B3 RAW_HIGH", raw_a_high);
        hex_display_write_raw(raw_a_low, raw_a_high);
        hex_display_set_raw_mode(1);
        timer_delay_cycles(HOLD_CYCLES);

        marker_hex("B4 RAW_LOW", raw_b_low);
        marker_hex("B4 RAW_HIGH", raw_b_high);
        hex_display_write_raw(raw_b_low, raw_b_high);
        timer_delay_cycles(HOLD_CYCLES);

        /* B5/B6 deliberately change only CTRL; B4 raw data is retained. */
        marker("B5 DISABLE_EXPECT_ALL_BLANK");
        hex_display_enable(0);
        timer_delay_cycles(HOLD_CYCLES);

        marker("B6 REENABLE_EXPECT_B4_RAW_RETENTION");
        hex_display_enable(1);
        timer_delay_cycles(HOLD_CYCLES);
    }
}
