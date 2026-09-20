#ifndef GSENSOR_H
#define GSENSOR_H

#include <stdint.h>

#define GSENSOR_HOLD_XY   0x00u
#define GSENSOR_HOLD_Z    0x04u
#define GSENSOR_STATUS    0x08u
#define GSENSOR_HOLD_SEQ  0x0cu
#define GSENSOR_SNAP_CTRL 0x10u

#define GSENSOR_STATUS_LIVE_VALID (1u << 0)
#define GSENSOR_STATUS_HOLD_VALID (1u << 1)

#define GSENSOR_SNAP_CAPTURE 1u
#define GSENSOR_SNAP_RELEASE 2u

typedef enum {
    GSENSOR_OK,
    GSENSOR_NO_NEW,
    GSENSOR_BUSY,
    GSENSOR_ERROR
} gsensor_status_t;

typedef struct {
    int16_t x;
    int16_t y;
    int16_t z;
    uint32_t seq;
} gsensor_sample_t;

/* Single-owner, non-reentrant API; not for ISR or concurrent callers. */
gsensor_status_t gsensor_read_sample(gsensor_sample_t *out);

#endif
