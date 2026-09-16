#ifndef VRAM_H
#define VRAM_H

#include <stdint.h>

#define VRAM_STATUS_VSYNC       (1u << 0)
#define VRAM_STATUS_CLEAR_DONE  (1u << 1)
#define VRAM_STATUS_CLEAR_BUSY  (1u << 2)

#define VRAM_CTRL_SWAP          (1u << 0)
#define VRAM_CTRL_HW_CLEAR      (1u << 1)

uint32_t vram_status(void);
void vram_wait_vsync(void);
void vram_clear_vsync(void);
void vram_swap_and_clear(void);
void vram_wait_clear_done(void);
void vram_write_word(uint32_t word_offset, uint32_t value);
void vram_write_byte(uint32_t byte_offset, uint8_t value);

#endif
