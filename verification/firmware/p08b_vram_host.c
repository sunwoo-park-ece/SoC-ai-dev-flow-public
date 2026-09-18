#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "soc_memory_map.h"
#include "vram.h"

static uint32_t status_value;
static uint32_t reads_before_change;
static uint32_t changed_status;
static uint32_t control_writes;
static uint32_t status_writes;

uint32_t mmio_read32(uint32_t addr)
{
    assert(addr == VRAM_BASE + VRAM_STATUS);
    if (reads_before_change != 0u) {
        --reads_before_change;
        return status_value;
    }
    return changed_status;
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    if (addr == VRAM_BASE + VRAM_STATUS) {
        assert((value & ~0xbu) == 0u);
        ++status_writes;
    } else if (addr == VRAM_BASE + VRAM_CONTROL) {
        assert((value & ~3u) == 0u);
        ++control_writes;
    } else {
        assert(addr >= VRAM_BASE && addr <= VRAM_BASE + 0x95ffu);
        assert((addr & 3u) == 0u);
    }
}

void mmio_write8(uint32_t addr, uint8_t value)
{
    (void)addr;
    (void)value;
    assert(!"unsupported byte framebuffer write");
}

static void set_status(uint32_t initial, uint32_t count, uint32_t final)
{
    status_value = initial;
    reads_before_change = count;
    changed_status = final;
}

int main(void)
{
    set_status(0u, 2u, VRAM_STATUS_DOMAIN_READY);
    assert(vram_wait_ready(3u) == VRAM_RESULT_OK);
    set_status(0u, 4u, VRAM_STATUS_DOMAIN_READY);
    assert(vram_wait_ready(3u) == VRAM_RESULT_TIMEOUT);

    set_status(VRAM_STATUS_DOMAIN_READY, 1u,
               VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_VSYNC);
    assert(vram_wait_vsync(2u) == VRAM_RESULT_OK);
    set_status(VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_ABORT, 1u, 0u);
    assert(vram_wait_vsync(1u) == VRAM_RESULT_ABORTED);
    set_status(0u, 1u, 0u);
    assert(vram_wait_vsync(1u) == VRAM_RESULT_NOT_READY);

    set_status(VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_BUSY, 1u, 0u);
    assert(vram_start_operation(VRAM_CTRL_SWAP) == VRAM_RESULT_BUSY);
    set_status(0u, 1u, 0u);
    assert(vram_start_operation(VRAM_CTRL_SWAP) == VRAM_RESULT_NOT_READY);
    set_status(VRAM_STATUS_DOMAIN_READY, 1u, VRAM_STATUS_DOMAIN_READY);
    assert(vram_start_operation(VRAM_CTRL_SWAP | VRAM_CTRL_HW_CLEAR) == VRAM_RESULT_OK);
    assert(control_writes == 1u && status_writes == 1u);

    set_status(VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_BUSY, 1u,
               VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_DONE);
    assert(vram_wait_operation(2u) == VRAM_RESULT_OK);
    set_status(VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_BUSY, 3u,
               VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_DONE);
    assert(vram_wait_operation(2u) == VRAM_RESULT_TIMEOUT);
    set_status(VRAM_STATUS_DOMAIN_READY | VRAM_STATUS_OP_ABORT, 1u, 0u);
    assert(vram_wait_operation(1u) == VRAM_RESULT_ABORTED);

    vram_write_word(9599u, 0x12345678u);
    puts("SUMMARY: PASS P08B bounded VRAM firmware API");
    return 0;
}
