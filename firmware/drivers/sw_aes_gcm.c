#include "sw_aes_gcm.h"

static const uint8_t AES_SBOX[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static const uint8_t AES_RCON[11] = {
    0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36
};

static void bytes_zero(uint8_t *dst, uint32_t len)
{
    uint32_t i;
    for (i = 0u; i < len; i++) {
        dst[i] = 0u;
    }
}

static void bytes_copy(uint8_t *dst, const uint8_t *src, uint32_t len)
{
    uint32_t i;
    for (i = 0u; i < len; i++) {
        dst[i] = src[i];
    }
}

static int bytes_equal(const uint8_t *a, const uint8_t *b, uint32_t len)
{
    uint32_t i;
    uint8_t diff = 0u;
    for (i = 0u; i < len; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }
    return diff == 0u;
}

static uint8_t xtime(uint8_t x)
{
    uint8_t x2 = (uint8_t)(x << 1);
    if ((x & 0x80u) != 0u) {
        x2 ^= 0x1bu;
    }
    return x2;
}

static void aes_add_round_key(uint8_t state[16], const uint8_t *rk)
{
    uint32_t i;
    for (i = 0u; i < 16u; i++) {
        state[i] ^= rk[i];
    }
}

static void aes_sub_bytes(uint8_t state[16])
{
    uint32_t i;
    for (i = 0u; i < 16u; i++) {
        state[i] = AES_SBOX[state[i]];
    }
}

static void aes_shift_rows(uint8_t state[16])
{
    uint8_t t;

    t = state[1];
    state[1] = state[5];
    state[5] = state[9];
    state[9] = state[13];
    state[13] = t;

    t = state[2];
    state[2] = state[10];
    state[10] = t;
    t = state[6];
    state[6] = state[14];
    state[14] = t;

    t = state[3];
    state[3] = state[15];
    state[15] = state[11];
    state[11] = state[7];
    state[7] = t;
}

static void aes_mix_columns(uint8_t state[16])
{
    uint32_t c;
    for (c = 0u; c < 4u; c++) {
        uint32_t base = c << 2;
        uint8_t a0 = state[base + 0u];
        uint8_t a1 = state[base + 1u];
        uint8_t a2 = state[base + 2u];
        uint8_t a3 = state[base + 3u];
        uint8_t x0 = xtime(a0);
        uint8_t x1 = xtime(a1);
        uint8_t x2 = xtime(a2);
        uint8_t x3 = xtime(a3);

        state[base + 0u] = (uint8_t)(x0 ^ (uint8_t)(x1 ^ a1) ^ a2 ^ a3);
        state[base + 1u] = (uint8_t)(a0 ^ x1 ^ (uint8_t)(x2 ^ a2) ^ a3);
        state[base + 2u] = (uint8_t)(a0 ^ a1 ^ x2 ^ (uint8_t)(x3 ^ a3));
        state[base + 3u] = (uint8_t)((uint8_t)(x0 ^ a0) ^ a1 ^ a2 ^ x3);
    }
}

static void aes128_key_expand(const uint8_t key[16], uint8_t round_key[176])
{
    uint32_t i;
    uint32_t bytes_gen = 16u;
    uint32_t rcon_iter = 1u;
    uint8_t temp[4];

    for (i = 0u; i < 16u; i++) {
        round_key[i] = key[i];
    }

    while (bytes_gen < 176u) {
        temp[0] = round_key[bytes_gen - 4u];
        temp[1] = round_key[bytes_gen - 3u];
        temp[2] = round_key[bytes_gen - 2u];
        temp[3] = round_key[bytes_gen - 1u];

        if ((bytes_gen & 0x0fu) == 0u) {
            uint8_t t = temp[0];
            temp[0] = temp[1];
            temp[1] = temp[2];
            temp[2] = temp[3];
            temp[3] = t;

            temp[0] = AES_SBOX[temp[0]];
            temp[1] = AES_SBOX[temp[1]];
            temp[2] = AES_SBOX[temp[2]];
            temp[3] = AES_SBOX[temp[3]];
            temp[0] ^= AES_RCON[rcon_iter];
            rcon_iter++;
        }

        for (i = 0u; i < 4u; i++) {
            round_key[bytes_gen] = (uint8_t)(round_key[bytes_gen - 16u] ^ temp[i]);
            bytes_gen++;
        }
    }
}

static void aes128_encrypt_block(const uint8_t round_key[176], const uint8_t in[16], uint8_t out[16])
{
    uint8_t state[16];
    uint32_t i;
    uint32_t round;

    for (i = 0u; i < 16u; i++) {
        state[i] = in[i];
    }

    aes_add_round_key(state, &round_key[0]);

    for (round = 1u; round <= 9u; round++) {
        aes_sub_bytes(state);
        aes_shift_rows(state);
        aes_mix_columns(state);
        aes_add_round_key(state, &round_key[round << 4]);
    }

    aes_sub_bytes(state);
    aes_shift_rows(state);
    aes_add_round_key(state, &round_key[160]);

    for (i = 0u; i < 16u; i++) {
        out[i] = state[i];
    }
}

static void shift_right_one_bit(uint8_t v[16])
{
    uint8_t carry = 0u;
    uint32_t i;
    for (i = 0u; i < 16u; i++) {
        uint8_t new_carry = (uint8_t)(v[i] & 1u);
        v[i] = (uint8_t)((v[i] >> 1) | (uint8_t)(carry << 7));
        carry = new_carry;
    }
}

static void gf_mul_128(const uint8_t x[16], const uint8_t y[16], uint8_t out[16])
{
    uint8_t z[16];
    uint8_t v[16];
    uint32_t i;
    int bit;

    bytes_zero(z, 16u);
    bytes_copy(v, y, 16u);

    for (i = 0u; i < 16u; i++) {
        uint8_t xi = x[i];
        for (bit = 7; bit >= 0; bit--) {
            uint8_t mask = (uint8_t)(1u << (uint32_t)bit);
            if ((xi & mask) != 0u) {
                uint32_t j;
                for (j = 0u; j < 16u; j++) {
                    z[j] ^= v[j];
                }
            }

            {
                uint8_t lsb = (uint8_t)(v[15] & 1u);
                shift_right_one_bit(v);
                if (lsb != 0u) {
                    v[0] ^= 0xe1u;
                }
            }
        }
    }

    bytes_copy(out, z, 16u);
}

static void ghash_update(uint8_t y[16], const uint8_t h[16], const uint8_t block[16])
{
    uint8_t tmp[16];
    uint32_t i;
    for (i = 0u; i < 16u; i++) {
        tmp[i] = (uint8_t)(y[i] ^ block[i]);
    }
    gf_mul_128(tmp, h, y);
}

static void ghash(const uint8_t h[16], const uint8_t *aad, uint32_t aad_len,
                  const uint8_t *c, uint32_t c_len, uint8_t out[16])
{
    uint8_t y[16];
    uint8_t block[16];
    uint8_t len_block[16];
    uint32_t i;
    uint32_t off;

    bytes_zero(y, 16u);

    off = 0u;
    while (off < aad_len) {
        uint32_t take = aad_len - off;
        if (take > 16u) {
            take = 16u;
        }
        bytes_zero(block, 16u);
        for (i = 0u; i < take; i++) {
            block[i] = aad[off + i];
        }
        ghash_update(y, h, block);
        off += take;
    }

    off = 0u;
    while (off < c_len) {
        uint32_t take = c_len - off;
        if (take > 16u) {
            take = 16u;
        }
        bytes_zero(block, 16u);
        for (i = 0u; i < take; i++) {
            block[i] = c[off + i];
        }
        ghash_update(y, h, block);
        off += take;
    }

    bytes_zero(len_block, 16u);
    {
        uint32_t aad_bits = aad_len << 3;
        uint32_t c_bits = c_len << 3;
        len_block[4] = (uint8_t)(aad_bits >> 24);
        len_block[5] = (uint8_t)(aad_bits >> 16);
        len_block[6] = (uint8_t)(aad_bits >> 8);
        len_block[7] = (uint8_t)(aad_bits >> 0);
        len_block[12] = (uint8_t)(c_bits >> 24);
        len_block[13] = (uint8_t)(c_bits >> 16);
        len_block[14] = (uint8_t)(c_bits >> 8);
        len_block[15] = (uint8_t)(c_bits >> 0);
    }
    ghash_update(y, h, len_block);

    bytes_copy(out, y, 16u);
}

static void inc32_be(uint8_t counter[16])
{
    int i;
    for (i = 15; i >= 12; i--) {
        counter[i] = (uint8_t)(counter[i] + 1u);
        if (counter[i] != 0u) {
            break;
        }
    }
}

void sw_aes_gcm_encrypt_128(const uint8_t key[16],
                            const uint8_t iv[12],
                            const uint8_t *aad,
                            uint32_t aad_len,
                            const uint8_t *pt,
                            uint32_t pt_len,
                            uint8_t *ct,
                            uint8_t tag[16])
{
    uint8_t round_key[176];
    uint8_t h[16];
    uint8_t j0[16];
    uint8_t ctr[16];
    uint8_t stream[16];
    uint8_t s[16];
    uint8_t e_j0[16];
    uint8_t zeros[16];
    uint32_t off;
    uint32_t i;

    aes128_key_expand(key, round_key);
    bytes_zero(zeros, 16u);
    aes128_encrypt_block(round_key, zeros, h);

    bytes_copy(j0, iv, 12u);
    j0[12] = 0u;
    j0[13] = 0u;
    j0[14] = 0u;
    j0[15] = 1u;
    bytes_copy(ctr, j0, 16u);
    inc32_be(ctr);

    off = 0u;
    while (off < pt_len) {
        uint32_t take = pt_len - off;
        if (take > 16u) {
            take = 16u;
        }
        aes128_encrypt_block(round_key, ctr, stream);
        for (i = 0u; i < take; i++) {
            ct[off + i] = (uint8_t)(pt[off + i] ^ stream[i]);
        }
        inc32_be(ctr);
        off += take;
    }

    ghash(h, aad, aad_len, ct, pt_len, s);
    aes128_encrypt_block(round_key, j0, e_j0);
    for (i = 0u; i < 16u; i++) {
        tag[i] = (uint8_t)(e_j0[i] ^ s[i]);
    }
}

int sw_aes_gcm_decrypt_verify_128(const uint8_t key[16],
                                  const uint8_t iv[12],
                                  const uint8_t *aad,
                                  uint32_t aad_len,
                                  const uint8_t *ct,
                                  uint32_t ct_len,
                                  const uint8_t tag_in[16],
                                  uint8_t *pt_out)
{
    uint8_t round_key[176];
    uint8_t h[16];
    uint8_t j0[16];
    uint8_t ctr[16];
    uint8_t stream[16];
    uint8_t s[16];
    uint8_t e_j0[16];
    uint8_t tag_exp[16];
    uint8_t zeros[16];
    uint32_t off;
    uint32_t i;

    aes128_key_expand(key, round_key);
    bytes_zero(zeros, 16u);
    aes128_encrypt_block(round_key, zeros, h);

    bytes_copy(j0, iv, 12u);
    j0[12] = 0u;
    j0[13] = 0u;
    j0[14] = 0u;
    j0[15] = 1u;

    ghash(h, aad, aad_len, ct, ct_len, s);
    aes128_encrypt_block(round_key, j0, e_j0);
    for (i = 0u; i < 16u; i++) {
        tag_exp[i] = (uint8_t)(e_j0[i] ^ s[i]);
    }

    if (!bytes_equal(tag_exp, tag_in, 16u)) {
        bytes_zero(pt_out, ct_len);
        return 0;
    }

    bytes_copy(ctr, j0, 16u);
    inc32_be(ctr);
    off = 0u;
    while (off < ct_len) {
        uint32_t take = ct_len - off;
        if (take > 16u) {
            take = 16u;
        }
        aes128_encrypt_block(round_key, ctr, stream);
        for (i = 0u; i < take; i++) {
            pt_out[off + i] = (uint8_t)(ct[off + i] ^ stream[i]);
        }
        inc32_be(ctr);
        off += take;
    }

    return 1;
}
