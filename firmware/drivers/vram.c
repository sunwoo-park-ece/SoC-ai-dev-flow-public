#include "vram.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

uint32_t vram_status(void)
{
    return mmio_read32(VRAM_BASE + VRAM_STATUS);
}

void vram_wait_vsync(void)
{
    while ((vram_status() & VRAM_STATUS_VSYNC) == 0u) {
    }
}

void vram_clear_vsync(void)
{
    mmio_write32(VRAM_BASE + VRAM_STATUS, VRAM_STATUS_VSYNC);
}

void vram_swap_and_clear(void)
{
    mmio_write32(VRAM_BASE + VRAM_CONTROL, VRAM_CTRL_SWAP | VRAM_CTRL_HW_CLEAR);
}

void vram_wait_clear_done(void)
{
    while ((vram_status() & VRAM_STATUS_CLEAR_BUSY) != 0u) {
    }
}

void vram_write_word(uint32_t word_offset, uint32_t value)
{
    mmio_write32(VRAM_BASE + (word_offset * 4u), value);
}

void vram_write_byte(uint32_t byte_offset, uint8_t value)
{
    mmio_write8(VRAM_BASE + byte_offset, value);
}
