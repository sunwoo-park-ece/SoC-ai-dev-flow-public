#ifndef SOC_SW_H
#define SOC_SW_H
#include <stdint.h>
uint32_t sw_read(void);
uint32_t sw_irq_status(void);
void sw_irq_enable(uint32_t mask);
void sw_irq_clear(uint32_t mask);
#endif
