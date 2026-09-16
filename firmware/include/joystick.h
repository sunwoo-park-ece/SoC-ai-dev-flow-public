#ifndef JOYSTICK_H
#define JOYSTICK_H

#include <stdint.h>

#define JOY_CTRL_ENABLE       (1u << 0)
#define JOY_CTRL_CLEAR_FLAGS  (1u << 1)
#define JOY_CTRL_CLEAR_COUNT  (1u << 2)

#define JOY_DIR_FORWARD       (1u << 0)
#define JOY_DIR_BACKWARD      (1u << 1)
#define JOY_DIR_LEFT          (1u << 2)
#define JOY_DIR_RIGHT         (1u << 3)
#define JOY_DIR_X_VALID       (1u << 4)
#define JOY_DIR_Y_VALID       (1u << 5)

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

#endif
