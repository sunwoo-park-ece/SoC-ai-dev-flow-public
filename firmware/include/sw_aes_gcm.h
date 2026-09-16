#ifndef SW_AES_GCM_H
#define SW_AES_GCM_H

#include <stdint.h>

void sw_aes_gcm_encrypt_128(const uint8_t key[16],
                            const uint8_t iv[12],
                            const uint8_t *aad,
                            uint32_t aad_len,
                            const uint8_t *pt,
                            uint32_t pt_len,
                            uint8_t *ct,
                            uint8_t tag[16]);

int sw_aes_gcm_decrypt_verify_128(const uint8_t key[16],
                                  const uint8_t iv[12],
                                  const uint8_t *aad,
                                  uint32_t aad_len,
                                  const uint8_t *ct,
                                  uint32_t ct_len,
                                  const uint8_t tag_in[16],
                                  uint8_t *pt_out);

#endif
