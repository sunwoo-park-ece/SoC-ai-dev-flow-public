#ifndef LORA_ACK_H
#define LORA_ACK_H

#include <stdint.h>

#define LORA_DATA_MAGIC  0xa55au
#define LORA_ACK_MAGIC   0x5aa5u
#define LORA_DIR_CTRL_TO_CAR 0x00u
#define LORA_DIR_CAR_TO_CTRL 0x01u

typedef struct {
    uint32_t session_nonce;
    uint32_t seq_hi;
    uint32_t seq_lo;
    uint8_t dir;
} lora_link_state_t;

void lora_link_init(lora_link_state_t *state, uint32_t session_nonce, uint8_t dir);
void lora_link_advance_seq(lora_link_state_t *state);
uint32_t lora_nonce_dir_word(const lora_link_state_t *state);
uint32_t lora_build_plain_command(char ascii_cmd, uint16_t x_raw, uint16_t y_raw,
                                  uint8_t out16[16]);

#endif
