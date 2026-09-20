#include "gsensor.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

gsensor_status_t gsensor_read_sample(gsensor_sample_t *out)
{
    uint32_t status;
    uint32_t xy;
    uint32_t z;

    if (out == 0) {
        return GSENSOR_ERROR;
    }

    status = mmio_read32(GSENSOR_BASE + GSENSOR_STATUS);
    if ((status & GSENSOR_STATUS_HOLD_VALID) != 0u) {
        return GSENSOR_BUSY;
    }
    if ((status & GSENSOR_STATUS_LIVE_VALID) == 0u) {
        return GSENSOR_NO_NEW;
    }

    mmio_write32(GSENSOR_BASE + GSENSOR_SNAP_CTRL, GSENSOR_SNAP_CAPTURE);
    status = mmio_read32(GSENSOR_BASE + GSENSOR_STATUS);
    if ((status & GSENSOR_STATUS_HOLD_VALID) == 0u) {
        return GSENSOR_NO_NEW;
    }

    out->seq = mmio_read32(GSENSOR_BASE + GSENSOR_HOLD_SEQ);
    xy = mmio_read32(GSENSOR_BASE + GSENSOR_HOLD_XY);
    z = mmio_read32(GSENSOR_BASE + GSENSOR_HOLD_Z);
    out->x = (int16_t)(xy >> 16);
    out->y = (int16_t)xy;
    out->z = (int16_t)z;
    mmio_write32(GSENSOR_BASE + GSENSOR_SNAP_CTRL, GSENSOR_SNAP_RELEASE);
    return GSENSOR_OK;
}
