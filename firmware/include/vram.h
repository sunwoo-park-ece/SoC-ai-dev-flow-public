#ifndef VRAM_H
#define VRAM_H

#include <stdint.h>

#define VRAM_STATUS_VSYNC       (1u << 0)
#define VRAM_STATUS_OP_DONE     (1u << 1)
#define VRAM_STATUS_OP_BUSY     (1u << 2)
#define VRAM_STATUS_OP_ABORT    (1u << 3)
#define VRAM_STATUS_DOMAIN_READY (1u << 4)
#define VRAM_STATUS_IS_CDC      (1u << 5)
#define VRAM_STATUS_LOCK_LOSS_SHIFT 16u
#define VRAM_STATUS_LOCK_LOSS_MASK (0xffffu << VRAM_STATUS_LOCK_LOSS_SHIFT)

/* Extract both diagnostics from ONE vram_status() snapshot. Zero fault is
 * not physical CDC proof; captured losses can coalesce and count saturates. */
static inline uint32_t vram_status_is_cdc(uint32_t status)
{
    return (status & VRAM_STATUS_IS_CDC) != 0u;
}
static inline uint16_t vram_status_lock_loss_count(uint32_t status)
{
    return (uint16_t)((status & VRAM_STATUS_LOCK_LOSS_MASK) >>
                      VRAM_STATUS_LOCK_LOSS_SHIFT);
}

#define VRAM_CTRL_SWAP          (1u << 0)
#define VRAM_CTRL_HW_CLEAR      (1u << 1)

typedef enum {
    VRAM_RESULT_OK = 0,
    VRAM_RESULT_TIMEOUT,
    VRAM_RESULT_NOT_READY,
    VRAM_RESULT_BUSY,
    VRAM_RESULT_ABORTED
} vram_result_t;

uint32_t vram_status(void);
void vram_clear_events(uint32_t mask);
/* Caller must capture/report status before explicitly acknowledging fault.
 * New hardware diagnosis may set the flag again; this never clears count. */
void vram_clear_cdc_fault(void);
vram_result_t vram_wait_ready(uint32_t poll_budget);
vram_result_t vram_wait_vsync(uint32_t poll_budget);
vram_result_t vram_start_operation(uint32_t command);
vram_result_t vram_wait_operation(uint32_t poll_budget);
void vram_write_word(uint32_t word_offset, uint32_t value);

#endif
