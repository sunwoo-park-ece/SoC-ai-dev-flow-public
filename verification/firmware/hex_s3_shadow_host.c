#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "hex_display.h"
#include "soc_memory_map.h"

static uint32_t hw_ctrl;
static uint32_t ctrl_writes[32];
static unsigned write_count;
static unsigned read_count;
static unsigned checks;
static int inject_bad_expectation;

static void fail(const char *check_id, uint32_t got, uint32_t expected)
{
    fprintf(stderr, "S3_CHECK_FAIL: %s got=%08x expected=%08x\n", check_id, got, expected);
    exit(1);
}

static void expect_u32(const char *check_id, uint32_t got, uint32_t expected)
{
    ++checks;
    if (got != expected) fail(check_id, got, expected);
}

static void expect_last_write(const char *check_id, uint32_t expected)
{
    uint32_t oracle = expected;
    if (inject_bad_expectation && write_count == 1u) oracle ^= 1u;
    if (write_count == 0u) fail(check_id, 0u, oracle);
    expect_u32(check_id, ctrl_writes[write_count - 1u], oracle);
    ++checks;
    if ((ctrl_writes[write_count - 1u] & ~HEX_CTRL_MASK) != 0u)
        fail("S3_CTRL_WRITE_RESERVED_ZERO", ctrl_writes[write_count - 1u], ctrl_writes[write_count - 1u] & HEX_CTRL_MASK);
}

uint32_t mmio_read32(uint32_t addr)
{
    if (addr != HEX_DISPLAY_BASE + HEX_CTRL) fail("S3_UNEXPECTED_READ", addr, HEX_DISPLAY_BASE + HEX_CTRL);
    ++read_count;
    return hw_ctrl;
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    if (addr != HEX_DISPLAY_BASE + HEX_CTRL) fail("S3_UNEXPECTED_WRITE", addr, HEX_DISPLAY_BASE + HEX_CTRL);
    if (write_count >= 32u) fail("S3_WRITE_OVERFLOW", write_count, 32u);
    ctrl_writes[write_count++] = value;
    hw_ctrl = value;
}

void mmio_write8(uint32_t addr, uint8_t value)
{
    (void)value;
    fail("S3_UNEXPECTED_WRITE8", addr, 0u);
}

int main(int argc, char **argv)
{
    unsigned writes_before;
    (void)argv;
    inject_bad_expectation = argc == 2;

    /* Init establishes the normal reset/firmware state without HW RMW. */
    hw_ctrl = 0u;
    hex_display_init();
    expect_last_write("S3_INIT_CTRL", HEX_CTRL_ENABLE);
    expect_u32("S3_INIT_HW", hw_ctrl, HEX_CTRL_ENABLE);

    /* ENABLE then RAW preserves the complementary functional bit. */
    hex_display_enable(0);
    expect_last_write("S3_ENABLE_CLEAR", 0u);
    hex_display_set_raw_mode(1);
    expect_last_write("S3_RAW_SET_AFTER_DISABLE", HEX_CTRL_RAW_MODE);
    hex_display_set_raw_mode(0);
    expect_last_write("S3_RAW_CLEAR", 0u);
    hex_display_enable(1);
    expect_last_write("S3_ENABLE_SET", HEX_CTRL_ENABLE);

    /* RAW then ENABLE exercises the reverse preservation order. */
    hex_display_set_raw_mode(1);
    expect_last_write("S3_RAW_SET", HEX_CTRL_MASK);
    hex_display_enable(0);
    expect_last_write("S3_ENABLE_CLEAR_AFTER_RAW", HEX_CTRL_RAW_MODE);

    /* HEX-only reset is modeled externally; caller explicitly resynchronizes. */
    hw_ctrl = HEX_CTRL_ENABLE;
    writes_before = write_count;
    hex_display_resync();
    expect_u32("S3_RESYNC_READ_COUNT", read_count, 1u);
    expect_u32("S3_RESYNC_NO_WRITE", write_count, writes_before);
    hex_display_set_raw_mode(1);
    expect_last_write("S3_RESYNC_THEN_RAW", HEX_CTRL_MASK);

    /* Contract limitation: without resync, a foreign state is not preserved. */
    hw_ctrl = 0u;
    hex_display_enable(1);
    expect_last_write("S3_NO_RESYNC_LIMIT", HEX_CTRL_MASK);

    /* Read and resync both mask an out-of-band reserved-bit value. */
    hw_ctrl = 0xfffffffdu;
    expect_u32("S3_READ_CTRL_MASK", hex_display_read_ctrl(), HEX_CTRL_ENABLE);
    hex_display_resync();
    hex_display_set_raw_mode(1);
    expect_last_write("S3_RESYNC_MASK_THEN_RAW", HEX_CTRL_MASK);

    if (inject_bad_expectation) fail("S3_INJECT_BAD_EXPECTATION_NOT_REACHED", 0u, 1u);
    printf("SUMMARY: PASS HEX S3 shadow checks=%u writes=%u reads=%u\n", checks, write_count, read_count);
    return 0;
}
