#include "vram.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

uint32_t vram_status(void)
{
    return mmio_read32(VRAM_BASE + VRAM_STATUS);
}

void vram_clear_events(uint32_t mask)
{
    mmio_write32(VRAM_BASE + VRAM_STATUS,
                 mask & (VRAM_STATUS_VSYNC | VRAM_STATUS_OP_DONE |
                         VRAM_STATUS_OP_ABORT));
}

vram_result_t vram_wait_ready(uint32_t poll_budget)
{
    while (poll_budget-- != 0u) {
        if ((vram_status() & VRAM_STATUS_DOMAIN_READY) != 0u)
            return VRAM_RESULT_OK;
    }
    return VRAM_RESULT_TIMEOUT;
}

vram_result_t vram_wait_vsync(uint32_t poll_budget)
{
    while (poll_budget-- != 0u) {
        uint32_t status = vram_status();
        if ((status & VRAM_STATUS_OP_ABORT) != 0u)
            return VRAM_RESULT_ABORTED;
        if ((status & VRAM_STATUS_DOMAIN_READY) == 0u)
            return VRAM_RESULT_NOT_READY;
        if ((status & VRAM_STATUS_VSYNC) != 0u)
            return VRAM_RESULT_OK;
    }
    return VRAM_RESULT_TIMEOUT;
}

vram_result_t vram_start_operation(uint32_t command)
{
    uint32_t status = vram_status();

    command &= VRAM_CTRL_SWAP | VRAM_CTRL_HW_CLEAR;
    if ((status & VRAM_STATUS_DOMAIN_READY) == 0u)
        return VRAM_RESULT_NOT_READY;
    if ((status & VRAM_STATUS_OP_BUSY) != 0u)
        return VRAM_RESULT_BUSY;
    if (command == 0u)
        return VRAM_RESULT_OK;

    vram_clear_events(VRAM_STATUS_OP_DONE | VRAM_STATUS_OP_ABORT);
    mmio_write32(VRAM_BASE + VRAM_CONTROL, command);
    return VRAM_RESULT_OK;
}

vram_result_t vram_wait_operation(uint32_t poll_budget)
{
    while (poll_budget-- != 0u) {
        uint32_t status = vram_status();
        if ((status & VRAM_STATUS_OP_ABORT) != 0u)
            return VRAM_RESULT_ABORTED;
        if ((status & VRAM_STATUS_DOMAIN_READY) == 0u)
            return VRAM_RESULT_NOT_READY;
        if ((status & VRAM_STATUS_OP_DONE) != 0u)
            return VRAM_RESULT_OK;
    }
    return VRAM_RESULT_TIMEOUT;
}

void vram_write_word(uint32_t word_offset, uint32_t value)
{
    mmio_write32(VRAM_BASE + (word_offset * 4u), value);
}
