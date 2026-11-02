#ifndef AES_GCM_H
#define AES_GCM_H

#include <stdint.h>

#define AES_CTRL_START       (1u << 0)
#define AES_CTRL_DECRYPT     (1u << 1)
#define AES_CTRL_CLR_STATUS  (1u << 2)

#define AES_CTRL_ZEROIZE     (1u << 3)

#define AES_STATUS_BUSY      (1u << 0)
#define AES_STATUS_DONE      (1u << 1)
#define AES_STATUS_TAG_OK    (1u << 2)
#define AES_STATUS_ERROR     (1u << 3)

#define AES_STATUS_OP_ERROR       (1u << 4)
#define AES_STATUS_PROG_ERROR     (1u << 5)
#define AES_STATUS_LEN_ERROR      (1u << 6)
#define AES_STATUS_AUTH_FAIL      (1u << 7)
#define AES_STATUS_CORE_OVERFLOW  (1u << 8)
#define AES_STATUS_BUSY_WRITE_ERR (1u << 9)
#define AES_STATUS_CTRL_CMD_ERR   (1u << 10)
#define AES_STATUS_BUSY_START_ERR (1u << 11)
#define AES_STATUS_ZEROIZE_BUSY_ERR (1u << 12)
#define AES_STATUS_ZEROIZE_ACTIVE (1u << 13)

typedef enum {
    AES_GCM_V2_ENCRYPT = 0, AES_GCM_V2_DECRYPT = 1
} aes_gcm_v2_mode_t;

typedef enum {
    AES_GCM_V2_OK = 0, AES_GCM_V2_INVALID_ARG, AES_GCM_V2_BUSY,
    AES_GCM_V2_TIMEOUT, AES_GCM_V2_HW_LEN_ERROR, AES_GCM_V2_AUTH_FAIL,
    AES_GCM_V2_HW_CORE_ERROR, AES_GCM_V2_PROGRAM_ERROR,
    AES_GCM_V2_RECOVERY_REQUIRED
} aes_gcm_v2_result_t;

typedef struct {
    aes_gcm_v2_mode_t mode;
    const uint8_t *key;
    uint32_t key_capacity;
    uint32_t nonce_dir, seq_hi, seq_lo;
    const uint8_t *input;
    uint32_t input_capacity;
    const uint8_t *tag_in;
    uint32_t tag_in_capacity;
    uint8_t *output;
    uint32_t output_capacity;
    uint8_t *tag_out;
    uint32_t tag_out_capacity;
    uint32_t len;
    uint32_t poll_budget;
} aes_gcm_v2_request_t;

typedef struct {
    uint32_t last_status;
    uint32_t completed_status_polls;
    uint32_t completed_maintenance_polls;
    uint32_t recovery_required;
    uint32_t start_issued;
} aes_gcm_v2_diagnostic_t;

/* One serialized owner; not reentrant, no competing raw clients/ISRs.
 * Caller must supply actual accessible storage, not merely claimed capacities.
 * KEY and mode-specific tag require 16 bytes; input/output require LEN bytes.
 * LEN=0 permits NULL input/output. Unused tag pointer/capacity must be NULL/0.
 * Output ranges must not overlap each other, any input, request or diagnostic;
 * diagnostic must not overlap request or buffers. Invalid args: zero MMIO,
 * no unsafe output access. Valid args: wipe LEN output bytes and encrypt tag
 * before MMIO; copy only on authenticated success. MSW words/MSB bytes.
 * Budget counts completed post-START reads, not time or a stalled bus access.
 * Protocol owns unique (key,IV), persistence/replay; no IV allocation or retry.
 * Timeout after START/fatal core error latches recovery; ZEROIZE cannot clear.
 */
aes_gcm_v2_result_t aes_gcm_v2_transact(
    const aes_gcm_v2_request_t *request, aes_gcm_v2_diagnostic_t *diagnostic);
aes_gcm_v2_result_t aes_gcm_v2_zeroize(
    uint32_t maintenance_poll_budget, aes_gcm_v2_diagnostic_t *diagnostic);
/* Acknowledgement only, not a reset command. No independent platform reset
 * completion proof exists in this interface: a latched driver stays blocked.
 */
aes_gcm_v2_result_t aes_gcm_v2_acknowledge_external_reset(
    aes_gcm_v2_diagnostic_t *diagnostic);

/* ALL helpers below are LEGACY/UNSAFE/DEBUG ONLY, including raw setters/status,
 * unbounded wait_done and unauthenticated payload/tag getters. Kept solely for
 * historical source/link compatibility. Trusted v2 callers must not use them.
 * Their presence does not remediate historical nonce or output security.
 */
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
