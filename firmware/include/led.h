#ifndef SOC_LED_H
#define SOC_LED_H
#include <stdint.h>
void led_write(uint32_t value);
uint32_t led_read(void);
#endif
