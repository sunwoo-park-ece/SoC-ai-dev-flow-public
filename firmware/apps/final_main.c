#include <stdint.h>

#include "aes_gcm.h"
#include "led.h"
#include "sw.h"
#include "hex_display.h"
#include "joystick.h"
#include "lora_uart.h"
#include "timer.h"
#include "uart.h"
#include "vga_text.h"
#include "vram.h"

#define SYS_CLK_HZ              50000000u
#define LOOP_DELAY_CYCLES       1000u
#define MANUAL_PERIOD_CYCLES    (SYS_CLK_HZ / 2u)
#define TELEMETRY_PERIOD_CYCLES SYS_CLK_HZ
#define RENDER_PERIOD_CYCLES    SYS_CLK_HZ
#define HEARTBEAT_PERIOD_CYCLES (SYS_CLK_HZ / 2u)
#define AES_HW_WAIT_LOOPS       1000000u
#define TIMER_TIMEBASE_COMPARE  UINT32_MAX

/*
 * Timeout policy for the final demo.
 * Each wait-loop includes timer_delay_cycles(LOOP_DELAY_CYCLES). At 50 MHz,
 * loops * 1000 cycles is the lower-bound delay, with firmware loop overhead
 * adding margin.
 */
#define MANUAL_ACK_WAIT_LOOPS       5000u  /* about 0.1 s lower bound */
#define MODE_ACK_WAIT_LOOPS        50000u  /* about 1.0 s lower bound */
#define WAYPOINT_ACK_WAIT_LOOPS    75000u  /* about 1.5 s lower bound */
#define TELEMETRY_WAIT_LOOPS       25000u  /* about 0.5 s lower bound */

#define FRAME_SOF               0x7eu
#define FRAME_EOF               0x0au
#define FRAME_MAX_PAYLOAD       64u
#define SECURE_BLOCK_LEN        16u
#define SECURE_WIRE_LEN         46u

#define TYPE_MODE_CHANGE        0x10u
#define TYPE_MANUAL_CMD         0x11u
#define TYPE_WAYPOINT_CMD       0x12u
#define TYPE_TELEMETRY_REQ      0x13u
#define TYPE_PC_WAYPOINT        0x21u
#define TYPE_SECURE_C2R         0x30u
#define TYPE_MANUAL_ACK         0x81u
#define TYPE_MODE_ACK           0x90u
#define TYPE_WAYPOINT_ACK       0x92u
#define TYPE_TELEMETRY_DATA     0x93u
#define TYPE_SECURE_R2C         0xb0u

#define AES_SESSION_NONCE       0x102030u
#define AES_DIR_C2R             0x00u
#define AES_DIR_R2C             0x01u
#define AES_NONCE_DIR_C2R       ((AES_SESSION_NONCE << 8) | AES_DIR_C2R)
#define AES_NONCE_DIR_R2C       ((AES_SESSION_NONCE << 8) | AES_DIR_R2C)

#define MODE_MANUAL             0u
#define MODE_WAYPOINT           1u
#define MODE_UNKNOWN            0xffu

#define ERR_NONE                0u
#define ERR_ACK_TIMEOUT         1u
#define ERR_BAD_FRAME           3u
#define ERR_MODE_SYNC           5u
#define ERR_TAG_FAIL            6u
#define ERR_UART_TIMEOUT        7u

#define VGA_WORDS_PER_ROW       20u
#define VGA_WIDTH_PX            640u
#define VGA_HEIGHT_PX           480u
#define RC_MAP_START_X          480
#define RC_MAP_START_Y          240
#define RC_MAP_SCALE_CM_PER_PX  4

typedef struct {
    uint8_t type;
    uint8_t len;
    uint8_t payload[FRAME_MAX_PAYLOAD];
} frame_t;

typedef struct {
    uint8_t state;
    uint8_t type;
    uint8_t len;
    uint8_t idx;
    uint8_t sum;
    uint8_t payload[FRAME_MAX_PAYLOAD];
} frame_parser_t;

typedef struct {
    uint32_t x;
    uint32_t y;
    uint16_t id;
    uint8_t valid;
} waypoint_t;

typedef struct {
    uint16_t seq;
    int16_t ekf_x_cm;
    int16_t ekf_y_cm;
    int16_t gps_x_cm;
    int16_t gps_y_cm;
    uint8_t rc_mode;
    uint8_t flags;
    uint8_t heading_u8;
    uint8_t valid;
} telemetry_t;

static frame_parser_t pc_parser;
static frame_parser_t lora_parser;
static waypoint_t waypoint;
static telemetry_t telemetry;

static uint8_t active_mode = MODE_UNKNOWN;
static uint8_t requested_mode = MODE_MANUAL;
static uint8_t last_error = ERR_NONE;
static uint8_t retry_count = 0u;
static uint8_t last_state = 0u;
static char last_cmd = ' ';
static uint32_t tx_seq = 1u;
static uint32_t rx_seq = 0u;
static uint8_t heartbeat = 0u;
static uint8_t manual_ack_seen = 0u;
static uint8_t lora_rx_seen = 0u;
static uint8_t lora_tx_seen = 0u;
static uint32_t current_switches = 0u;
static uint32_t last_heartbeat_cycle = 0u;
static int32_t prev_map_x_cm = 0;
static int32_t prev_map_y_cm = 0;
static uint8_t prev_map_valid = 0u;

/* Debug output must never stall the control application indefinitely. */
static void app_uart1_putc(char c)
{
    if (uart1_putc_timeout(c, UART_DEFAULT_POLL_BUDGET) != UART_RESULT_SUCCESS) {
        last_error = ERR_UART_TIMEOUT;
    }
}

static void app_uart1_puts(const char *s)
{
    if (uart1_puts_timeout(s, UART_DEFAULT_POLL_BUDGET) != UART_RESULT_SUCCESS) {
        last_error = ERR_UART_TIMEOUT;
    }
}

static void app_uart1_put_hex32(uint32_t value)
{
    if (uart1_put_hex32_timeout(value, UART_DEFAULT_POLL_BUDGET) !=
        UART_RESULT_SUCCESS) {
        last_error = ERR_UART_TIMEOUT;
    }
}

#define uart1_putc      app_uart1_putc
#define uart1_puts      app_uart1_puts
#define uart1_put_hex32 app_uart1_put_hex32

static const uint8_t aes_demo_key_bytes[16] = {
    0x00u, 0x01u, 0x02u, 0x03u, 0x04u, 0x05u, 0x06u, 0x07u,
    0x08u, 0x09u, 0x0au, 0x0bu, 0x0cu, 0x0du, 0x0eu, 0x0fu
};

static void update_monitor(void);
static void update_health_leds(void);

static uint32_t demo_time_cycles(void)
{
    /*
     * APB_TIMER is a one-shot. Re-arm it explicitly after the full 32-bit
     * span; unsigned subtraction preserves the application's wrap handling.
     */
    if ((timer_status() & TIMER_STATUS_READY) != 0u) {
        timer_clear_ready();
        timer_start(TIMER_TIMEBASE_COMPARE);
    }
    return timer_count();
}

static int elapsed_cycles(uint32_t now, uint32_t last, uint32_t period)
{
    return (uint32_t)(now - last) >= period;
}

static void service_health_tasks(void)
{
    uint32_t now = demo_time_cycles();

    current_switches = sw_read();
    if (elapsed_cycles(now, last_heartbeat_cycle, HEARTBEAT_PERIOD_CYCLES)) {
        last_heartbeat_cycle = now;
        heartbeat ^= 1u;
    }

    update_monitor();
    update_health_leds();
}

static void put_u16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xffu);
    p[1] = (uint8_t)((v >> 8) & 0xffu);
}

static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xffu);
    p[1] = (uint8_t)((v >> 8) & 0xffu);
    p[2] = (uint8_t)((v >> 16) & 0xffu);
    p[3] = (uint8_t)((v >> 24) & 0xffu);
}

static uint16_t get_u16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t get_u32(const uint8_t *p)
{
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void parser_reset(frame_parser_t *p)
{
    p->state = 0u;
    p->type = 0u;
    p->len = 0u;
    p->idx = 0u;
    p->sum = 0u;
}

static int parser_feed(frame_parser_t *p, uint8_t byte, frame_t *out)
{
    switch (p->state) {
    case 0u:
        if (byte == FRAME_SOF) {
            p->state = 1u;
            p->sum = 0u;
            p->idx = 0u;
        }
        break;
    case 1u:
        p->type = byte;
        p->sum = byte;
        p->state = 2u;
        break;
    case 2u:
        p->len = byte;
        p->sum = (uint8_t)(p->sum + byte);
        if (p->len > FRAME_MAX_PAYLOAD) {
            parser_reset(p);
            last_error = ERR_BAD_FRAME;
        } else {
            p->idx = 0u;
            p->state = (p->len == 0u) ? 4u : 3u;
        }
        break;
    case 3u:
        p->payload[p->idx++] = byte;
        p->sum = (uint8_t)(p->sum + byte);
        if (p->idx >= p->len) {
            p->state = 4u;
        }
        break;
    case 4u:
        if (byte == p->sum) {
            p->state = 5u;
        } else {
            parser_reset(p);
            last_error = ERR_BAD_FRAME;
        }
        break;
    case 5u:
        if (byte == FRAME_EOF) {
            uint32_t i;
            out->type = p->type;
            out->len = p->len;
            for (i = 0u; i < p->len; i++) {
                out->payload[i] = p->payload[i];
            }
            parser_reset(p);
            return 1;
        }
        parser_reset(p);
        last_error = ERR_BAD_FRAME;
        break;
    default:
        parser_reset(p);
        break;
    }
    return 0;
}

static void build_frame(uint8_t type, const uint8_t *payload, uint8_t len,
                        uint8_t *out, uint8_t *out_len)
{
    uint8_t sum = (uint8_t)(type + len);
    uint8_t i;

    out[0] = FRAME_SOF;
    out[1] = type;
    out[2] = len;
    for (i = 0u; i < len; i++) {
        out[3u + i] = payload[i];
        sum = (uint8_t)(sum + payload[i]);
    }
    out[3u + len] = sum;
    out[4u + len] = FRAME_EOF;
    *out_len = (uint8_t)(5u + len);
}

static void put_u16_be(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)((v >> 8) & 0xffu);
    p[1] = (uint8_t)(v & 0xffu);
}

static void put_u32_be(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)((v >> 24) & 0xffu);
    p[1] = (uint8_t)((v >> 16) & 0xffu);
    p[2] = (uint8_t)((v >> 8) & 0xffu);
    p[3] = (uint8_t)(v & 0xffu);
}

static uint16_t get_u16_be(const uint8_t *p)
{
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static uint32_t get_u32_be(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) |
           ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) |
           (uint32_t)p[3];
}

static void bytes_to_words_be_16(const uint8_t bytes[16], uint32_t words[4])
{
    uint32_t i;
    uint32_t j = 0u;

    for (i = 0u; i < 4u; i++) {
        words[i] = ((uint32_t)bytes[j] << 24) |
                   ((uint32_t)bytes[j + 1u] << 16) |
                   ((uint32_t)bytes[j + 2u] << 8) |
                   (uint32_t)bytes[j + 3u];
        j += 4u;
    }
}

static void words_to_bytes_be_16(const uint32_t words[4], uint8_t bytes[16])
{
    uint32_t i;
    uint32_t j = 0u;

    for (i = 0u; i < 4u; i++) {
        uint32_t w = words[i];
        bytes[j++] = (uint8_t)((w >> 24) & 0xffu);
        bytes[j++] = (uint8_t)((w >> 16) & 0xffu);
        bytes[j++] = (uint8_t)((w >> 8) & 0xffu);
        bytes[j++] = (uint8_t)(w & 0xffu);
    }
}

static int lora_send_frame(uint8_t type, const uint8_t *payload, uint8_t len)
{
    uint8_t frame[FRAME_MAX_PAYLOAD + 5u];
    uint8_t frame_len;
    build_frame(type, payload, len, frame, &frame_len);
    if (lora_uart_send_bytes(frame, frame_len) != LORA_UART_RESULT_SUCCESS) {
        last_error = ERR_UART_TIMEOUT;
        return 0;
    }
    lora_tx_seen ^= 1u;
    return 1;
}

static int aes_encrypt_block(uint32_t nonce_dir, uint32_t seq_hi, uint32_t seq_lo,
                             const uint8_t plain[SECURE_BLOCK_LEN],
                             uint8_t cipher[SECURE_BLOCK_LEN],
                             uint8_t tag[SECURE_BLOCK_LEN])
{
    uint32_t key_words[4];
    uint32_t payload_words[4];
    uint32_t cipher_words[4];
    uint32_t tag_words[4];
    static const uint32_t zero_tag_words[4] = {0u, 0u, 0u, 0u};
    uint32_t i;
    uint32_t status;

    bytes_to_words_be_16(aes_demo_key_bytes, key_words);
    bytes_to_words_be_16(plain, payload_words);

    aes_gcm_set_key_words(key_words);
    aes_gcm_set_iv(nonce_dir, seq_hi, seq_lo);
    aes_gcm_set_payload_words(payload_words);
    aes_gcm_set_tag_words(zero_tag_words);
    aes_gcm_clear_status();
    aes_gcm_start_encrypt(SECURE_BLOCK_LEN);

    for (i = 0u; i < AES_HW_WAIT_LOOPS; i++) {
        status = aes_gcm_status();
        if ((status & AES_STATUS_DONE) != 0u) {
            if ((status & AES_STATUS_ERROR) != 0u) {
                last_error = ERR_TAG_FAIL;
                return 0;
            }
            aes_gcm_get_payload_words(cipher_words);
            aes_gcm_get_tag_words(tag_words);
            words_to_bytes_be_16(cipher_words, cipher);
            words_to_bytes_be_16(tag_words, tag);
            return 1;
        }
    }

    last_error = ERR_ACK_TIMEOUT;
    uart1_puts("AES HW encrypt timeout status=");
    uart1_put_hex32(aes_gcm_status());
    uart1_puts("\n");
    return 0;
}

static int aes_decrypt_block(uint32_t nonce_dir, uint32_t seq_hi, uint32_t seq_lo,
                             const uint8_t cipher[SECURE_BLOCK_LEN],
                             const uint8_t tag[SECURE_BLOCK_LEN],
                             uint8_t plain[SECURE_BLOCK_LEN])
{
    uint32_t key_words[4];
    uint32_t cipher_words[4];
    uint32_t tag_words[4];
    uint32_t plain_words[4];
    uint32_t i;
    uint32_t status;

    bytes_to_words_be_16(aes_demo_key_bytes, key_words);
    bytes_to_words_be_16(cipher, cipher_words);
    bytes_to_words_be_16(tag, tag_words);

    aes_gcm_set_key_words(key_words);
    aes_gcm_set_iv(nonce_dir, seq_hi, seq_lo);
    aes_gcm_set_payload_words(cipher_words);
    aes_gcm_set_tag_words(tag_words);
    aes_gcm_clear_status();
    aes_gcm_start_decrypt(SECURE_BLOCK_LEN);

    for (i = 0u; i < AES_HW_WAIT_LOOPS; i++) {
        status = aes_gcm_status();
        if ((status & AES_STATUS_DONE) != 0u) {
            if ((status & AES_STATUS_TAG_OK) == 0u || (status & AES_STATUS_ERROR) != 0u) {
                last_error = ERR_TAG_FAIL;
                return 0;
            }
            aes_gcm_get_payload_words(plain_words);
            words_to_bytes_be_16(plain_words, plain);
            return 1;
        }
    }

    last_error = ERR_ACK_TIMEOUT;
    uart1_puts("AES HW decrypt timeout status=");
    uart1_put_hex32(aes_gcm_status());
    uart1_puts("\n");
    return 0;
}

static int secure_build_payload(uint32_t nonce_dir, uint32_t seq_hi, uint32_t seq_lo,
                                const uint8_t plain[SECURE_BLOCK_LEN],
                                uint8_t wire[SECURE_WIRE_LEN])
{
    uint8_t cipher[SECURE_BLOCK_LEN];
    uint8_t tag[SECURE_BLOCK_LEN];
    uint32_t i;

    if (!aes_encrypt_block(nonce_dir, seq_hi, seq_lo, plain, cipher, tag)) {
        return 0;
    }

    put_u32_be(&wire[0], nonce_dir);
    put_u32_be(&wire[4], seq_hi);
    put_u32_be(&wire[8], seq_lo);
    put_u16_be(&wire[12], SECURE_BLOCK_LEN);
    for (i = 0u; i < SECURE_BLOCK_LEN; i++) {
        wire[14u + i] = cipher[i];
        wire[30u + i] = tag[i];
    }
    return 1;
}

static int secure_send_app(uint8_t app_type, const uint8_t *payload, uint8_t payload_len)
{
    uint8_t plain[SECURE_BLOCK_LEN];
    uint8_t wire[SECURE_WIRE_LEN];
    uint32_t i;

    for (i = 0u; i < SECURE_BLOCK_LEN; i++) {
        plain[i] = 0u;
    }

    plain[0] = app_type;
    if (payload_len > (SECURE_BLOCK_LEN - 1u)) {
        payload_len = SECURE_BLOCK_LEN - 1u;
    }
    for (i = 0u; i < payload_len; i++) {
        plain[1u + i] = payload[i];
    }

    if (!secure_build_payload(AES_NONCE_DIR_C2R, 0u, tx_seq, plain, wire)) {
        return 0;
    }

    return lora_send_frame(TYPE_SECURE_C2R, wire, SECURE_WIRE_LEN);
}

static int secure_decrypt_payload(const uint8_t *wire, uint8_t wire_len,
                                  uint8_t expected_dir,
                                  uint8_t plain[SECURE_BLOCK_LEN],
                                  uint32_t *seq_lo_out)
{
    uint32_t nonce_dir;
    uint32_t seq_hi;
    uint32_t seq_lo;
    uint16_t len;
    uint32_t expected_nonce_dir = (AES_SESSION_NONCE << 8) | (uint32_t)expected_dir;

    if (wire_len != SECURE_WIRE_LEN) {
        last_error = ERR_BAD_FRAME;
        return 0;
    }

    nonce_dir = get_u32_be(&wire[0]);
    seq_hi = get_u32_be(&wire[4]);
    seq_lo = get_u32_be(&wire[8]);
    len = get_u16_be(&wire[12]);

    if (nonce_dir != expected_nonce_dir || len != SECURE_BLOCK_LEN) {
        last_error = ERR_BAD_FRAME;
        return 0;
    }

    if (!aes_decrypt_block(nonce_dir, seq_hi, seq_lo, &wire[14], &wire[30], plain)) {
        return 0;
    }

    if (seq_lo_out != 0) {
        *seq_lo_out = seq_lo;
    }
    return 1;
}

static int poll_lora_frame(frame_t *out)
{
    uint8_t b;
    while (lora_uart_recv_byte(&b)) {
        lora_rx_seen ^= 1u;
        if (parser_feed(&lora_parser, b, out)) {
            return 1;
        }
    }
    return 0;
}

static void handle_pc_frame(const frame_t *f)
{
    if (f->type == TYPE_PC_WAYPOINT && f->len == 8u) {
        if (active_mode != MODE_WAYPOINT || (current_switches & 2u) == 0u) {
            uart1_puts("PC waypoint ignored sw=");
            uart1_put_hex32(current_switches & 3u);
            uart1_puts(" mode=");
            uart1_put_hex32((uint32_t)active_mode);
            uart1_puts("\n");
            return;
        }

        waypoint.x = get_u32(&f->payload[0]);
        waypoint.y = get_u32(&f->payload[4]);
        waypoint.id++;
        waypoint.valid = 1u;
        uart1_puts("PC waypoint received x=");
        uart1_put_hex32(waypoint.x);
        uart1_puts(" y=");
        uart1_put_hex32(waypoint.y);
        uart1_puts("\n");
    }
}

static void poll_pc_uart(void)
{
    uint8_t b;
    frame_t f;
    while (uart1_getc_nonblock(&b)) {
        if (parser_feed(&pc_parser, b, &f)) {
            handle_pc_frame(&f);
        }
    }
}

static int wait_lora_type(uint8_t type, frame_t *out, uint32_t wait_loops)
{
    uint32_t i;
    for (i = 0u; i < wait_loops; i++) {
        poll_pc_uart();
        if (poll_lora_frame(out) && out->type == type) {
            return 1;
        }
        service_health_tasks();
        timer_delay_cycles(LOOP_DELAY_CYCLES);
    }
    last_error = ERR_ACK_TIMEOUT;
    return 0;
}

static int wait_lora_secure_app(uint8_t app_type, uint8_t plain[SECURE_BLOCK_LEN],
                                uint32_t wait_loops)
{
    uint32_t i;
    frame_t frame;
    uint32_t seq_lo;

    for (i = 0u; i < wait_loops; i++) {
        poll_pc_uart();
        if (poll_lora_frame(&frame) && frame.type == TYPE_SECURE_R2C) {
            if (secure_decrypt_payload(frame.payload, frame.len, AES_DIR_R2C, plain, &seq_lo)) {
                rx_seq = seq_lo;
                if (plain[0] == app_type) {
                    return 1;
                }
            }
        }
        service_health_tasks();
        timer_delay_cycles(LOOP_DELAY_CYCLES);
    }
    last_error = ERR_ACK_TIMEOUT;
    return 0;
}

static uint8_t cmd_state(char cmd)
{
    if (cmd == 'w') {
        return 1u;
    }
    if (cmd == 's') {
        return 2u;
    }
    if (cmd == 'a') {
        return 3u;
    }
    if (cmd == 'd') {
        return 4u;
    }
    if (cmd == ' ') {
        return 5u;
    }
    return 0u;
}

static const char *cmd_text(char cmd)
{
    if (cmd == 'w') {
        return "W";
    }
    if (cmd == 's') {
        return "S";
    }
    if (cmd == 'a') {
        return "A";
    }
    if (cmd == 'd') {
        return "D";
    }
    return "SPC";
}

static int clamp_i32(int value, int min_value, int max_value)
{
    if (value < min_value) {
        return min_value;
    }
    if (value > max_value) {
        return max_value;
    }
    return value;
}

static uint32_t rect_mask_for_word(int x, int width, uint32_t word_x)
{
    uint32_t mask = 0u;
    int left = x;
    int right = x + width;
    int word_left = (int)(word_x * 32u);
    int bit;

    for (bit = 0; bit < 32; bit++) {
        int px = word_left + bit;
        if (px >= left && px < right) {
            mask |= (1u << (uint32_t)bit);
        }
    }
    return mask;
}

static void draw_rect(int x, int y, int width, int height)
{
    int row;

    x = clamp_i32(x, 0, (int)VGA_WIDTH_PX - width);
    y = clamp_i32(y, 0, (int)VGA_HEIGHT_PX - height);

    for (row = 0; row < height; row++) {
        uint32_t word0 = (uint32_t)x / 32u;
        uint32_t word1 = (uint32_t)(x + width - 1) / 32u;
        uint32_t py = (uint32_t)(y + row);
        uint32_t mask0 = rect_mask_for_word(x, width, word0);
        vram_write_word((py * VGA_WORDS_PER_ROW) + word0, mask0);
        if (word1 != word0) {
            uint32_t mask1 = rect_mask_for_word(x, width, word1);
            vram_write_word((py * VGA_WORDS_PER_ROW) + word1, mask1);
        }
    }
}

static void telemetry_to_map_px(int32_t x_cm, int32_t y_cm, int *px, int *py)
{
    int x = RC_MAP_START_X + (int)(x_cm / RC_MAP_SCALE_CM_PER_PX);
    int y = RC_MAP_START_Y - (int)(y_cm / RC_MAP_SCALE_CM_PER_PX);

    *px = clamp_i32(x, 324, 632);
    *py = clamp_i32(y, 4, 472);
}

static int32_t telemetry_map_x_cm(void)
{
    return ((telemetry.flags & 0x02u) != 0u) ?
           (int32_t)telemetry.ekf_x_cm :
           (int32_t)telemetry.gps_x_cm;
}

static int32_t telemetry_map_y_cm(void)
{
    return ((telemetry.flags & 0x02u) != 0u) ?
           (int32_t)telemetry.ekf_y_cm :
           (int32_t)telemetry.gps_y_cm;
}

static void render_rc_map(void)
{
    int px;
    int py;

    vga_text_puts(13u, 228u, "START");
    draw_rect(RC_MAP_START_X, RC_MAP_START_Y, 8, 8);

    if (active_mode == MODE_WAYPOINT && ((current_switches & 2u) == 0u) &&
        prev_map_valid != 0u) {
        telemetry_to_map_px(prev_map_x_cm, prev_map_y_cm, &px, &py);
        draw_rect(px, py, 4, 4);
    }

    if (active_mode == MODE_WAYPOINT && ((current_switches & 2u) == 0u) &&
        telemetry.valid != 0u) {
        telemetry_to_map_px(telemetry_map_x_cm(), telemetry_map_y_cm(), &px, &py);
        draw_rect(px, py, 8, 8);
    }
}

static void render_dashboard(void)
{
    vga_text_begin_frame();
    vga_text_puts(1u, 16u, "RC CONTROLLER SOC");
    vga_text_puts(1u, 44u, "MODE");
    vga_text_puts(5u, 44u, active_mode == MODE_WAYPOINT ? "WAYP" : "MAN");
    vga_text_puts(1u, 68u, "CMD");
    vga_text_puts(5u, 68u, cmd_text(last_cmd));
    vga_text_puts(1u, 92u, "WPX");
    vga_text_put_hex32(5u, 92u, waypoint.x);
    vga_text_puts(1u, 116u, "WPY");
    vga_text_put_hex32(5u, 116u, waypoint.y);
    vga_text_puts(1u, 148u, "TEL SEQ");
    vga_text_put_hex16(8u, 148u, telemetry.seq);
    vga_text_puts(1u, 172u, "EKFX");
    vga_text_put_hex16(6u, 172u, (uint16_t)telemetry.ekf_x_cm);
    vga_text_puts(1u, 196u, "EKFY");
    vga_text_put_hex16(6u, 196u, (uint16_t)telemetry.ekf_y_cm);
    vga_text_puts(1u, 220u, "GPSX");
    vga_text_put_hex16(6u, 220u, (uint16_t)telemetry.gps_x_cm);
    vga_text_puts(1u, 244u, "GPSY");
    vga_text_put_hex16(6u, 244u, (uint16_t)telemetry.gps_y_cm);
    vga_text_puts(1u, 268u, "FLG");
    vga_text_put_hex8(5u, 268u, telemetry.flags);
    vga_text_puts(8u, 268u, "E");
    vga_text_put_hex8(9u, 268u, last_error);
    render_rc_map();
}

static void update_monitor(void)
{
    uint8_t mode_digit = active_mode == MODE_WAYPOINT ? 1u : 0u;
    hex_display_write_monitor(mode_digit, last_state, retry_count,
                              last_error, (uint8_t)rx_seq, (uint8_t)tx_seq);
}

static void update_health_leds(void)
{
    uint32_t leds = 0u;

    if (heartbeat != 0u) {
        leds |= (1u << 0);
    }
    if (active_mode == MODE_MANUAL) {
        leds |= (1u << 1);
    }
    if (active_mode == MODE_WAYPOINT) {
        leds |= (1u << 2);
    }
    if (lora_uart_aux_ready()) {
        leds |= (1u << 3);
    }
    if (last_error != ERR_NONE) {
        leds |= (1u << 4);
    }
    if (manual_ack_seen != 0u) {
        leds |= (1u << 5);
    }
    if (lora_rx_seen != 0u) {
        leds |= (1u << 6);
    }
    if (lora_tx_seen != 0u) {
        leds |= (1u << 7);
    }
    if (waypoint.valid || telemetry.valid) {
        leds |= (1u << 8);
    }

    led_write(leds);
}

static void sync_mode(uint8_t mode, uint8_t reason)
{
    uint8_t payload[2];
    uint8_t ack_plain[SECURE_BLOCK_LEN];

    payload[0] = mode;
    payload[1] = reason;
    retry_count = 0u;

    while (retry_count < 3u) {
        last_state = 8u;
        uart1_puts("MODE_CHANGE tx mode=");
        uart1_put_hex32((uint32_t)mode);
        uart1_puts(" reason=");
        uart1_put_hex32((uint32_t)reason);
        uart1_puts(" lora_status=");
        uart1_put_hex32(lora_uart_status());
        uart1_puts("\n");
        if (secure_send_app(TYPE_MODE_CHANGE, payload, 2u) &&
            wait_lora_secure_app(TYPE_MODE_ACK, ack_plain, MODE_ACK_WAIT_LOOPS) &&
            ack_plain[1] == mode && ack_plain[2] == 0u) {
            active_mode = mode;
            last_error = ERR_NONE;
            retry_count = 0u;
            tx_seq++;
            uart1_puts("MODE_ACK ok mode=");
            uart1_put_hex32((uint32_t)mode);
            uart1_puts("\n");
            return;
        }
        retry_count++;
        last_error = ERR_MODE_SYNC;
        uart1_puts("MODE_ACK timeout retry=");
        uart1_put_hex32((uint32_t)retry_count);
        uart1_puts(" lora_status=");
        uart1_put_hex32(lora_uart_status());
        uart1_puts("\n");
    }
}

static void manual_step(void)
{
    joystick_sample_t joy = joystick_read();
    char cmd = joystick_dir_to_ascii(joy.dir_status);
    uint8_t payload[8];
    frame_t ack;

    if (cmd == '\0') {
        return;
    }

    payload[0] = (uint8_t)cmd;
    put_u16(&payload[1], joy.x_raw);
    put_u16(&payload[3], joy.y_raw);
    payload[5] = (uint8_t)(joy.dir_status & 0xffu);
    payload[6] = (uint8_t)(tx_seq & 0xffu);
    payload[7] = 0u;

    last_cmd = cmd;
    last_state = cmd_state(cmd);
    retry_count = 0u;
    manual_ack_seen = 0u;
    secure_send_app(TYPE_MANUAL_CMD, payload, 8u);
    if (wait_lora_type(TYPE_MANUAL_ACK, &ack, MANUAL_ACK_WAIT_LOOPS) && ack.len >= 2u) {
        rx_seq = ack.payload[0];
        last_error = ERR_NONE;
        manual_ack_seen = 1u;
    }
    tx_seq++;

    uart1_puts("MANUAL cmd=");
    uart1_puts(cmd_text(cmd));
    uart1_puts(" x=");
    uart1_put_hex32((uint32_t)joy.x_raw);
    uart1_puts(" y=");
    uart1_put_hex32((uint32_t)joy.y_raw);
    uart1_puts("\n");
}

static void waypoint_step(void)
{
    uint8_t payload[10];
    uint8_t ack_plain[SECURE_BLOCK_LEN];

    if (!waypoint.valid) {
        return;
    }

    put_u16(&payload[0], waypoint.id);
    put_u32(&payload[2], waypoint.x);
    put_u32(&payload[6], waypoint.y);

    last_state = 6u;
    if (secure_send_app(TYPE_WAYPOINT_CMD, payload, 10u) &&
        wait_lora_secure_app(TYPE_WAYPOINT_ACK, ack_plain, WAYPOINT_ACK_WAIT_LOOPS) &&
        get_u16(&ack_plain[1]) == waypoint.id && ack_plain[3] == 0u) {
        last_error = ERR_NONE;
        waypoint.valid = 0u;
        tx_seq++;
    }
}

static void telemetry_step(void)
{
    uint8_t payload[4];
    uint8_t data_plain[SECURE_BLOCK_LEN];
    uint16_t req_id = (uint16_t)(tx_seq & 0xffffu);

    put_u16(&payload[0], req_id);
    put_u16(&payload[2], 0xffffu);

    last_state = 7u;
    if (secure_send_app(TYPE_TELEMETRY_REQ, payload, 4u) &&
        wait_lora_secure_app(TYPE_TELEMETRY_DATA, data_plain, TELEMETRY_WAIT_LOOPS)) {
        if (telemetry.valid != 0u) {
            prev_map_x_cm = telemetry_map_x_cm();
            prev_map_y_cm = telemetry_map_y_cm();
            prev_map_valid = 1u;
        }
        telemetry.seq = get_u16(&data_plain[1]);
        telemetry.ekf_x_cm = (int16_t)get_u16(&data_plain[3]);
        telemetry.ekf_y_cm = (int16_t)get_u16(&data_plain[5]);
        telemetry.gps_x_cm = (int16_t)get_u16(&data_plain[7]);
        telemetry.gps_y_cm = (int16_t)get_u16(&data_plain[9]);
        telemetry.rc_mode = data_plain[11];
        telemetry.flags = data_plain[12];
        telemetry.heading_u8 = data_plain[13];
        telemetry.valid = 1u;
        rx_seq = telemetry.seq;
        last_error = ERR_NONE;
        tx_seq++;
        uart1_puts("TELEMETRY seq=");
        uart1_put_hex32((uint32_t)telemetry.seq);
        uart1_puts(" ekf_x=");
        uart1_put_hex32((uint32_t)(uint16_t)telemetry.ekf_x_cm);
        uart1_puts(" ekf_y=");
        uart1_put_hex32((uint32_t)(uint16_t)telemetry.ekf_y_cm);
        uart1_puts(" flags=");
        uart1_put_hex32((uint32_t)telemetry.flags);
        uart1_puts("\n");
    }
}

static void write_banner(void)
{
    uart1_puts("\n=== RC Controller SoC AES-GCM full demo firmware ===\n");
    uart1_puts("UART0=LoRa AES-GCM peer, UART1=PC COM, VGA telemetry dashboard\n");
    uart1_puts("LoRa secure frame: SOF SECURE LEN NONCE/SEQ/CT/TAG SUM EOF\n");
    uart1_puts("PC waypoint frame remains plaintext on UART1\n");
}

int main(void)
{
    uint32_t now;
    uint32_t last_manual_cycle = 0u;
    uint32_t last_telemetry_cycle = 0u;
    uint32_t last_render_cycle = 0u;

    /* GPIO_IO remains Hi-Z until an external JP1 peer is explicitly configured. */
    led_write(0u);
    timer_start(TIMER_TIMEBASE_COMPARE);
    lora_uart_init(0u);
    joystick_init(1u, 2u, 2048u, 2048u, 300u);
    hex_display_enable(1);
    hex_display_set_raw_mode(0);
    parser_reset(&pc_parser);
    parser_reset(&lora_parser);
    write_banner();
    render_dashboard();
    now = demo_time_cycles();
    last_manual_cycle = now - MANUAL_PERIOD_CYCLES;
    last_telemetry_cycle = now - TELEMETRY_PERIOD_CYCLES;
    last_render_cycle = now;
    last_heartbeat_cycle = now;

    for (;;) {
        uint32_t sw = sw_read();
        current_switches = sw;
        now = demo_time_cycles();
        requested_mode = (sw & 1u) ? MODE_WAYPOINT : MODE_MANUAL;

        poll_pc_uart();

        if (requested_mode != active_mode) {
            sync_mode(requested_mode, active_mode == MODE_UNKNOWN ? 0u : 1u);
            now = demo_time_cycles();
            if (requested_mode == MODE_MANUAL) {
                last_manual_cycle = now - MANUAL_PERIOD_CYCLES;
            } else {
                last_telemetry_cycle = now - TELEMETRY_PERIOD_CYCLES;
            }
            render_dashboard();
        } else if (active_mode == MODE_MANUAL) {
            if (elapsed_cycles(now, last_manual_cycle, MANUAL_PERIOD_CYCLES)) {
                last_manual_cycle = now;
                manual_step();
                render_dashboard();
            }
        } else {
            if ((sw & 2u) != 0u) {
                waypoint_step();
            } else if (elapsed_cycles(now, last_telemetry_cycle, TELEMETRY_PERIOD_CYCLES)) {
                last_telemetry_cycle = now;
                telemetry_step();
                render_dashboard();
            }
        }

        now = demo_time_cycles();
        if (elapsed_cycles(now, last_render_cycle, RENDER_PERIOD_CYCLES)) {
            last_render_cycle = now;
            render_dashboard();
        }
        service_health_tasks();
        timer_delay_cycles(LOOP_DELAY_CYCLES);
    }
}
