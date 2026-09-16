#include "gpio.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

void gpio_set_direction(uint32_t mask)
{
    mmio_write32(GPIO_BASE + GPIO_DIR, mask & 0xffffu);
}

void gpio_set_output(uint32_t mask)
{
    gpio_set_direction(mmio_read32(GPIO_BASE + GPIO_DIR) | (mask & 0xffffu));
}

void gpio_set_input(uint32_t mask)
{
    gpio_set_direction(mmio_read32(GPIO_BASE + GPIO_DIR) & ~(mask & 0xffffu));
}

void gpio_write(uint32_t value)
{
    mmio_write32(GPIO_BASE + GPIO_DATA_OUT, value & 0xffffu);
}

uint32_t gpio_read(void)
{
    return mmio_read32(GPIO_BASE + GPIO_DATA_IN) & 0xffffu;
}

uint32_t gpio_read_output(void)
{
    return mmio_read32(GPIO_BASE + GPIO_DATA_OUT) & 0xffffu;
}

uint32_t gpio_irq_status(void)
{
    return mmio_read32(GPIO_BASE + GPIO_IRQ_PENDING) & 0xffffu;
}

void gpio_irq_clear(uint32_t mask)
{
    mmio_write32(GPIO_BASE + GPIO_IRQ_PENDING, mask & 0xffffu);
}
