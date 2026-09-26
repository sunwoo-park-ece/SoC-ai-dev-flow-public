#ifndef SOC_HEALTH_BOARD_IO_H
#define SOC_HEALTH_BOARD_IO_H
#include "soc_health.h"
#define SOC_HEALTH_GPIO_SETTLE 3u
#define SOC_HEALTH_BOARD_BUDGET 262144u
#define SOC_BOARD_LED 1u
#define SOC_BOARD_HEX 2u
/* Single-owner SW command storage. Snapshot detail retains each consumed value;
 * PASS plus that value/CTRL deterministically describes matched HEX banks. */
typedef struct {
    uint32_t budget, settle, gpio_phase, gpio_index, gpio_expected;
    uint32_t gpio_written, gpio_start, gpio_attempt, gpio_generation;
    soc_health_deadline_t gpio_deadline;
    uint32_t sw_generation, sw_value, pending, command_start;
    uint32_t led_readback, hex_phase, hex_initialized;
    uint32_t hex_value, hex_low, hex_high, hex_ctrl;
    uint32_t hex_read_value, hex_read_low, hex_read_high, hex_read_ctrl;
} soc_health_board_io_t;
void soc_health_board_io_init(soc_health_board_io_t *board);
void soc_health_board_io_service(soc_health_core_t *core, void *context,
                                 soc_ip_id_t id);
#endif
