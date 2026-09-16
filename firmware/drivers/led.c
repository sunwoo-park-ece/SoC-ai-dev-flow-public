#include "led.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"
void led_write(uint32_t value) { mmio_write32(LED_BASE + LED_DATA, value & 0x3ffu); }
uint32_t led_read(void) { return mmio_read32(LED_BASE + LED_DATA) & 0x3ffu; }
