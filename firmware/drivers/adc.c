#include "adc.h"
#include "soc_mmio.h"

static uint32_t s_adc_enabled = 0u;

static inline uint32_t current_enable_ctrl(void)
{
    return s_adc_enabled ? ADC_CTRL_ENABLE : 0u;
}

adc_status_t adc_init(void)
{
    uint32_t name0   = mmio_read32(ADC_BASE + ADC_NAME0);
    uint32_t name1   = mmio_read32(ADC_BASE + ADC_NAME1);
    uint32_t version = mmio_read32(ADC_BASE + ADC_VERSION);

    /* Verify ADC v2 canonical peripheral identification: "apb-", "adc ", v2.0 */
    if (name0 != ADC_EXPECTED_NAME0 ||
        name1 != ADC_EXPECTED_NAME1 ||
        version != ADC_EXPECTED_VERSION) {
        return ADC_ERROR;
    }

    /* Initialize software enable tracker from current hardware register state */
    uint32_t status = mmio_read32(ADC_BASE + ADC_STATUS);
    s_adc_enabled = (status & ADC_STATUS_ENABLE_REQ) ? 1u : 0u;

    return ADC_OK;
}

adc_status_t adc_enable(uint32_t timeout_loops)
{
    s_adc_enabled = 1u;
    mmio_write32(ADC_BASE + ADC_CTRL, ADC_CTRL_ENABLE);

    for (uint32_t i = 0u; i < timeout_loops; ++i) {
        if ((mmio_read32(ADC_BASE + ADC_STATUS) & ADC_STATUS_ENGINE_ENABLED) != 0u) {
            return ADC_OK;
        }
    }

    return ADC_TIMEOUT;
}

adc_status_t adc_disable(uint32_t timeout_loops)
{
    s_adc_enabled = 0u;
    mmio_write32(ADC_BASE + ADC_CTRL, 0u);

    for (uint32_t i = 0u; i < timeout_loops; ++i) {
        if ((mmio_read32(ADC_BASE + ADC_STATUS) & ADC_STATUS_ENGINE_ENABLED) == 0u) {
            return ADC_OK;
        }
    }

    return ADC_TIMEOUT;
}

bool adc_is_enabled(void)
{
    return (mmio_read32(ADC_BASE + ADC_STATUS) & ADC_STATUS_ENGINE_ENABLED) != 0u;
}

adc_status_t adc_capture(adc_frame_t *frame)
{
    if (frame == 0) {
        return ADC_INVALID_PARAM;
    }

    uint32_t status = mmio_read32(ADC_BASE + ADC_STATUS);
    if ((status & ADC_STATUS_NEW_FRAME) == 0u) {
        return ADC_NO_NEW;
    }

    /* Issue atomic CAPTURE pulse preserving persistent ENABLE */
    mmio_write32(ADC_BASE + ADC_CTRL, current_enable_ctrl() | ADC_CTRL_CAPTURE);

    /* Read coherent HOLD generation */
    frame->seq        = mmio_read32(ADC_BASE + ADC_FRAME_SEQ);
    frame->valid_mask = (uint8_t)(mmio_read32(ADC_BASE + ADC_VALID_MASK) & 0x3fu);
    frame->ch[0]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH1_RAW) & 0x0fffu);
    frame->ch[1]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH2_RAW) & 0x0fffu);
    frame->ch[2]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH3_RAW) & 0x0fffu);
    frame->ch[3]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH4_RAW) & 0x0fffu);
    frame->ch[4]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH5_RAW) & 0x0fffu);
    frame->ch[5]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH6_RAW) & 0x0fffu);

    return ADC_OK;
}

adc_status_t adc_read_hold(adc_frame_t *frame)
{
    if (frame == 0) {
        return ADC_INVALID_PARAM;
    }

    uint32_t status = mmio_read32(ADC_BASE + ADC_STATUS);
    if ((status & ADC_STATUS_HOLD_VALID) == 0u) {
        return ADC_NO_NEW;
    }

    frame->seq        = mmio_read32(ADC_BASE + ADC_FRAME_SEQ);
    frame->valid_mask = (uint8_t)(mmio_read32(ADC_BASE + ADC_VALID_MASK) & 0x3fu);
    frame->ch[0]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH1_RAW) & 0x0fffu);
    frame->ch[1]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH2_RAW) & 0x0fffu);
    frame->ch[2]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH3_RAW) & 0x0fffu);
    frame->ch[3]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH4_RAW) & 0x0fffu);
    frame->ch[4]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH5_RAW) & 0x0fffu);
    frame->ch[5]      = (uint16_t)(mmio_read32(ADC_BASE + ADC_CH6_RAW) & 0x0fffu);

    return ADC_OK;
}

void adc_set_calibration(uint16_t center_x, uint16_t center_y, uint16_t deadzone)
{
    mmio_write32(ADC_BASE + ADC_JOY_CENTER_X, (uint32_t)(center_x & 0x0fffu));
    mmio_write32(ADC_BASE + ADC_JOY_CENTER_Y, (uint32_t)(center_y & 0x0fffu));
    mmio_write32(ADC_BASE + ADC_JOY_DEADZONE, (uint32_t)(deadzone & 0x0fffu));
}

void adc_get_calibration(uint16_t *center_x, uint16_t *center_y, uint16_t *deadzone)
{
    if (center_x != 0) {
        *center_x = (uint16_t)(mmio_read32(ADC_BASE + ADC_JOY_CENTER_X) & 0x0fffu);
    }
    if (center_y != 0) {
        *center_y = (uint16_t)(mmio_read32(ADC_BASE + ADC_JOY_CENTER_Y) & 0x0fffu);
    }
    if (deadzone != 0) {
        *deadzone = (uint16_t)(mmio_read32(ADC_BASE + ADC_JOY_DEADZONE) & 0x0fffu);
    }
}

uint8_t adc_get_raw_joy_status(void)
{
    return (uint8_t)(mmio_read32(ADC_BASE + ADC_JOY_STATUS) & 0x3fu);
}

uint32_t adc_get_error_status(void)
{
    return mmio_read32(ADC_BASE + ADC_ERROR_STATUS);
}

void adc_clear_error(void)
{
    mmio_write32(ADC_BASE + ADC_CTRL, current_enable_ctrl() | ADC_CTRL_CLEAR_ERROR);
}

uint32_t adc_get_frame_count(void)
{
    return mmio_read32(ADC_BASE + ADC_FRAME_COUNT);
}

uint32_t adc_get_status(void)
{
    return mmio_read32(ADC_BASE + ADC_STATUS);
}
