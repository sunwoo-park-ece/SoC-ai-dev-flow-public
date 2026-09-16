#include <stdint.h>

#include "led.h"
#include "hex_display.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"
#include "timer.h"
#include "vga_text.h"
#include "vram.h"

/* No UART peer, ADC samples, timer peripheral or interrupts are required. */
#define VSYNC_POLL_LIMIT 1000000u

static uint32_t hex_pattern(uint32_t step)
{
    return step | (step << 4) | (step << 8) | (step << 12) |
           (step << 16) | (step << 20);
}

static uint32_t led_pattern(uint32_t step)
{
    if (step < 10u) return 1u << step;
    if (step == 10u || step == 14u) return 0x3ffu;
    if (step == 12u) return 0x155u;
    if (step == 13u) return 0x2aau;
    return 0u;
}

static void draw_frame(uint32_t step, uint32_t leds, uint32_t frame)
{
    uint32_t i, x, y;
    /* Clear the back buffer in software, isolating the hardware-clear engine. */
    for (i = 0u; i < 9600u; ++i) vram_write_word(i, 0u);
    vga_text_puts(1u, 24u, "VGA HEX LED TEST V1");
    vga_text_puts(1u, 48u, "AUTOMATIC 16 STEP SCAN");
    vga_text_puts(1u, 80u, "STEP");
    vga_text_put_hex8(5u, 80u, (uint8_t)step);
    vga_text_puts(1u, 104u, "HEX EXPECT LAST SIX DIGITS");
    vga_text_put_hex32(9u, 104u, hex_pattern(step));
    vga_text_puts(1u, 128u, "LED MASK");
    vga_text_put_hex16(5u, 128u, (uint16_t)leds);
    vga_text_puts(1u, 152u, "FRAME");
    vga_text_put_hex32(5u, 152u, frame);
    vga_text_puts(1u, 184u, "LED0 TO LED9 LEFT TO RIGHT");
    for (x = 0u; x < 10u; ++x) {
        for (y = 208u; y < 240u; ++y) {
            uint32_t pixels = (leds & (1u << x)) ? 0x3ffffffcu : 0x20000004u;
            if (y == 208u || y == 239u) pixels = 0x3ffffffcu;
            vram_write_word(y * 20u + x + 1u, pixels);
        }
    }
    vga_text_puts(1u, 272u, "HEX 000000 TO FFFFFF THEN REPEAT");
    vga_text_puts(1u, 296u, "LED WALK ALL OFF ALTERNATE");
    vga_text_puts(1u, 320u, "NO LORA OR ADC INPUT REQUIRED");
    for (y = 376u; y < 408u; ++y) {
        for (x = 1u; x < 19u; ++x) {
            vram_write_word(y * 20u + x, ((x ^ (y >> 3)) & 1u) ? 0xffffffffu : 0u);
        }
    }
}

static int present_frame(void)
{
    uint32_t tries;
    vram_clear_vsync();
    for (tries = 0u; tries < VSYNC_POLL_LIMIT; ++tries) {
        if ((vram_status() & VRAM_STATUS_VSYNC) != 0u) {
            /* Publish the complete back buffer without starting hardware clear. */
            mmio_write32(VRAM_BASE + VRAM_CONTROL, VRAM_CTRL_SWAP);
            return 1;
        }
    }
    return 0;
}

int main(void)
{
    uint32_t step = 0u, frame = 0u;
    hex_display_enable(1);
    hex_display_set_raw_mode(0);
    hex_display_write_value(0xb00701u);
    led_write(0x3ffu);
    timer_delay_cycles(1500000u); /* Software loop; duration is clock dependent. */
    for (;;) {
        uint32_t leds = led_pattern(step);
        uint32_t value = hex_pattern(step);
        draw_frame(step, leds, frame);
        if (!present_frame()) value = 0xe10000u | step;
        led_write(leds);
        hex_display_write_value(value);
        /* Register readback is diagnostic only; physical outputs need observation. */
        if (led_read() != leds) hex_display_write_value(0xe20000u | step);
        else if (hex_display_read_value() != value) hex_display_write_value(0xe30000u | step);
        timer_delay_cycles(1500000u);
        step = (step + 1u) & 0x0fu;
        ++frame;
    }
}
