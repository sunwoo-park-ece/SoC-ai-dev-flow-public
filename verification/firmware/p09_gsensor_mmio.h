#ifndef P09_GSENSOR_MMIO_H
#define P09_GSENSOR_MMIO_H

#include <stdint.h>

#define SOC_MMIO_H

uint32_t mmio_read32(uint32_t addr);
void mmio_write32(uint32_t addr, uint32_t value);

#endif
