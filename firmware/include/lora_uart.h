#ifndef LORA_UART_H
#define LORA_UART_H

#include <stdint.h>

#define LORA_UART_DEFAULT_AUX_POLL_BUDGET 100000u
#define LORA_UART_DEFAULT_TX_POLL_BUDGET  100000u

typedef enum {
    LORA_UART_RESULT_SUCCESS = 0,
    LORA_UART_RESULT_AUX_TIMEOUT = 1,
    LORA_UART_RESULT_UART_TX_TIMEOUT = 2,
    LORA_UART_RESULT_INVALID_ARGUMENT = 3
} lora_uart_result_t;

lora_uart_result_t lora_uart_init(uint32_t baud_div);
uint32_t lora_uart_status(void);
int lora_uart_aux_ready(void);
lora_uart_result_t lora_uart_wait_aux_ready_timeout(uint32_t poll_budget);
lora_uart_result_t lora_uart_send_bytes_timeout(
    const uint8_t *data, uint32_t len, uint32_t aux_poll_budget_per_byte,
    uint32_t tx_poll_budget_per_byte);
lora_uart_result_t lora_uart_send_ascii_timeout(
    char c, uint32_t aux_poll_budget, uint32_t tx_poll_budget);
lora_uart_result_t lora_uart_wait_aux_ready(void);
lora_uart_result_t lora_uart_send_bytes(const uint8_t *data, uint32_t len);
lora_uart_result_t lora_uart_send_ascii(char c);
int lora_uart_recv_byte(uint8_t *out);

#endif
