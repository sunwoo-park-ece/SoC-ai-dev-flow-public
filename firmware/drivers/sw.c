#include "sw.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"
uint32_t sw_read(void) { return mmio_read32(SW_BASE + SW_DATA) & 0x3ffu; }
uint32_t sw_irq_status(void) { return mmio_read32(SW_BASE + SW_IRQ_PENDING) & 0x3ffu; }
void sw_irq_enable(uint32_t mask) { mmio_write32(SW_BASE + SW_IRQ_ENABLE, mask & 0x3ffu); }
void sw_irq_clear(uint32_t mask) { mmio_write32(SW_BASE + SW_IRQ_PENDING, mask & 0x3ffu); }
