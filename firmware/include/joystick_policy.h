#ifndef JOYSTICK_POLICY_H
#define JOYSTICK_POLICY_H

#include <stdint.h>
#include <stdbool.h>
#include "adc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Joystick Direction & Validity Flags (matching hardware JOY_STATUS) */
#define JOY_POLICY_DIR_FORWARD   (1u << 0)
#define JOY_POLICY_DIR_BACKWARD  (1u << 1)
#define JOY_POLICY_DIR_LEFT      (1u << 2)
#define JOY_POLICY_DIR_RIGHT     (1u << 3)
#define JOY_POLICY_DIR_X_VALID   (1u << 4)
#define JOY_POLICY_DIR_Y_VALID   (1u << 5)

typedef struct {
    uint16_t center_x;
    uint16_t center_y;
    uint16_t deadzone;
} joystick_calibration_t;

/**
 * Pure firmware policy evaluation:
 * Recomputes directional status independently from a coherent ADC HOLD frame
 * and calibration settings using saturated 12-bit thresholds and strict inequalities.
 * Contains no MMIO and does not reference hardware JOY_STATUS.
 */
uint8_t joystick_policy_eval(const adc_frame_t *frame, const joystick_calibration_t *cal);

/**
 * Maps evaluated logical direction flags to standard ASCII command:
 *   FORWARD  -> 'w'
 *   BACKWARD -> 's'
 *   LEFT     -> 'a'
 *   RIGHT    -> 'd'
 *   Neutral / Invalid -> ' '
 *
 * NOTE: Physical joystick cabling/polarity is a board-level acceptance item.
 */
char joystick_direction_to_char(uint8_t dir_status);

#ifdef __cplusplus
}
#endif

#endif /* JOYSTICK_POLICY_H */
