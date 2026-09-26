#include "soc_health_board_io.h"
#include "gpio.h"
#include "sw.h"
#include "led.h"
#include "hex_display.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

void soc_health_board_io_init(soc_health_board_io_t *b)
{
    b->budget = SOC_HEALTH_BOARD_BUDGET; b->settle = SOC_HEALTH_GPIO_SETTLE;
    b->gpio_phase = b->gpio_index = b->gpio_expected = b->gpio_written = 0u;
    b->gpio_start = b->gpio_attempt = b->gpio_generation = 0u;
    b->gpio_deadline.armed = 0u;
    b->gpio_deadline.start_epoch = b->gpio_deadline.budget = b->gpio_deadline.token = 0u;
    b->sw_generation = b->sw_value = b->pending = b->command_start = 0u;
    b->led_readback = b->hex_phase = b->hex_initialized = 0u;
    b->hex_value = b->hex_low = b->hex_high = b->hex_ctrl = 0u;
    b->hex_read_value = b->hex_read_low = b->hex_read_high = b->hex_read_ctrl = 0u;
}
static void failure(soc_health_core_t *c, soc_ip_id_t id, uint32_t detail)
{
    (void)soc_health_report(c, id, SOC_STEP_FAIL, 0u, detail);
}
static void gpio_service(soc_health_core_t *c, soc_health_board_io_t *b)
{
    static const uint8_t stimulus[4] = {0u, 1u, 1u, 0u};
    uint32_t sense;
    if (b->gpio_phase != 0u && soc_health_deadline_poll(c, SOC_IP_GPIO, &b->gpio_deadline)) {
        failure(c, SOC_IP_GPIO, 0x71000000u | (b->gpio_index << 8) | b->gpio_expected);
        b->gpio_phase = 0u; return;
    }
    if (b->gpio_phase == 0u) {
        /* Release owned pins before preloading; unrelated direction/latch bits survive. */
        gpio_set_input(3u);
        b->gpio_written = gpio_read_output() & ~1u;
        gpio_write(b->gpio_written);
        gpio_set_output(1u);
        if ((mmio_read32(GPIO_BASE + GPIO_DIR) & 3u) != 1u ||
            gpio_read_output() != b->gpio_written) {
            failure(c, SOC_IP_GPIO, 0x72000000u); return;
        }
        b->gpio_index = b->gpio_expected = 0u; b->gpio_start = c->epoch;
        (void)soc_health_deadline_begin(&b->gpio_deadline, c->epoch, b->budget, ++b->gpio_attempt);
        b->gpio_phase = 2u; return;
    }
    if (b->gpio_phase == 1u) {
        b->gpio_expected = stimulus[b->gpio_index];
        b->gpio_written = (gpio_read_output() & ~1u) | b->gpio_expected;
        gpio_write(b->gpio_written);
        b->gpio_start = c->epoch; b->gpio_phase = 2u; return;
    }
    if (c->epoch - b->gpio_start < b->settle) return;
    if ((mmio_read32(GPIO_BASE + GPIO_DIR) & 3u) != 1u ||
        gpio_read_output() != b->gpio_written) {
        failure(c, SOC_IP_GPIO, 0x72000000u); b->gpio_phase = 0u; return;
    }
    sense = (gpio_read() >> 1) & 1u;
    if (sense != b->gpio_expected) return; /* bounded settle/deadline retry, not readback PASS */
    if (++b->gpio_index == 4u) {
        (void)soc_health_report(c, SOC_IP_GPIO, SOC_STEP_PROGRESS,
                                ++b->gpio_generation, 0x00000103u);
        b->gpio_deadline.armed = 0u; b->gpio_phase = 0u;
    } else b->gpio_phase = 1u;
}
static void hex_command(soc_health_board_io_t *b)
{
    uint32_t s = b->sw_value, i, group = (s >> 7) & 3u;
    uint32_t on = s & 0x7fu, raw = (~on) & 0x7fu;
    b->hex_value = (s & 0x1ffu) | ((s & 0x1ffu) << 12);
    b->hex_low = b->hex_high = 0u;
    b->hex_ctrl = (s & 0x200u) ? 3u : 1u;
    for (i = 0u; i < 6u; i++) {
        uint32_t digit = raw;
        if ((group == 1u && i >= 3u) || (group == 2u && i < 3u)) digit = 0x7fu;
        if (group == 3u && (i & 1u)) digit = on;
        if (i < 3u) b->hex_low |= digit << (i * 7u);
        else b->hex_high |= digit << ((i - 3u) * 7u);
    }
}
static void sw_service(soc_health_core_t *c, soc_health_board_io_t *b)
{
    if (b->pending) return; /* retain this SW sample until both consumers retire */
    b->sw_value = sw_read() & 0x3ffu;
    ++b->sw_generation; b->command_start = c->epoch;
    b->pending = SOC_BOARD_LED | SOC_BOARD_HEX; b->hex_phase = 0u;
    hex_command(b);
    (void)soc_health_report(c, SOC_IP_SW, SOC_STEP_PROGRESS, b->sw_generation, b->sw_value);
    /* This heartbeat counts completed observations, never physical switch motion. */
}
static int consumer_expired(soc_health_core_t *c, soc_health_board_io_t *b,
                            soc_ip_id_t id, uint32_t bit)
{
    if (c->epoch - b->command_start < b->budget) return 0;
    (void)soc_health_report(c, id, SOC_STEP_DEADLINE_MISS, b->sw_generation,
                            0x73000000u | b->sw_value);
    b->pending &= ~bit; return 1;
}
static void led_service(soc_health_core_t *c, soc_health_board_io_t *b)
{
    if (!(b->pending & SOC_BOARD_LED) || consumer_expired(c, b, SOC_IP_LED, SOC_BOARD_LED)) return;
    led_write(b->sw_value);
    b->led_readback = led_read() & 0x3ffu;
    if (b->led_readback != b->sw_value)
        failure(c, SOC_IP_LED, 0x74000000u | (b->led_readback << 10) | b->sw_value);
    else
        (void)soc_health_report(c, SOC_IP_LED, SOC_STEP_PROGRESS, b->sw_generation,
                                (b->led_readback << 10) | b->sw_value);
    b->pending &= ~SOC_BOARD_LED;
}
static void hex_service(soc_health_core_t *c, soc_health_board_io_t *b)
{
    uint32_t fault = 0u;
    if (!b->hex_initialized) { hex_display_init(); b->hex_initialized = 1u; }
    if (!(b->pending & SOC_BOARD_HEX) || consumer_expired(c, b, SOC_IP_HEX, SOC_BOARD_HEX)) return;
    switch (b->hex_phase) {
    case 0u: hex_display_resync(); hex_display_enable(0); b->hex_phase++; return;
    case 1u:
        if (b->hex_ctrl == 3u) hex_display_write_raw(b->hex_low, b->hex_high);
        else hex_display_write_value(b->hex_value);
        b->hex_phase++; return;
    case 2u: hex_display_set_raw_mode(b->hex_ctrl == 3u); b->hex_phase++; return;
    case 3u: hex_display_enable(1); b->hex_phase++; return;
    default:
        b->hex_read_ctrl = hex_display_read_ctrl();
        if (b->hex_read_ctrl != b->hex_ctrl) fault = 1u;
        if (b->hex_ctrl == 3u) {
            b->hex_read_low = hex_display_read_raw_low();
            b->hex_read_high = hex_display_read_raw_high();
            if (b->hex_read_low != b->hex_low) fault |= 2u;
            if (b->hex_read_high != b->hex_high) fault |= 4u;
        } else {
            b->hex_read_value = hex_display_read_value();
            if (b->hex_read_value != b->hex_value) fault |= 8u;
        }
        if (fault) failure(c, SOC_IP_HEX, (fault << 24) | (b->hex_read_ctrl << 10) | b->sw_value);
        else (void)soc_health_report(c, SOC_IP_HEX, SOC_STEP_PROGRESS, b->sw_generation,
                                     (b->hex_read_ctrl << 10) | b->sw_value);
        b->pending &= ~SOC_BOARD_HEX; return;
    }
}
void soc_health_board_io_service(soc_health_core_t *c, void *context, soc_ip_id_t id)
{
    soc_health_board_io_t *b = (soc_health_board_io_t *)context;
    switch (id) {
    case SOC_IP_GPIO: gpio_service(c, b); break;
    case SOC_IP_SW: sw_service(c, b); break;
    case SOC_IP_LED: led_service(c, b); break;
    case SOC_IP_HEX: hex_service(c, b); break;
    default: break;
    }
}
