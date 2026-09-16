#ifndef VGA_TEXT_H
#define VGA_TEXT_H

#include <stdint.h>

void vga_text_begin_frame(void);
void vga_text_puts(uint32_t word_x, uint32_t y, const char *str);
void vga_text_put_hex8(uint32_t word_x, uint32_t y, uint8_t value);
void vga_text_put_hex16(uint32_t word_x, uint32_t y, uint16_t value);
void vga_text_put_hex32(uint32_t word_x, uint32_t y, uint32_t value);

#endif
