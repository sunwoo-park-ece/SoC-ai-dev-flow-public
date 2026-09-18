#ifndef VRAM_H
#define VRAM_H

#include <stdint.h>

#define VRAM_STATUS_VSYNC       (1u << 0)
#define VRAM_STATUS_OP_DONE     (1u << 1)
#define VRAM_STATUS_OP_BUSY     (1u << 2)
#define VRAM_STATUS_OP_ABORT    (1u << 3)
#define VRAM_STATUS_DOMAIN_READY (1u << 4)

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
vram_result_t vram_wait_ready(uint32_t poll_budget);
vram_result_t vram_wait_vsync(uint32_t poll_budget);
vram_result_t vram_start_operation(uint32_t command);
vram_result_t vram_wait_operation(uint32_t poll_budget);
void vram_write_word(uint32_t word_offset, uint32_t value);

#endif
