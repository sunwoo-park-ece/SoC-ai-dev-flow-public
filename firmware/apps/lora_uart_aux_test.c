#include <stdint.h>

#include "lora_uart.h"
#include "timer.h"
#include "uart.h"

int main(void)
{
    uint32_t count = 0u;

    lora_uart_init(0u);
    uart1_puts("\n=== LoRa UART AUX polling test ===\n");
    uart1_puts("UART0 sends only after UART_STATUS[3] AUX is high.\n");

    for (;;) {
        lora_uart_wait_aux_ready();
        lora_uart_send_ascii('A');

        uart1_puts("lora tx A status=");
        uart1_put_hex32(lora_uart_status());
        uart1_puts(" count=");
        uart1_put_hex32(count++);
        uart1_puts("\n");

        timer_delay_cycles(5000000u);
    }
}
