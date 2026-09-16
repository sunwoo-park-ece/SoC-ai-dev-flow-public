#include <stdint.h>

#include "hex_display.h"
#include "lora_uart.h"
#include "timer.h"
#include "uart.h"

#define FRAME_SOF          0x7eu
#define FRAME_EOF          0x0au
#define TYPE_MODE_CHANGE   0x10u

static void put_hex8(uint8_t value)
{
    static const char hex[] = "0123456789ABCDEF";
    uart1_putc(hex[(value >> 4) & 0x0f]);
    uart1_putc(hex[value & 0x0f]);
}

static void send_mode_change(void)
{
    uint8_t frame[7];
    uint8_t sum;

    frame[0] = FRAME_SOF;
    frame[1] = TYPE_MODE_CHANGE;
    frame[2] = 2u;
    frame[3] = 1u;
    frame[4] = 0u;
    sum = (uint8_t)(frame[1] + frame[2] + frame[3] + frame[4]);
    frame[5] = sum;
    frame[6] = FRAME_EOF;

    lora_uart_send_bytes(frame, sizeof(frame));
    uart1_puts("TX MODE_CHANGE frame=");
    for (uint32_t i = 0u; i < sizeof(frame); i++) {
        put_hex8(frame[i]);
        uart1_putc(' ');
    }
    uart1_puts("\n");
}

int main(void)
{
    uint32_t tick = 0u;
    uint32_t stat_tick = 0u;
    uint32_t tx_tick = 0u;
    uint32_t rx_count = 0u;
    uint8_t last_rx = 0u;

    lora_uart_init(0u);
    hex_display_enable(1);
    hex_display_set_raw_mode(0);

    uart1_puts("\n=== LoRa UART0 RX debug ===\n");
    uart1_puts("This app sends MODE_CHANGE on UART0 and prints raw UART0 RX bytes on UART1.\n");
    uart1_puts("Expected MODE_ACK bytes: 7E 90 03 01 00 00 94 0A\n");

    send_mode_change();

    for (;;) {
        uint8_t b;
        uint32_t status = lora_uart_status();

        if (lora_uart_recv_byte(&b)) {
            last_rx = b;
            rx_count++;
            uart1_puts("RX byte=0x");
            put_hex8(b);
            uart1_puts(" status=0x");
            uart1_put_hex32(status);
            uart1_puts(" count=");
            uart1_put_hex32(rx_count);
            uart1_puts("\n");
        }

        stat_tick++;
        if (stat_tick >= 10000u) {
            stat_tick = 0u;
            uart1_puts("STAT=0x");
            uart1_put_hex32(lora_uart_status());
            uart1_puts(" rx_count=");
            uart1_put_hex32(rx_count);
            uart1_puts("\n");
        }

        tx_tick++;
        if (tx_tick >= 50000u) {
            tx_tick = 0u;
            send_mode_change();
        }

        hex_display_write_monitor(0u, 9u, (uint8_t)rx_count, 0u,
                                  last_rx & 0x0fu, (uint8_t)(tick & 0x0fu));
        timer_delay_cycles(1000u);
        tick++;
    }
}
