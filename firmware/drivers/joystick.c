#include "joystick.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

void joystick_init(uint32_t x_channel, uint32_t y_channel,
                   uint32_t center_x, uint32_t center_y,
                   uint32_t deadzone)
{
    mmio_write32(JOYSTICK_BASE + JOY_X_CHANNEL, x_channel & 0x1fu);
    mmio_write32(JOYSTICK_BASE + JOY_Y_CHANNEL, y_channel & 0x1fu);
    mmio_write32(JOYSTICK_BASE + JOY_CENTER_X, center_x & 0xfffu);
    mmio_write32(JOYSTICK_BASE + JOY_CENTER_Y, center_y & 0xfffu);
    mmio_write32(JOYSTICK_BASE + JOY_DEADZONE, deadzone & 0xfffu);
    joystick_clear_flags();
    joystick_enable(1);
}

void joystick_enable(int enable)
{
    mmio_write32(JOYSTICK_BASE + JOY_CTRL, enable ? JOY_CTRL_ENABLE : 0u);
}

void joystick_clear_flags(void)
{
    mmio_write32(JOYSTICK_BASE + JOY_CTRL,
                 JOY_CTRL_ENABLE | JOY_CTRL_CLEAR_FLAGS | JOY_CTRL_CLEAR_COUNT);
}

uint32_t joystick_dir_status(void)
{
    return mmio_read32(JOYSTICK_BASE + JOY_DIR_STATUS);
}

joystick_sample_t joystick_read(void)
{
    joystick_sample_t sample;
    sample.dir_status = joystick_dir_status();
    sample.x_raw = (uint16_t)(mmio_read32(JOYSTICK_BASE + JOY_X_RAW) & 0xfffu);
    sample.y_raw = (uint16_t)(mmio_read32(JOYSTICK_BASE + JOY_Y_RAW) & 0xfffu);
    return sample;
}

char joystick_dir_to_ascii(uint32_t dir_status)
{
    if ((dir_status & (JOY_DIR_X_VALID | JOY_DIR_Y_VALID)) !=
        (JOY_DIR_X_VALID | JOY_DIR_Y_VALID)) {
        return '\0';
    }
    if ((dir_status & JOY_DIR_FORWARD) != 0u) {
        return 'w';
    }
    if ((dir_status & JOY_DIR_BACKWARD) != 0u) {
        return 's';
    }
    if ((dir_status & JOY_DIR_LEFT) != 0u) {
        return 'd';
    }
    if ((dir_status & JOY_DIR_RIGHT) != 0u) {
        return 'a';
    }
    return ' ';
}
