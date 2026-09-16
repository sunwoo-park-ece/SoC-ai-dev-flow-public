#ifndef GPIO_H
#define GPIO_H

#include <stdint.h>

void gpio_set_direction(uint32_t mask);
void gpio_set_output(uint32_t mask);
void gpio_set_input(uint32_t mask);
void gpio_write(uint32_t value);
uint32_t gpio_read(void);
uint32_t gpio_read_output(void);
uint32_t gpio_irq_status(void);
void gpio_irq_clear(uint32_t mask);

#endif
