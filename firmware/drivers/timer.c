#include "timer.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

void timer_start(uint32_t compare)
{
    mmio_write32(TIMER_BASE + TIMER_COMPARE, compare);
    mmio_write32(TIMER_BASE + TIMER_CTRL, TIMER_CTRL_START);
}

void timer_stop(void)
{
    mmio_write32(TIMER_BASE + TIMER_CTRL, 0u);
}

void timer_reload(void)
{
    mmio_write32(TIMER_BASE + TIMER_CTRL, TIMER_CTRL_RELOAD);
}

uint32_t timer_count(void)
{
    return mmio_read32(TIMER_BASE + TIMER_COUNT);
}

uint32_t timer_status(void)
{
    return mmio_read32(TIMER_BASE + TIMER_STATUS);
}

void timer_clear_ready(void)
{
    mmio_write32(TIMER_BASE + TIMER_STATUS, TIMER_STATUS_READY);
}

void timer_wait_ready(void)
{
    while ((timer_status() & TIMER_STATUS_READY) == 0u) {
    }
}

void timer_delay_cycles(uint32_t cycles)
{
    volatile uint32_t i;
    for (i = 0u; i < cycles; i++) {
        __asm__ volatile("nop");
    }
}
