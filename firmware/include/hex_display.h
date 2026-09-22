#ifndef HEX_DISPLAY_H
#define HEX_DISPLAY_H

#include <stdint.h>

#define HEX_CTRL_ENABLE   (1u << 0)
#define HEX_CTRL_RAW_MODE (1u << 1)
#define HEX_CTRL_MASK     (HEX_CTRL_ENABLE | HEX_CTRL_RAW_MODE)

/* Normal boot initialization: establishes driver Shadow and hardware CTRL=1. */
void hex_display_init(void);
/* Caller invokes after HEX-only reset or suspected out-of-band CTRL change. */
void hex_display_resync(void);
/* Legacy helpers before init rely on the normal hardware-reset CTRL=1 contract. */
void hex_display_enable(int enable);
void hex_display_set_raw_mode(int enable);
void hex_display_write_value(uint32_t value);
void hex_display_write_raw(uint32_t raw_low, uint32_t raw_high);
void hex_display_write_monitor(uint8_t mode, uint8_t state, uint8_t retry_count,
                               uint8_t err, uint8_t rx_seq, uint8_t tx_seq);
uint32_t hex_display_read_value(void);
uint32_t hex_display_read_ctrl(void);

#endif
