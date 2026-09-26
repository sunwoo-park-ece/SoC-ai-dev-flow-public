#ifndef SOC_HEALTH_PROVIDER_MMIO_H
#define SOC_HEALTH_PROVIDER_MMIO_H
#include <stdint.h>
#define SOC_MMIO_H
#ifdef __cplusplus
extern "C" {
#endif
uint32_t soc_health_test_read(uint32_t address);
void soc_health_test_write(uint32_t address, uint32_t value);
#ifdef __cplusplus
}
#endif
#define mmio_read32 soc_health_test_read
#define mmio_write32 soc_health_test_write
#endif
