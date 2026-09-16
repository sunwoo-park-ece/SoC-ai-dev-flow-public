#include "lora_ack.h"

void lora_link_init(lora_link_state_t *state, uint32_t session_nonce, uint8_t dir)
{
    state->session_nonce = session_nonce & 0x00ffffffu;
    state->seq_hi = 0u;
    state->seq_lo = 1u;
    state->dir = dir;
}

void lora_link_advance_seq(lora_link_state_t *state)
{
    state->seq_lo++;
    if (state->seq_lo == 0u) {
        state->seq_hi++;
    }
}

uint32_t lora_nonce_dir_word(const lora_link_state_t *state)
{
    return ((state->session_nonce & 0x00ffffffu) << 8) | (uint32_t)state->dir;
}

uint32_t lora_build_plain_command(char ascii_cmd, uint16_t x_raw, uint16_t y_raw,
                                  uint8_t out16[16])
{
    uint32_t i;
    for (i = 0u; i < 16u; i++) {
        out16[i] = 0u;
    }

    out16[0] = (uint8_t)ascii_cmd;
    out16[1] = (uint8_t)(x_raw & 0xffu);
    out16[2] = (uint8_t)((x_raw >> 8) & 0xffu);
    out16[3] = (uint8_t)(y_raw & 0xffu);
    out16[4] = (uint8_t)((y_raw >> 8) & 0xffu);
    return 16u;
}
