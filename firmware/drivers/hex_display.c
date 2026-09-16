#include "hex_display.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

static uint32_t hex_ctrl_shadow = HEX_CTRL_ENABLE;

void hex_display_enable(int enable)
{
    if (enable) {
        hex_ctrl_shadow |= HEX_CTRL_ENABLE;
    } else {
        hex_ctrl_shadow &= ~HEX_CTRL_ENABLE;
    }
    mmio_write32(HEX_DISPLAY_BASE + HEX_CTRL, hex_ctrl_shadow);
}

void hex_display_set_raw_mode(int enable)
{
    if (enable) {
        hex_ctrl_shadow |= HEX_CTRL_RAW_MODE;
    } else {
        hex_ctrl_shadow &= ~HEX_CTRL_RAW_MODE;
    }
    mmio_write32(HEX_DISPLAY_BASE + HEX_CTRL, hex_ctrl_shadow);
}

void hex_display_write_value(uint32_t value)
{
    mmio_write32(HEX_DISPLAY_BASE + HEX_VALUE, value & 0x00ffffffu);
}

void hex_display_write_raw(uint32_t raw_low, uint32_t raw_high)
{
    mmio_write32(HEX_DISPLAY_BASE + HEX_RAW_LOW, raw_low & 0x001fffffu);
    mmio_write32(HEX_DISPLAY_BASE + HEX_RAW_HIGH, raw_high & 0x001fffffu);
}

void hex_display_write_monitor(uint8_t mode, uint8_t state, uint8_t retry_count,
                               uint8_t err, uint8_t rx_seq, uint8_t tx_seq)
{
    uint32_t value =
        (((uint32_t)mode        & 0x0fu) << 20) |
        (((uint32_t)state       & 0x0fu) << 16) |
        (((uint32_t)retry_count & 0x0fu) << 12) |
        (((uint32_t)err         & 0x0fu) <<  8) |
        (((uint32_t)rx_seq      & 0x0fu) <<  4) |
        (((uint32_t)tx_seq      & 0x0fu) <<  0);

    hex_display_set_raw_mode(0);
    hex_display_write_value(value);
}

uint32_t hex_display_read_value(void)
{
    return mmio_read32(HEX_DISPLAY_BASE + HEX_VALUE) & 0x00ffffffu;
}

uint32_t hex_display_read_ctrl(void)
{
    return mmio_read32(HEX_DISPLAY_BASE + HEX_CTRL);
}
