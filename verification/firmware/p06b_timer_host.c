#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "soc_memory_map.h"
#include "timer.h"

typedef struct {
    uint32_t addr;
    uint32_t value;
} write_record_t;

static write_record_t write_log[32];
static unsigned write_count;
static uint32_t mock_count;
static uint32_t mock_status;

uint32_t mmio_read32(uint32_t addr)
{
    if (addr == TIMER_BASE + TIMER_COUNT) return mock_count;
    if (addr == TIMER_BASE + TIMER_STATUS) return mock_status;
    assert(!"unexpected Timer read address");
    return 0u;
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    assert(write_count < (sizeof(write_log) / sizeof(write_log[0])));
    write_log[write_count].addr = addr;
    write_log[write_count].value = value;
    ++write_count;
}

static void reset_log(void)
{
    write_count = 0u;
}

static void expect_write(unsigned index, uint32_t offset, uint32_t value)
{
    assert(index < write_count);
    assert(write_log[index].addr == TIMER_BASE + offset);
    assert(write_log[index].value == value);
}

int main(void)
{
    reset_log();
    timer_start(7u);
    assert(write_count == 2u);
    expect_write(0u, TIMER_COMPARE, 7u);
    expect_write(1u, TIMER_CTRL, TIMER_CTRL_START);

    timer_start(3u);
    assert(write_count == 4u);
    expect_write(2u, TIMER_COMPARE, 3u);
    expect_write(3u, TIMER_CTRL, TIMER_CTRL_START);

    timer_stop();
    timer_reload();
    timer_clear_ready();
    assert(write_count == 7u);
    expect_write(4u, TIMER_CTRL, 0u);
    expect_write(5u, TIMER_CTRL, TIMER_CTRL_RELOAD);
    expect_write(6u, TIMER_STATUS, TIMER_STATUS_READY);

    mock_count = 0x12345678u;
    mock_status = TIMER_STATUS_READY;
    assert(timer_count() == mock_count);
    assert(timer_status() == TIMER_STATUS_READY);

    // final_main canonical terminal service: W1C, then an explicit fresh START.
    reset_log();
    timer_clear_ready();
    timer_start(UINT32_MAX);
    assert(write_count == 3u);
    expect_write(0u, TIMER_STATUS, TIMER_STATUS_READY);
    expect_write(1u, TIMER_COMPARE, UINT32_MAX);
    expect_write(2u, TIMER_CTRL, TIMER_CTRL_START);

    // benchmark canonical sequence: RELOAD, START, sample COUNT, then STOP.
    reset_log();
    timer_reload();
    timer_start(UINT32_MAX);
    assert(timer_count() == mock_count);
    timer_stop();
    assert(write_count == 4u);
    expect_write(0u, TIMER_CTRL, TIMER_CTRL_RELOAD);
    expect_write(1u, TIMER_COMPARE, UINT32_MAX);
    expect_write(2u, TIMER_CTRL, TIMER_CTRL_START);
    expect_write(3u, TIMER_CTRL, 0u);

    puts("SUMMARY: PASS P06B Timer firmware MMIO ordering");
    return 0;
}
