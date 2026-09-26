/**
 * @file joystick.c
 * @brief DEPRECATED compatibility wrapper over generic ADC v2 driver (adc.h)
 *        and firmware joystick policy (joystick_policy.h).
 *
 * Contains NO direct MMIO access and NO v1 register references.
 */

#include "joystick.h"

static joystick_calibration_t s_compat_cal = {
    2048u,
    2048u,
    300u
};

void joystick_init(uint32_t x_channel, uint32_t y_channel,
                   uint32_t center_x, uint32_t center_y,
                   uint32_t deadzone)
{
    /* x_channel and y_channel are unused as ADC v2 fixes CH1=X, CH2=Y */
    (void)x_channel;
    (void)y_channel;

    s_compat_cal.center_x = (uint16_t)(center_x & 0x0fffu);
    s_compat_cal.center_y = (uint16_t)(center_y & 0x0fffu);
    s_compat_cal.deadzone = (uint16_t)(deadzone & 0x0fffu);

    (void)adc_init();
    adc_set_calibration(s_compat_cal.center_x, s_compat_cal.center_y, s_compat_cal.deadzone);
    (void)adc_enable(1000u);
}

void joystick_enable(int enable)
{
    if (enable != 0) {
        (void)adc_enable(1000u);
    } else {
        (void)adc_disable(1000u);
    }
}

void joystick_clear_flags(void)
{
    adc_clear_error();
}

uint32_t joystick_dir_status(void)
{
    return (uint32_t)adc_get_raw_joy_status();
}

joystick_sample_t joystick_read(void)
{
    joystick_sample_t sample;
    sample.dir_status = 0u;
    sample.x_raw = 0u;
    sample.y_raw = 0u;

    adc_frame_t frame;
    /* Try capture; if no new frame, read hold */
    adc_status_t st = adc_capture(&frame);
    if (st != ADC_OK) {
        st = adc_read_hold(&frame);
    }

    if (st == ADC_OK) {
        sample.dir_status = (uint32_t)joystick_policy_eval(&frame, &s_compat_cal);
        sample.x_raw = frame.ch[0];
        sample.y_raw = frame.ch[1];
    }

    return sample;
}

char joystick_dir_to_ascii(uint32_t dir_status)
{
    /* Uses canonical WASD mapping (eliminating historical LEFT/RIGHT reversal) */
    return joystick_direction_to_char((uint8_t)(dir_status & 0x3fu));
}
