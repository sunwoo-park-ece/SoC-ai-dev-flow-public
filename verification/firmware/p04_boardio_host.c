#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "gpio.h"
#include "sw.h"
#include "led.h"
#include "soc_memory_map.h"

static uint32_t gpio_regs[8], sw_regs[3], led_reg;
static unsigned writes;
uint32_t mmio_read32(uint32_t addr)
{
    if (addr >= GPIO_BASE && addr <= GPIO_BASE + GPIO_IRQ_PENDING) {
        assert((addr & 3u) == 0u);
        return gpio_regs[(addr-GPIO_BASE)/4u];
    }
    if (addr >= SW_BASE && addr <= SW_BASE + SW_IRQ_PENDING) {
        assert((addr & 3u) == 0u);
        return sw_regs[(addr-SW_BASE)/4u];
    }
    if (addr == LED_BASE + LED_DATA) return led_reg;
    assert(!"unexpected P04 read address");
    return 0;
}
void mmio_write32(uint32_t addr, uint32_t value)
{
    ++writes;
    if (addr >= GPIO_BASE && addr <= GPIO_BASE + GPIO_IRQ_PENDING) {
        assert((addr & 3u) == 0u);
        gpio_regs[(addr-GPIO_BASE)/4u] = value;
    } else if (addr >= SW_BASE && addr <= SW_BASE + SW_IRQ_PENDING) {
        assert((addr & 3u) == 0u);
        sw_regs[(addr-SW_BASE)/4u] = value;
    } else if (addr == LED_BASE + LED_DATA) led_reg = value;
    else assert(!"unexpected P04 write address");
}
int main(void)
{
    gpio_regs[GPIO_DATA_IN/4u] = 0x1234abcd;
    gpio_regs[GPIO_DIR/4u] = 0x8000u;
    sw_regs[SW_DATA/4u] = 0xdead03a5u;
    gpio_write(0x12345678u);
    assert(gpio_regs[GPIO_DATA_OUT/4u] == 0x5678u);
    assert(gpio_read() == 0xabcdu);
    assert(gpio_read_output() == 0x5678u);
    gpio_set_output(0x0003u);
    assert(gpio_regs[GPIO_DIR/4u] == 0x8003u);
    gpio_set_input(0x8001u);
    assert(gpio_regs[GPIO_DIR/4u] == 0x0002u);
    gpio_regs[GPIO_IRQ_PENDING/4u] = 0xffff0005u;
    assert(gpio_irq_status() == 5u);
    gpio_irq_clear(0x10002u);
    assert(gpio_regs[GPIO_IRQ_PENDING/4u] == 2u);
    assert(sw_read() == 0x3a5u);
    sw_irq_enable(0x40001u);
    assert(sw_regs[SW_IRQ_ENABLE/4u] == 1u);
    sw_regs[SW_IRQ_PENDING/4u] = 0x40002u;
    assert(sw_irq_status() == 2u);
    sw_irq_clear(0x40004u);
    assert(sw_regs[SW_IRQ_PENDING/4u] == 4u);
    led_write(0x12345u);
    assert(led_reg == 0x345u && led_read() == 0x345u);
    assert(writes == 7u);
    puts("SUMMARY: PASS P04 GPIO/SW/LED firmware driver host test");
    return 0;
}
