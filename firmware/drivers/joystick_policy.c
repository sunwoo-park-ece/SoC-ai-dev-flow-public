#include "joystick_policy.h"

uint8_t joystick_policy_eval(const adc_frame_t *frame, const joystick_calibration_t *cal)
{
    if (frame == 0 || cal == 0) {
        return 0u;
    }

    /* 1. Axis validity from frame valid_mask (bit 0: CH1/X, bit 1: CH2/Y) */
    uint8_t x_valid = (frame->valid_mask & 0x01u) ? 1u : 0u;
    uint8_t y_valid = (frame->valid_mask & 0x02u) ? 1u : 0u;

    /* 2. Saturated 12-bit thresholds using widened arithmetic */
    int32_t sum_x = (int32_t)cal->center_x + (int32_t)cal->deadzone;
    uint16_t high_x = (sum_x > 4095) ? 4095u : (uint16_t)sum_x;
    int32_t sub_x = (int32_t)cal->center_x - (int32_t)cal->deadzone;
    uint16_t low_x = (sub_x < 0) ? 0u : (uint16_t)sub_x;

    int32_t sum_y = (int32_t)cal->center_y + (int32_t)cal->deadzone;
    uint16_t high_y = (sum_y > 4095) ? 4095u : (uint16_t)sum_y;
    int32_t sub_y = (int32_t)cal->center_y - (int32_t)cal->deadzone;
    uint16_t low_y = (sub_y < 0) ? 0u : (uint16_t)sub_y;

    /* 3. Raw sample extractions (CH1 -> X, CH2 -> Y) */
    uint16_t x_raw = frame->ch[0] & 0x0fffu;
    uint16_t y_raw = frame->ch[1] & 0x0fffu;

    /* 4. Direction evaluations (strict inequalities, exact equality is neutral) */
    uint8_t right    = (x_valid && (x_raw > high_x)) ? 1u : 0u;
    uint8_t left     = (x_valid && (x_raw < low_x))  ? 1u : 0u;
    uint8_t forward  = (y_valid && (y_raw > high_y)) ? 1u : 0u;
    uint8_t backward = (y_valid && (y_raw < low_y))  ? 1u : 0u;

    /* 5. Bit packing identical to JOY_STATUS */
    uint8_t status = (uint8_t)(
        (forward  ? JOY_POLICY_DIR_FORWARD  : 0u) |
        (backward ? JOY_POLICY_DIR_BACKWARD : 0u) |
        (left     ? JOY_POLICY_DIR_LEFT     : 0u) |
        (right    ? JOY_POLICY_DIR_RIGHT    : 0u) |
        (x_valid  ? JOY_POLICY_DIR_X_VALID  : 0u) |
        (y_valid  ? JOY_POLICY_DIR_Y_VALID  : 0u)
    );

    return status;
}

char joystick_direction_to_char(uint8_t dir_status)
{
    /* If either axis is invalid, produce neutral ' ' */
    if ((dir_status & (JOY_POLICY_DIR_X_VALID | JOY_POLICY_DIR_Y_VALID)) !=
        (JOY_POLICY_DIR_X_VALID | JOY_POLICY_DIR_Y_VALID)) {
        return ' ';
    }

    /* Standard WASD mapping:
     * FORWARD  -> 'w'
     * BACKWARD -> 's'
     * LEFT     -> 'a'
     * RIGHT    -> 'd'
     */
    if ((dir_status & JOY_POLICY_DIR_FORWARD) != 0u) {
        return 'w';
    }
    if ((dir_status & JOY_POLICY_DIR_BACKWARD) != 0u) {
        return 's';
    }
    if ((dir_status & JOY_POLICY_DIR_LEFT) != 0u) {
        return 'a';
    }
    if ((dir_status & JOY_POLICY_DIR_RIGHT) != 0u) {
        return 'd';
    }

    return ' ';
}
