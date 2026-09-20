#include <stdint.h>
#include "gsensor.h"
#include "soc_memory_map.h"
volatile uint32_t p09_gsensor_signature[8];
int main(void) {
    gsensor_sample_t sample;
    gsensor_status_t status = gsensor_read_sample(&sample);
    p09_gsensor_signature[0] = (uint32_t)status;
    while (status == GSENSOR_NO_NEW) status = gsensor_read_sample(&sample);
    p09_gsensor_signature[1] = (uint32_t)status;
    p09_gsensor_signature[2] = sample.seq;
    p09_gsensor_signature[3] = ((uint32_t)(uint16_t)sample.x << 16) | (uint16_t)sample.y;
    p09_gsensor_signature[4] = (uint16_t)sample.z;
    p09_gsensor_signature[5] = 0x4f4b0001u;
    p09_gsensor_signature[6] = *(volatile uint32_t *)(GSENSOR_BASE + GSENSOR_SNAP_CTRL);
    p09_gsensor_signature[7] = 0xdeadbeefu;
    return 0;
}
