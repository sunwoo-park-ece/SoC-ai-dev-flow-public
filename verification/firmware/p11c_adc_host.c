#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "p11c_adc_mmio.h"
#include "soc_memory_map.h"
#include "adc.h"
#include "joystick_policy.h"

/* Mock MMIO storage for ADC v2 peripheral */
#define MOCK_REGS_WORDS 32
static uint32_t mock_regs[MOCK_REGS_WORDS];

typedef struct {
    uint32_t addr;
    uint32_t value;
} write_record_t;

#define MAX_WRITES 256
static write_record_t write_history[MAX_WRITES];
static unsigned write_history_count = 0;

static void reset_mock(void)
{
    memset(mock_regs, 0, sizeof(mock_regs));
    write_history_count = 0;

    /* Set default peripheral ID values matching RTL APB_ADC_Controller */
    mock_regs[ADC_NAME0 / 4]   = ADC_EXPECTED_NAME0;   // 0x6170622D: "apb-"
    mock_regs[ADC_NAME1 / 4]   = ADC_EXPECTED_NAME1;   // 0x61646320: "adc "
    mock_regs[ADC_VERSION / 4] = ADC_EXPECTED_VERSION; // 0x00020000: v2.0

    /* Default reset values for calibration */
    mock_regs[ADC_JOY_CENTER_X / 4] = 2048u;
    mock_regs[ADC_JOY_CENTER_Y / 4] = 2048u;
    mock_regs[ADC_JOY_DEADZONE / 4] = 300u;
}

uint32_t mmio_read32(uint32_t addr)
{
    assert(addr >= ADC_BASE && addr < (ADC_BASE + (MOCK_REGS_WORDS * 4)));
    uint32_t offset = addr - ADC_BASE;
    return mock_regs[offset / 4];
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    assert(addr >= ADC_BASE && addr < (ADC_BASE + (MOCK_REGS_WORDS * 4)));
    assert(write_history_count < MAX_WRITES);
    write_history[write_history_count].addr = addr;
    write_history[write_history_count].value = value;
    write_history_count++;

    uint32_t offset = addr - ADC_BASE;
    if (offset == ADC_CTRL) {
        /* Bit 0 is persistent ENABLE */
        if (value & ADC_CTRL_ENABLE) {
            mock_regs[ADC_STATUS / 4] |= ADC_STATUS_ENABLE_REQ;
        } else {
            mock_regs[ADC_STATUS / 4] &= ~ADC_STATUS_ENABLE_REQ;
        }
        /* Bit 2 is CLEAR_ERROR */
        if (value & ADC_CTRL_CLEAR_ERROR) {
            mock_regs[ADC_ERROR_STATUS / 4] = 0u;
            mock_regs[ADC_STATUS / 4] &= ~ADC_STATUS_ERROR_PENDING;
        }
    } else {
        mock_regs[offset / 4] = value;
    }
}

/* ========================================================================= */
/* 1. Policy C Tests                                                         */
/* ========================================================================= */
static void test_policy_c(void)
{
    printf("--- Running Policy C Tests ---\n");
    joystick_calibration_t cal = { 2048u, 2048u, 300u };
    adc_frame_t frame;
    memset(&frame, 0, sizeof(frame));

    // 1. Neutral at center
    frame.valid_mask = 0x03u;
    frame.ch[0] = 2048u;
    frame.ch[1] = 2048u;
    uint8_t st = joystick_policy_eval(&frame, &cal);
    assert(st == (JOY_POLICY_DIR_X_VALID | JOY_POLICY_DIR_Y_VALID));
    assert(joystick_direction_to_char(st) == ' ');

    // 2. Exact thresholds: neutral (strict inequality)
    // High = 2048 + 300 = 2348, Low = 2048 - 300 = 1748
    frame.ch[0] = 2348u; frame.ch[1] = 2048u;
    assert((joystick_policy_eval(&frame, &cal) & JOY_POLICY_DIR_RIGHT) == 0);
    frame.ch[0] = 1748u; frame.ch[1] = 2048u;
    assert((joystick_policy_eval(&frame, &cal) & JOY_POLICY_DIR_LEFT) == 0);
    frame.ch[0] = 2048u; frame.ch[1] = 2348u;
    assert((joystick_policy_eval(&frame, &cal) & JOY_POLICY_DIR_FORWARD) == 0);
    frame.ch[0] = 2048u; frame.ch[1] = 1748u;
    assert((joystick_policy_eval(&frame, &cal) & JOY_POLICY_DIR_BACKWARD) == 0);

    // 3. Boundary ±1 assertions
    frame.ch[0] = 2349u; frame.ch[1] = 2048u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_RIGHT) != 0);
    assert(joystick_direction_to_char(st) == 'd'); // RIGHT is 'd'

    frame.ch[0] = 1747u; frame.ch[1] = 2048u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_LEFT) != 0);
    assert(joystick_direction_to_char(st) == 'a'); // LEFT is 'a' (no reversal)

    frame.ch[0] = 2048u; frame.ch[1] = 2349u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_FORWARD) != 0);
    assert(joystick_direction_to_char(st) == 'w'); // FORWARD is 'w'

    frame.ch[0] = 2048u; frame.ch[1] = 1747u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_BACKWARD) != 0);
    assert(joystick_direction_to_char(st) == 's'); // BACKWARD is 's'

    // 4. Diagonals
    frame.ch[0] = 2500u; frame.ch[1] = 2500u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_RIGHT) && (st & JOY_POLICY_DIR_FORWARD));

    frame.ch[0] = 1500u; frame.ch[1] = 2500u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_LEFT) && (st & JOY_POLICY_DIR_FORWARD));

    // 5. Valid mask gating
    frame.valid_mask = 0x00u; // both invalid
    st = joystick_policy_eval(&frame, &cal);
    assert(st == 0u);
    assert(joystick_direction_to_char(st) == ' ');

    frame.valid_mask = 0x01u; // X valid only
    frame.ch[0] = 2500u; frame.ch[1] = 2500u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_RIGHT) != 0);
    assert((st & JOY_POLICY_DIR_FORWARD) == 0); // Y gated
    assert((st & JOY_POLICY_DIR_Y_VALID) == 0);
    assert(joystick_direction_to_char(st) == ' '); // invalid Y yields neutral char

    frame.valid_mask = 0x02u; // Y valid only
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_RIGHT) == 0); // X gated
    assert((st & JOY_POLICY_DIR_FORWARD) != 0);
    assert(joystick_direction_to_char(st) == ' ');

    // 6. Saturation underflow/overflow clamp
    cal.center_x = 100u; cal.deadzone = 200u; // low_x clamps to 0
    frame.valid_mask = 0x03u;
    frame.ch[0] = 0u; frame.ch[1] = 2048u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_LEFT) == 0); // 0 is not < 0

    cal.center_y = 4000u; cal.deadzone = 200u; // high_y clamps to 4095
    frame.ch[0] = 2048u; frame.ch[1] = 4095u;
    st = joystick_policy_eval(&frame, &cal);
    assert((st & JOY_POLICY_DIR_FORWARD) == 0); // 4095 is not > 4095

    printf("[PASS] Policy C tests completed\n");
}

/* ========================================================================= */
/* 2. ADC Driver Tests                                                       */
/* ========================================================================= */
static void test_adc_driver(void)
{
    printf("--- Running ADC Driver Tests ---\n");
    reset_mock();

    // 1. adc_init identity check: verify NAME0, NAME1, VERSION checks
    assert(adc_init() == ADC_OK);

    // Test NAME0 mismatch
    mock_regs[ADC_NAME0 / 4] = 0xDEADBEEFu;
    assert(adc_init() == ADC_ERROR);
    mock_regs[ADC_NAME0 / 4] = ADC_EXPECTED_NAME0; // restore

    // Test NAME1 mismatch
    mock_regs[ADC_NAME1 / 4] = 0xDEADBEEFu;
    assert(adc_init() == ADC_ERROR);
    mock_regs[ADC_NAME1 / 4] = ADC_EXPECTED_NAME1; // restore

    // Test VERSION mismatch
    mock_regs[ADC_VERSION / 4] = 0x00010000u;
    assert(adc_init() == ADC_ERROR);
    mock_regs[ADC_VERSION / 4] = ADC_EXPECTED_VERSION; // restore

    assert(adc_init() == ADC_OK);

    // 2. adc_enable with bounded acknowledgement
    reset_mock();
    assert(adc_init() == ADC_OK);
    // Timeout case: ENGINE_ENABLED never asserts
    assert(adc_enable(10u) == ADC_TIMEOUT);
    assert(write_history_count == 1);
    assert(write_history[0].addr == ADC_BASE + ADC_CTRL);
    assert(write_history[0].value == ADC_CTRL_ENABLE);

    // Success case: ENGINE_ENABLED asserts
    mock_regs[ADC_STATUS / 4] |= ADC_STATUS_ENGINE_ENABLED;
    assert(adc_enable(10u) == ADC_OK);
    assert(adc_is_enabled() == true);

    // 3. adc_disable with bounded acknowledgement
    mock_regs[ADC_STATUS / 4] &= ~ADC_STATUS_ENGINE_ENABLED;
    assert(adc_disable(10u) == ADC_OK);
    assert(adc_is_enabled() == false);
    assert(write_history[write_history_count - 1].addr == ADC_BASE + ADC_CTRL);
    assert(write_history[write_history_count - 1].value == 0u);

    // 4. adc_capture: NEW_FRAME == 0 returns ADC_NO_NEW without stale read
    reset_mock();
    (void)adc_init();
    (void)adc_enable(10u);
    mock_regs[ADC_STATUS / 4] |= ADC_STATUS_ENGINE_ENABLED;
    mock_regs[ADC_STATUS / 4] &= ~ADC_STATUS_NEW_FRAME; // NEW_FRAME = 0
    mock_regs[ADC_CH1_RAW / 4] = 0x123u; // stale data in HOLD

    adc_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    unsigned writes_before = write_history_count;
    assert(adc_capture(&frame) == ADC_NO_NEW);
    assert(write_history_count == writes_before); // No CAPTURE write issued!
    assert(frame.ch[0] == 0u); // Frame was not populated with stale data

    // 5. adc_capture: valid CAPTURE reads one coherent HOLD generation
    mock_regs[ADC_STATUS / 4] |= ADC_STATUS_NEW_FRAME;
    mock_regs[ADC_FRAME_SEQ / 4] = 7u;
    mock_regs[ADC_VALID_MASK / 4] = 3u;
    mock_regs[ADC_CH1_RAW / 4] = 0x600u;
    mock_regs[ADC_CH2_RAW / 4] = 0xA00u;
    mock_regs[ADC_CH3_RAW / 4] = 0x001u;
    mock_regs[ADC_CH4_RAW / 4] = 0x002u;
    mock_regs[ADC_CH5_RAW / 4] = 0x003u;
    mock_regs[ADC_CH6_RAW / 4] = 0x004u;

    assert(adc_capture(&frame) == ADC_OK);
    assert(frame.seq == 7u);
    assert(frame.valid_mask == 3u);
    assert(frame.ch[0] == 0x600u);
    assert(frame.ch[1] == 0xA00u);
    assert(frame.ch[2] == 0x001u);
    assert(frame.ch[3] == 0x002u);
    assert(frame.ch[4] == 0x003u);
    assert(frame.ch[5] == 0x004u);

    // Verify CAPTURE write preserved persistent ENABLE
    assert(write_history[write_history_count - 1].addr == ADC_BASE + ADC_CTRL);
    assert(write_history[write_history_count - 1].value == (ADC_CTRL_ENABLE | ADC_CTRL_CAPTURE));

    // 6. adc_clear_error preserves persistent ENABLE
    mock_regs[ADC_ERROR_STATUS / 4] = 0x08u;
    mock_regs[ADC_STATUS / 4] |= ADC_STATUS_ERROR_PENDING;
    assert(adc_get_error_status() == 0x08u);
    adc_clear_error();
    assert(write_history[write_history_count - 1].addr == ADC_BASE + ADC_CTRL);
    assert(write_history[write_history_count - 1].value == (ADC_CTRL_ENABLE | ADC_CTRL_CLEAR_ERROR));
    assert(adc_get_error_status() == 0u);

    // 7. Calibration uses canonical v2 offsets (0x40, 0x44, 0x48)
    adc_set_calibration(2048u, 2048u, 300u);
    uint16_t cx = 0, cy = 0, dz = 0;
    adc_get_calibration(&cx, &cy, &dz);
    assert(cx == 2048u && cy == 2048u && dz == 300u);

    // 8. Prove zero writes to v1 offsets or RELEASE
    for (unsigned i = 0; i < write_history_count; ++i) {
        uint32_t off = write_history[i].addr - ADC_BASE;
        assert(off != 0x14u); // v1 JOY_X_CHANNEL
        assert(off != 0x18u); // v1 JOY_Y_CHANNEL
        assert(off != 0x24u); // v1 JOY_CENTER_X
        assert(off != 0x28u); // v1 JOY_CENTER_Y
        assert(off != 0x2Cu); // v1 JOY_DEADZONE
        assert(off != 0x30u); // v1 JOY_DIR_STATUS
        assert(off != 0x34u); // v1 JOY_SAMPLE_COUNT
    }

    printf("[PASS] ADC Driver tests completed\n");
}

/* ========================================================================= */
/* 3. HW/FW Policy Cross-Check against policy_vectors.txt                    */
/* ========================================================================= */
static void test_corpus_cross_check(const char *corpus_path)
{
    printf("--- Running Shared Corpus Policy Cross-Check (%s) ---\n", corpus_path);
    FILE *f = fopen(corpus_path, "r");
    if (!f) {
        fprintf(stderr, "Failed to open vector corpus at %s\n", corpus_path);
        exit(1);
    }

    int count = 0;
    int x, y, mask, cx, cy, dz, expected;
    while (fscanf(f, "%d %d %d %d %d %d %d\n", &x, &y, &mask, &cx, &cy, &dz, &expected) == 7) {
        adc_frame_t frame;
        memset(&frame, 0, sizeof(frame));
        frame.valid_mask = (uint8_t)(mask & 0x3fu);
        frame.ch[0] = (uint16_t)(x & 0xfffu);
        frame.ch[1] = (uint16_t)(y & 0xfffu);

        joystick_calibration_t cal;
        cal.center_x = (uint16_t)(cx & 0xfffu);
        cal.center_y = (uint16_t)(cy & 0xfffu);
        cal.deadzone = (uint16_t)(dz & 0xfffu);

        uint8_t fw_status = joystick_policy_eval(&frame, &cal);
        assert(fw_status == (uint8_t)(expected & 0x3fu));
        count++;
    }
    fclose(f);
    printf("[PASS] Verified %d vectors from shared corpus independently in C policy\n", count);
}

int main(int argc, char **argv)
{
    const char *corpus_path = "verification/directed/adc/policy_vectors.txt";
    if (argc > 1) {
        corpus_path = argv[1];
    }

    test_policy_c();
    test_adc_driver();
    test_corpus_cross_check(corpus_path);

    printf("SUMMARY: PASS P11C ADC Firmware Host Verification\n");
    return 0;
}
