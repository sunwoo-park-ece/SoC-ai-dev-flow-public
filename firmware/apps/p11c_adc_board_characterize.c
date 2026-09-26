/*
 * P11-ADC Board Characterization Firmware (Verification-Only)
 *
 * Measures:
 *   1. Hardware ADC new-frame interval (cadence) using CPU mcycle counter
 *   2. Physical joystick analog raw X/Y response (CH1/CH2) and HW/FW policy agreement
 *
 * NOTE: This is a standalone verification image for physical characterization.
 *       Canonical integration firmware remains soc_health_main.c.
 */

#include <stdint.h>
#include <stdbool.h>
#include "adc.h"
#include "joystick_policy.h"
#include "uart.h"

#define BATCH_SIZE 1024u
#define CLK_MHZ    50u /* 50 MHz system clock: 1 tick = 20 ns, 50 ticks = 1 us */

/* Software integer division routines to eliminate libgcc RV32I runtime dependency */
static uint32_t udiv32(uint32_t num, uint32_t den, uint32_t *rem)
{
    uint32_t q = 0u;
    uint32_t r = 0u;
    int i;
    if (den == 0u) {
        if (rem) *rem = 0u;
        return 0u;
    }
    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((num >> i) & 1u);
        if (r >= den) {
            r -= den;
            q |= (1u << i);
        }
    }
    if (rem) *rem = r;
    return q;
}

static uint64_t udiv64(uint64_t num, uint64_t den)
{
    uint64_t q = 0ULL;
    uint64_t r = 0ULL;
    int i;
    if (den == 0ULL) return 0ULL;
    for (i = 63; i >= 0; i--) {
        r = (r << 1) | ((num >> i) & 1ULL);
        if (r >= den) {
            r -= den;
            q |= (1ULL << i);
        }
    }
    return q;
}

static inline uint32_t read_mcycle(void)
{
    uint32_t cycles;
    __asm__ volatile(
        ".option push\n"
        ".option arch, +zicsr\n"
        "csrr %0, mcycle\n"
        ".option pop\n"
        : "=r"(cycles)
    );
    return cycles;
}

static void uart_puts_u1(const char *s)
{
    while (*s) {
        (void)uart1_putc_timeout(*s++, 50000u);
    }
}

static void uart_put_dec(uint32_t val)
{
    char buf[12];
    int idx = 0;
    if (val == 0u) {
        (void)uart1_putc_timeout('0', 50000u);
        return;
    }
    while (val > 0u) {
        uint32_t rem = 0u;
        val = udiv32(val, 10u, &rem);
        buf[idx++] = (char)('0' + rem);
    }
    while (idx > 0) {
        (void)uart1_putc_timeout(buf[--idx], 50000u);
    }
}

static void uart_put_hex2(uint8_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    (void)uart1_putc_timeout(hex[(val >> 4) & 0x0Fu], 50000u);
    (void)uart1_putc_timeout(hex[val & 0x0Fu], 50000u);
}

static void uart_put_hex8(uint32_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i--) {
        (void)uart1_putc_timeout(hex[(val >> (i * 4)) & 0x0Fu], 50000u);
    }
}

int main(void)
{
    joystick_calibration_t cal;
    adc_frame_t frame;
    uint32_t prev_cycles;
    uint32_t batch_count = 0u;
    uint64_t sum_ticks = 0ULL;
    uint32_t min_ticks = 0xFFFFFFFFu;
    uint32_t max_ticks = 0u;
    uint32_t total_frames = 0u;
    uint32_t last_seq = 0u;
    uint32_t total_errors = 0u;
    uint32_t hw_fw_mismatches = 0u;

    (void)uart1_set_baud_div(434u); /* 115200 baud at 50 MHz */

    uart_puts_u1("\r\n# ============================================================\r\n");
    uart_puts_u1("# P11-ADC C4-C Physical Characterization (Verification Only)\r\n");
    uart_puts_u1("# Timing: 50 MHz (1 tick = 20 ns, 50 ticks = 1 us)\r\n");
    uart_puts_u1("# Protocol: STAT (cadence batch) and RAW (telemetry)\r\n");
    uart_puts_u1("# Movement: CENTER -> UP -> DOWN -> LEFT -> RIGHT\r\n");
    uart_puts_u1("# ============================================================\r\n");

    if (adc_init() != ADC_OK) {
        uart_puts_u1("ERROR: adc_init() failed (peripheral identity mismatch)\r\n");
        for (;;) ;
    }

    if (adc_enable(10000u) != ADC_OK) {
        uart_puts_u1("ERROR: adc_enable() failed (engine timeout)\r\n");
        for (;;) ;
    }

    adc_get_calibration(&cal.center_x, &cal.center_y, &cal.deadzone);
    uart_puts_u1("INIT: Engine enabled. Default Cal: CX=");
    uart_put_dec(cal.center_x);
    uart_puts_u1(" CY=");
    uart_put_dec(cal.center_y);
    uart_puts_u1(" DZ=");
    uart_put_dec(cal.deadzone);
    uart_puts_u1("\r\n");

    prev_cycles = read_mcycle();

    for (;;) {
        adc_status_t status = adc_capture(&frame);
        if (status == ADC_OK) {
            uint32_t now = read_mcycle();
            uint32_t delta = now - prev_cycles;
            prev_cycles = now;

            total_frames++;

            if (last_seq != 0u && frame.seq <= last_seq) {
                total_errors++;
            }
            last_seq = frame.seq;

            /* First frame after UART print is excluded from interval measurement
             * to prevent UART transmission time from polluting hardware cadence */
            if (batch_count > 0u) {
                sum_ticks += delta;
                if (delta < min_ticks) min_ticks = delta;
                if (delta > max_ticks) max_ticks = delta;
            }

            batch_count++;

            uint8_t fw_joy = joystick_policy_eval(&frame, &cal);
            uint8_t hw_joy = adc_get_raw_joy_status();
            if (fw_joy != hw_joy) {
                hw_fw_mismatches++;
            }

            if (batch_count >= BATCH_SIZE) {
                uint32_t valid_samples = BATCH_SIZE - 1u;
                uint32_t avg_ticks = (uint32_t)udiv64(sum_ticks, (uint64_t)valid_samples);
                uint32_t avg_us = udiv32(avg_ticks, CLK_MHZ, 0);
                uint32_t min_us = udiv32(min_ticks, CLK_MHZ, 0);
                uint32_t max_us = udiv32(max_ticks, CLK_MHZ, 0);

                /* STAT seq=... n=... avg_ticks=... avg_us=... min_us=... max_us=... err=... */
                uart_puts_u1("STAT seq=");
                uart_put_hex8(frame.seq);
                uart_puts_u1(" n=");
                uart_put_dec(valid_samples);
                uart_puts_u1(" avg_ticks=");
                uart_put_dec(avg_ticks);
                uart_puts_u1(" avg_us=");
                uart_put_dec(avg_us);
                uart_puts_u1(" min_us=");
                uart_put_dec(min_us);
                uart_puts_u1(" max_us=");
                uart_put_dec(max_us);
                uart_puts_u1(" err=");
                uart_put_dec(total_errors);
                uart_puts_u1("\r\n");

                /* RAW seq=... mask=03 ch1=... ch2=... hw=... fw=... dir=... */
                uart_puts_u1("RAW  seq=");
                uart_put_hex8(frame.seq);
                uart_puts_u1(" mask=");
                uart_put_hex2((uint8_t)frame.valid_mask);
                uart_puts_u1(" ch1=");
                uart_put_dec(frame.ch[0]);
                uart_puts_u1(" ch2=");
                uart_put_dec(frame.ch[1]);
                uart_puts_u1(" hw=");
                uart_put_hex2(hw_joy);
                uart_puts_u1(" fw=");
                uart_put_hex2(fw_joy);
                uart_puts_u1(" dir=");
                char d = joystick_direction_to_char(hw_joy);
                (void)uart1_putc_timeout((d == ' ') ? 'C' : d, 50000u);
                uart_puts_u1("\r\n");

                /* Reset batch statistics */
                batch_count = 0u;
                sum_ticks = 0ULL;
                min_ticks = 0xFFFFFFFFu;
                max_ticks = 0u;

                /* Reset baseline timestamp so UART print time is excluded from next batch */
                prev_cycles = read_mcycle();
            }
        }
    }

    return 0;
}
