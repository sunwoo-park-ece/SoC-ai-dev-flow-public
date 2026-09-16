#ifndef UART_H
#define UART_H

#include <stdint.h>

#define UART_STATUS_TX_READY  (1u << 0)
#define UART_STATUS_RX_READY  (1u << 1)
#define UART_STATUS_RX_ERROR  (1u << 2)
#define UART_STATUS_LORA_AUX  (1u << 3)

#define UART_BAUD_DIV_MIN          217u
#define UART_BAUD_DIV_MAX          65535u
#define UART_DEFAULT_POLL_BUDGET   100000u

typedef enum {
    UART_RESULT_SUCCESS = 0,
    UART_RESULT_TIMEOUT = 1,
    UART_RESULT_INVALID_ARGUMENT = 2
} uart_result_t;

uart_result_t uart0_set_baud_div(uint32_t baud_div);
uint32_t uart0_status(void);
int uart0_tx_ready(void);
int uart0_rx_ready(void);
uart_result_t uart0_putc_timeout(char c, uint32_t poll_budget);
uart_result_t uart0_write_timeout(const uint8_t *data, uint32_t len,
                                  uint32_t poll_budget_per_byte);
uart_result_t uart0_puts_timeout(const char *s, uint32_t poll_budget_per_byte);
uart_result_t uart0_put_hex32_timeout(uint32_t value,
                                      uint32_t poll_budget_per_byte);
uart_result_t uart0_putc(char c);
uart_result_t uart0_write(const uint8_t *data, uint32_t len);
uart_result_t uart0_puts(const char *s);
int uart0_getc_nonblock(uint8_t *out);
uart_result_t uart0_put_hex32(uint32_t value);
int uart0_rx_error(void);
void uart0_clear_rx_error(void);

uart_result_t uart1_set_baud_div(uint32_t baud_div);
uint32_t uart1_status(void);
int uart1_tx_ready(void);
int uart1_rx_ready(void);
uart_result_t uart1_putc_timeout(char c, uint32_t poll_budget);
uart_result_t uart1_write_timeout(const uint8_t *data, uint32_t len,
                                  uint32_t poll_budget_per_byte);
uart_result_t uart1_puts_timeout(const char *s, uint32_t poll_budget_per_byte);
uart_result_t uart1_put_hex32_timeout(uint32_t value,
                                      uint32_t poll_budget_per_byte);
uart_result_t uart1_putc(char c);
uart_result_t uart1_write(const uint8_t *data, uint32_t len);
uart_result_t uart1_puts(const char *s);
int uart1_getc_nonblock(uint8_t *out);
uart_result_t uart1_put_hex32(uint32_t value);
int uart1_rx_error(void);
void uart1_clear_rx_error(void);

#endif
