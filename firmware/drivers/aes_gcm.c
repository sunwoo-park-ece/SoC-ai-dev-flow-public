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

/* Trusted v2 path. Legacy helpers above deliberately retain their old ABI. */
static uint32_t v2_recovery;

static int v2_range(const void *p, uint32_t n)
{
    return n == 0u || (p != 0 && (uintptr_t)p <= UINTPTR_MAX - (n - 1u));
}

static int v2_overlap(const void *a, uint32_t an, const void *b, uint32_t bn)
{
    uintptr_t x = (uintptr_t)a, y = (uintptr_t)b;
    if (an == 0u || bn == 0u) return 0;
    return x <= y ? y - x < an : x - y < bn;
}

static int v2_valid(const aes_gcm_v2_request_t *r, aes_gcm_v2_diagnostic_t *d)
{
    const void *p[7];
    uint32_t n[7], i, j;
    if (!r || !d || !v2_range(r, sizeof(*r)) || !v2_range(d, sizeof(*d))) return 0;
    if ((r->mode != AES_GCM_V2_ENCRYPT && r->mode != AES_GCM_V2_DECRYPT) ||
        r->len > 16u || !r->key || r->key_capacity < 16u ||
        r->input_capacity < r->len || r->output_capacity < r->len) return 0;
    if (r->mode == AES_GCM_V2_ENCRYPT) {
        if (!r->tag_out || r->tag_out_capacity < 16u || r->tag_in || r->tag_in_capacity) return 0;
    } else {
        if (!r->tag_in || r->tag_in_capacity < 16u || r->tag_out || r->tag_out_capacity) return 0;
    }
    p[0] = r->key; n[0] = 16u;
    p[1] = r->input; n[1] = r->len;
    p[2] = r->tag_in; n[2] = r->mode == AES_GCM_V2_DECRYPT ? 16u : 0u;
    p[3] = r; n[3] = sizeof(*r);
    p[4] = r->output; n[4] = r->len;
    p[5] = r->tag_out; n[5] = r->mode == AES_GCM_V2_ENCRYPT ? 16u : 0u;
    p[6] = d; n[6] = sizeof(*d);
    for (i = 0u; i < 7u; ++i) if (!v2_range(p[i], n[i])) return 0;
    /* Read-only input ranges may alias; any writable overlap is unsafe. */
    for (i = 4u; i < 7u; ++i)
        for (j = 0u; j < i; ++j)
            if (v2_overlap(p[i], n[i], p[j], n[j])) return 0;
    return 1;
}

static void v2_diag(aes_gcm_v2_diagnostic_t *d)
{
    d->last_status = 0u;
    d->completed_status_polls = 0u;
    d->completed_maintenance_polls = 0u;
    d->recovery_required = v2_recovery;
    d->start_issued = 0u;
}

static uint32_t v2_status(aes_gcm_v2_diagnostic_t *d)
{
    d->last_status = mmio_read32(AES_GCM_BASE + AES_STATUS);
    return d->last_status;
}

static aes_gcm_v2_result_t v2_result(uint32_t s, aes_gcm_v2_diagnostic_t *d)
{
    const uint32_t prog = AES_STATUS_PROG_ERROR | AES_STATUS_BUSY_WRITE_ERR |
        AES_STATUS_CTRL_CMD_ERR | AES_STATUS_BUSY_START_ERR | AES_STATUS_ZEROIZE_BUSY_ERR;
    if ((s & AES_STATUS_CORE_OVERFLOW) || (s & ~0x3fffu) ||
        ((s & (AES_STATUS_ERROR | AES_STATUS_OP_ERROR)) &&
         !(s & (AES_STATUS_CORE_OVERFLOW | AES_STATUS_AUTH_FAIL | AES_STATUS_LEN_ERROR | prog)))) {
        v2_recovery = 1u;
        d->recovery_required = 1u;
        return AES_GCM_V2_HW_CORE_ERROR;
    }
    if (s & AES_STATUS_AUTH_FAIL) return AES_GCM_V2_AUTH_FAIL;
    if (s & AES_STATUS_LEN_ERROR) return AES_GCM_V2_HW_LEN_ERROR;
    if (s & prog) return AES_GCM_V2_PROGRAM_ERROR;
    return AES_GCM_V2_OK;
}

static uint32_t v2_pack(const uint8_t *p, uint32_t n, uint32_t word)
{
    uint32_t j, v = 0u;
    for (j = 0u; j < 4u; ++j) {
        uint32_t k = word * 4u + j;
        v = (v << 8) | (k < n ? p[k] : 0u);
    }
    return v;
}

static void v2_read_bytes(uint32_t offset, uint8_t *p, uint32_t n)
{
    uint32_t i, j;
    for (i = 0u; i * 4u < n; ++i) {
        uint32_t v = mmio_read32(AES_GCM_BASE + offset + i * 4u);
        for (j = 0u; j < 4u && i * 4u + j < n; ++j)
            p[i * 4u + j] = (uint8_t)(v >> (24u - 8u * j));
    }
}

aes_gcm_v2_result_t aes_gcm_v2_transact(
    const aes_gcm_v2_request_t *r, aes_gcm_v2_diagnostic_t *d)
{
    uint32_t i, s;
    aes_gcm_v2_result_t result;
    if (!v2_valid(r, d)) return AES_GCM_V2_INVALID_ARG;
    v2_diag(d);
    for (i = 0u; i < r->len; ++i) r->output[i] = 0u;
    if (r->mode == AES_GCM_V2_ENCRYPT)
        for (i = 0u; i < 16u; ++i) r->tag_out[i] = 0u;
    if (!r->poll_budget) return AES_GCM_V2_TIMEOUT;
    if (v2_recovery) return AES_GCM_V2_RECOVERY_REQUIRED;
    if (mmio_read32(AES_GCM_BASE + AES_VERSION) != AES_VERSION_V2)
        return AES_GCM_V2_HW_CORE_ERROR;
    s = v2_status(d);
    if (s & (AES_STATUS_BUSY | AES_STATUS_ZEROIZE_ACTIVE)) return AES_GCM_V2_BUSY;
    mmio_write32(AES_GCM_BASE + AES_CTRL, AES_CTRL_CLR_STATUS);
    /* Verify admission again before writing sensitive data. */
    s = v2_status(d);
    if (s & (AES_STATUS_BUSY | AES_STATUS_ZEROIZE_ACTIVE)) return AES_GCM_V2_BUSY;
    result = v2_result(s, d);
    if (result != AES_GCM_V2_OK) return result;
    for (i = 0u; i < 4u; ++i)
        mmio_write32(AES_GCM_BASE + AES_KEY0 + 4u * i, v2_pack(r->key, 16u, i));
    mmio_write32(AES_GCM_BASE + AES_NONCE_DIR, r->nonce_dir);
    mmio_write32(AES_GCM_BASE + AES_SEQ_HI, r->seq_hi);
    mmio_write32(AES_GCM_BASE + AES_SEQ_LO, r->seq_lo);
    mmio_write32(AES_GCM_BASE + AES_LEN, r->len);
    for (i = 0u; i < 4u; ++i)
        mmio_write32(AES_GCM_BASE + AES_PAYLOAD_IN0 + 4u * i, v2_pack(r->input, r->len, i));
    if (r->mode == AES_GCM_V2_DECRYPT)
        for (i = 0u; i < 4u; ++i)
            mmio_write32(AES_GCM_BASE + AES_TAG_IN0 + 4u * i, v2_pack(r->tag_in, 16u, i));
    s = v2_status(d);
    result = v2_result(s, d);
    if (result != AES_GCM_V2_OK) return result;
    if (s & (AES_STATUS_BUSY | AES_STATUS_ZEROIZE_ACTIVE)) return AES_GCM_V2_BUSY;
    if (s & (AES_STATUS_DONE | AES_STATUS_TAG_OK)) return AES_GCM_V2_PROGRAM_ERROR;
    mmio_write32(AES_GCM_BASE + AES_CTRL,
                 r->mode == AES_GCM_V2_ENCRYPT ? 1u : 3u);
    d->start_issued = 1u;
    for (i = 0u; i < r->poll_budget; ++i) {
        s = v2_status(d);
        ++d->completed_status_polls;
        if (s & AES_STATUS_DONE) {
            result = v2_result(s, d);
            if (result != AES_GCM_V2_OK) return result;
            if (!(s & AES_STATUS_TAG_OK) ||
                (s & (AES_STATUS_ERROR | AES_STATUS_BUSY | AES_STATUS_ZEROIZE_ACTIVE))) {
                v2_recovery = d->recovery_required = 1u;
                return AES_GCM_V2_HW_CORE_ERROR;
            }
            v2_read_bytes(AES_PAYLOAD_OUT0, r->output, r->len);
            if (r->mode == AES_GCM_V2_ENCRYPT) v2_read_bytes(AES_TAG_OUT0, r->tag_out, 16u);
            return AES_GCM_V2_OK;
        }
    }
    v2_recovery = d->recovery_required = 1u;
    return AES_GCM_V2_TIMEOUT;
}

aes_gcm_v2_result_t aes_gcm_v2_zeroize(uint32_t budget, aes_gcm_v2_diagnostic_t *d)
{
    uint32_t i, s;
    aes_gcm_v2_result_t result;
    if (!d) return AES_GCM_V2_INVALID_ARG;
    v2_diag(d);
    if (!budget) return AES_GCM_V2_TIMEOUT;
    /* STATUS first: ZEROIZE must never be used as an abort. */
    s = v2_status(d);
    if (s & (AES_STATUS_BUSY | AES_STATUS_ZEROIZE_ACTIVE)) return AES_GCM_V2_BUSY;
    if (mmio_read32(AES_GCM_BASE + AES_VERSION) != AES_VERSION_V2)
        return AES_GCM_V2_HW_CORE_ERROR;
    mmio_write32(AES_GCM_BASE + AES_CTRL, AES_CTRL_ZEROIZE);
    for (i = 0u; i < budget; ++i) {
        s = v2_status(d);
        ++d->completed_maintenance_polls;
        result = v2_result(s, d);
        if (result != AES_GCM_V2_OK) return result;
        if (!(s & (AES_STATUS_BUSY | AES_STATUS_ZEROIZE_ACTIVE))) {
            if (s != 0u) return AES_GCM_V2_HW_CORE_ERROR;
            /* Contiguous canonical sensitive words KEY0 through HDR3. */
            for (i = AES_KEY0; i <= AES_HDR0 + 12u; i += 4u)
                if (mmio_read32(AES_GCM_BASE + i) != 0u) return AES_GCM_V2_HW_CORE_ERROR;
            return AES_GCM_V2_OK;
        }
    }
    return AES_GCM_V2_TIMEOUT;
}

aes_gcm_v2_result_t aes_gcm_v2_acknowledge_external_reset(aes_gcm_v2_diagnostic_t *d)
{
    if (!d) return AES_GCM_V2_INVALID_ARG;
    v2_diag(d);
    /* No authorized independent reset-completion witness in this interface. */
    return v2_recovery ? AES_GCM_V2_RECOVERY_REQUIRED : AES_GCM_V2_OK;
}
