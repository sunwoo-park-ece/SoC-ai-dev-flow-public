#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "gsensor.h"
#include "soc_memory_map.h"

typedef struct {
    uint32_t addr;
    uint32_t value;
} read_step_t;

typedef struct {
    uint32_t addr;
    uint32_t value;
} write_step_t;

static const read_step_t *reads;
static unsigned read_count;
static unsigned read_index;
static write_step_t writes[4];
static unsigned write_count;

uint32_t mmio_read32(uint32_t addr)
{
    assert(read_index < read_count);
    assert(reads[read_index].addr == addr);
    return reads[read_index++].value;
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    assert(write_count < (sizeof(writes) / sizeof(writes[0])));
    writes[write_count].addr = addr;
    writes[write_count].value = value;
    ++write_count;
}

static void begin_case(const read_step_t *script, unsigned count)
{
    reads = script;
    read_count = count;
    read_index = 0u;
    write_count = 0u;
}

static void finish_case(unsigned expected_writes)
{
    assert(read_index == read_count);
    assert(write_count == expected_writes);
}

static void expect_write(unsigned index, uint32_t value)
{
    assert(index < write_count);
    assert(writes[index].addr == GSENSOR_BASE + GSENSOR_SNAP_CTRL);
    assert(writes[index].value == value);
}

int main(void)
{
    gsensor_sample_t sample = {0};
    static const read_step_t no_new[] = {
        {GSENSOR_BASE + GSENSOR_STATUS, 0u},
    };
    static const read_step_t busy[] = {
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_HOLD_VALID},
    };
    static const read_step_t failed_capture[] = {
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_LIVE_VALID},
        {GSENSOR_BASE + GSENSOR_STATUS, 0u},
    };
    static const read_step_t ok_signed[] = {
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_LIVE_VALID},
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_HOLD_VALID},
        {GSENSOR_BASE + GSENSOR_HOLD_SEQ, 0x12345678u},
        {GSENSOR_BASE + GSENSOR_HOLD_XY, 0xfffe0003u},
        {GSENSOR_BASE + GSENSOR_HOLD_Z, 0x0000fffcu},
    };
    static const read_step_t wrap_same_xyz[] = {
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_LIVE_VALID},
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_HOLD_VALID},
        {GSENSOR_BASE + GSENSOR_HOLD_SEQ, 0u},
        {GSENSOR_BASE + GSENSOR_HOLD_XY, 0x12345678u},
        {GSENSOR_BASE + GSENSOR_HOLD_Z, 0x00009abcu},
    };
    static const read_step_t deferred_then_next[] = {
        {GSENSOR_BASE + GSENSOR_STATUS, 0u},
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_LIVE_VALID},
        {GSENSOR_BASE + GSENSOR_STATUS, GSENSOR_STATUS_HOLD_VALID},
        {GSENSOR_BASE + GSENSOR_HOLD_SEQ, 9u},
        {GSENSOR_BASE + GSENSOR_HOLD_XY, 0x00010002u},
        {GSENSOR_BASE + GSENSOR_HOLD_Z, 3u},
    };

    assert(gsensor_read_sample(0) == GSENSOR_ERROR);

    begin_case(no_new, 1u);
    assert(gsensor_read_sample(&sample) == GSENSOR_NO_NEW);
    finish_case(0u);

    begin_case(busy, 1u);
    assert(gsensor_read_sample(&sample) == GSENSOR_BUSY);
    finish_case(0u); /* Never RELEASE another owner's HOLD. */

    begin_case(failed_capture, 2u);
    assert(gsensor_read_sample(&sample) == GSENSOR_NO_NEW);
    finish_case(1u);
    expect_write(0u, GSENSOR_SNAP_CAPTURE); /* No ownership, no RELEASE. */

    begin_case(ok_signed, 5u);
    assert(gsensor_read_sample(&sample) == GSENSOR_OK);
    finish_case(2u);
    expect_write(0u, GSENSOR_SNAP_CAPTURE);
    expect_write(1u, GSENSOR_SNAP_RELEASE);
    assert(sample.seq == 0x12345678u);
    assert(sample.x == -2 && sample.y == 3 && sample.z == -4);

    begin_case(wrap_same_xyz, 5u);
    assert(gsensor_read_sample(&sample) == GSENSOR_OK);
    finish_case(2u);
    expect_write(0u, GSENSOR_SNAP_CAPTURE);
    expect_write(1u, GSENSOR_SNAP_RELEASE);
    assert(sample.seq == 0u); /* Wrapped seq is valid. */
    assert(sample.x == 0x1234 && sample.y == 0x5678 && sample.z == (int16_t)0x9abc);

    begin_case(deferred_then_next, 6u);
    assert(gsensor_read_sample(&sample) == GSENSOR_NO_NEW);
    assert(gsensor_read_sample(&sample) == GSENSOR_OK);
    finish_case(2u);
    expect_write(0u, GSENSOR_SNAP_CAPTURE);
    expect_write(1u, GSENSOR_SNAP_RELEASE);
    assert(sample.seq == 9u && sample.x == 1 && sample.y == 2 && sample.z == 3);

    puts("SUMMARY: PASS P09 GSensor firmware MMIO lifecycle");
    return 0;
}
