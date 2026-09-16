#ifndef DISPLAY_SMOKE_MMIO_H
#define DISPLAY_SMOKE_MMIO_H
#include <stdint.h>
/* Replace physical MMIO for host fault injection; retain production drivers. */
#define SOC_MMIO_H
uint32_t mmio_read32(uint32_t addr);
void mmio_write32(uint32_t addr, uint32_t value);
void mmio_write8(uint32_t addr, uint8_t value);
#endif
