#include <assert.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include "soc_memory_map.h"

int display_smoke_entry(void);
static jmp_buf done;
static uint32_t hex, leds, hex_ctrl;
static unsigned scenario, delays, swaps, writes, reads, frames;
static const uint32_t expected_leds[16] = {
    1, 2, 4, 8, 16, 32, 64, 128, 256, 512,
    0x3ff, 0, 0x155, 0x2aa, 0x3ff, 0
};
static const uint32_t expected_hex[16] = {
    0x000000, 0x111111, 0x222222, 0x333333,
    0x444444, 0x555555, 0x666666, 0x777777,
    0x888888, 0x999999, 0xaaaaaa, 0xbbbbbb,
    0xcccccc, 0xdddddd, 0xeeeeee, 0xffffff
};

void mmio_write8(uint32_t addr, uint8_t value)
{
    (void)addr;
    (void)value;
    assert(!"unexpected byte write");
}

uint32_t mmio_read32(uint32_t addr)
{
    if (addr == VRAM_BASE + VRAM_STATUS) {
        ++reads;
        return scenario == 1 ? 0u : 1u;
    }
    if (addr == LED_BASE + LED_DATA) return leds ^ (scenario == 2 ? 1u : 0u);
    if (addr == HEX_DISPLAY_BASE + HEX_VALUE) return hex ^ (scenario == 3 ? 1u : 0u);
    assert(!"unexpected MMIO read");
    return 0;
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    if (addr >= VRAM_BASE && addr < VRAM_BASE + 9600u * 4u) {
        assert((addr & 3u) == 0u);
        /* Each frame must begin by clearing every framebuffer word in order. */
        if (writes < 9600u) {
            assert(addr == VRAM_BASE + writes * 4u);
            assert(value == 0u);
        }
        ++writes;
    } else if (addr == VRAM_BASE + VRAM_STATUS) {
        assert(value == 1u);
        assert(writes > 9600u);
        ++frames;
    } else if (addr == VRAM_BASE + VRAM_CONTROL) {
        assert(value == 1u); /* SWAP only: hardware clear must stay disabled. */
        assert(scenario != 1);
        ++swaps;
    } else if (addr == LED_BASE + LED_DATA) leds = value;
    else if (addr == HEX_DISPLAY_BASE + HEX_VALUE) hex = value;
    else if (addr == HEX_DISPLAY_BASE + HEX_CTRL) hex_ctrl = value;
    else assert(!"unexpected MMIO write or framebuffer overrun");
}

void timer_delay_cycles(uint32_t cycles)
{
    (void)cycles;
    if (delays == 0) {
        assert(hex == 0xb00701u && leds == 0x3ffu);
    } else {
        unsigned step = (delays - 1u) & 15u;
        assert(hex_ctrl == 1u);
        assert(leds == expected_leds[step]);
        assert(hex == (scenario == 0 ? expected_hex[step] :
                       (0xe00000u | (scenario << 16) | step)));
        assert(frames == delays);
        assert(swaps == (scenario == 1 ? 0u : delays));
        assert(reads > 0);
        writes = reads = 0;
    }
    if (++delays == 18u) longjmp(done, 1); /* Includes wrap from F back to 0. */
}

int main(void)
{
    for (scenario = 0; scenario < 4; ++scenario) {
        hex = leds = hex_ctrl = 0;
        delays = swaps = writes = reads = frames = 0;
        if (setjmp(done) == 0) display_smoke_entry();
        printf("PASS scenario %u: %s\n", scenario,
               scenario == 0 ? "16 steps and wrap; bounded framebuffer, SWAP only" :
               scenario == 1 ? "VSYNC timeout; HEX/LED progression continues" :
               scenario == 2 ? "LED readback error code" : "HEX readback error code");
    }
    return 0;
}
