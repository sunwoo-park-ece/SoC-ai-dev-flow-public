#ifndef SOC_HEALTH_TEST_MMIO_H
#define SOC_HEALTH_TEST_MMIO_H
#include <stdint.h>
/* Fail closed if a future S2 source accidentally adds a peripheral MMIO call. */
#define SOC_MMIO_H
uint32_t soc_health_forbidden_read(uint32_t address);
void soc_health_forbidden_write(uint32_t address, uint32_t value);
#define mmio_read32 soc_health_forbidden_read
#define mmio_read8 soc_health_forbidden_read
#define mmio_write32 soc_health_forbidden_write
#define mmio_write8 soc_health_forbidden_write
#endif
