#ifndef JOYSTICK_H
#define JOYSTICK_H

/**
 * @file joystick.h
 * @brief DEPRECATED compatibility wrapper over generic ADC v2 driver (adc.h)
 *        and firmware joystick policy (joystick_policy.h).
 *
 * This header and its corresponding driver (joystick.c) are preserved solely
 * as a thin transitional compatibility wrapper during P11 migration.
 * Active production firmware shall use adc.h and joystick_policy.h directly.
 */

#include <stdint.h>
#include "adc.h"
#include "joystick_policy.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Legacy direction status bit definitions (mapped directly to policy flags) */
#define JOY_DIR_FORWARD       JOY_POLICY_DIR_FORWARD
#define JOY_DIR_BACKWARD      JOY_POLICY_DIR_BACKWARD
#define JOY_DIR_LEFT          JOY_POLICY_DIR_LEFT
#define JOY_DIR_RIGHT         JOY_POLICY_DIR_RIGHT
#define JOY_DIR_X_VALID       JOY_POLICY_DIR_X_VALID
#define JOY_DIR_Y_VALID       JOY_POLICY_DIR_Y_VALID

typedef struct {
    uint32_t dir_status;
    uint16_t x_raw;
    uint16_t y_raw;
} joystick_sample_t;

void joystick_init(uint32_t x_channel, uint32_t y_channel,
                   uint32_t center_x, uint32_t center_y,
                   uint32_t deadzone);
void joystick_enable(int enable);
void joystick_clear_flags(void);
uint32_t joystick_dir_status(void);
joystick_sample_t joystick_read(void);
char joystick_dir_to_ascii(uint32_t dir_status);

#ifdef __cplusplus
}
#endif

#endif /* JOYSTICK_H */
