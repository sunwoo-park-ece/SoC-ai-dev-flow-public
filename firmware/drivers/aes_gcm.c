#include "aes_gcm.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

static void aes_write_words(uint32_t offset, const uint32_t words[4])
{
    uint32_t i;
    for (i = 0u; i < 4u; i++) {
        mmio_write32(AES_GCM_BASE + offset + (i * 4u), words[i]);
    }
}

static void aes_read_words(uint32_t offset, uint32_t words[4])
{
    uint32_t i;
    for (i = 0u; i < 4u; i++) {
        words[i] = mmio_read32(AES_GCM_BASE + offset + (i * 4u));
    }
}

void aes_gcm_set_key_words(const uint32_t key_words[4])
{
    aes_write_words(AES_KEY0, key_words);
}

void aes_gcm_set_iv(uint32_t nonce_dir, uint32_t seq_hi, uint32_t seq_lo)
{
    mmio_write32(AES_GCM_BASE + AES_NONCE_DIR, nonce_dir);
    mmio_write32(AES_GCM_BASE + AES_SEQ_HI, seq_hi);
    mmio_write32(AES_GCM_BASE + AES_SEQ_LO, seq_lo);
}

void aes_gcm_set_payload_words(const uint32_t payload_words[4])
{
    aes_write_words(AES_PAYLOAD_IN0, payload_words);
}

void aes_gcm_set_tag_words(const uint32_t tag_words[4])
{
    aes_write_words(AES_TAG_IN0, tag_words);
}

void aes_gcm_get_payload_words(uint32_t payload_words[4])
{
    aes_read_words(AES_PAYLOAD_OUT0, payload_words);
}

void aes_gcm_get_tag_words(uint32_t tag_words[4])
{
    aes_read_words(AES_TAG_OUT0, tag_words);
}

uint32_t aes_gcm_status(void)
{
    return mmio_read32(AES_GCM_BASE + AES_STATUS);
}

void aes_gcm_clear_status(void)
{
    mmio_write32(AES_GCM_BASE + AES_CTRL, AES_CTRL_CLR_STATUS);
}

void aes_gcm_start_encrypt(uint32_t len)
{
    mmio_write32(AES_GCM_BASE + AES_LEN, len & 0xffffu);
    mmio_write32(AES_GCM_BASE + AES_CTRL, AES_CTRL_START);
}

void aes_gcm_start_decrypt(uint32_t len)
{
    mmio_write32(AES_GCM_BASE + AES_LEN, len & 0xffffu);
    mmio_write32(AES_GCM_BASE + AES_CTRL, AES_CTRL_START | AES_CTRL_DECRYPT);
}

void aes_gcm_wait_done(void)
{
    while ((aes_gcm_status() & AES_STATUS_DONE) == 0u) {
    }
}
