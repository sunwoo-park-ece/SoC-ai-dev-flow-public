#ifndef AES_GCM_H
#define AES_GCM_H

#include <stdint.h>

#define AES_CTRL_START       (1u << 0)
#define AES_CTRL_DECRYPT     (1u << 1)
#define AES_CTRL_CLR_STATUS  (1u << 2)

#define AES_STATUS_BUSY      (1u << 0)
#define AES_STATUS_DONE      (1u << 1)
#define AES_STATUS_TAG_OK    (1u << 2)
#define AES_STATUS_ERROR     (1u << 3)

void aes_gcm_set_key_words(const uint32_t key_words[4]);
void aes_gcm_set_iv(uint32_t nonce_dir, uint32_t seq_hi, uint32_t seq_lo);
void aes_gcm_set_payload_words(const uint32_t payload_words[4]);
void aes_gcm_set_tag_words(const uint32_t tag_words[4]);
void aes_gcm_get_payload_words(uint32_t payload_words[4]);
void aes_gcm_get_tag_words(uint32_t tag_words[4]);
uint32_t aes_gcm_status(void);
void aes_gcm_clear_status(void);
void aes_gcm_start_encrypt(uint32_t len);
void aes_gcm_start_decrypt(uint32_t len);
void aes_gcm_wait_done(void);

#endif
