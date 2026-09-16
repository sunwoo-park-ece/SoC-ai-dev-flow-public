#include "lora_uart.h"
#include "uart.h"

lora_uart_result_t lora_uart_init(uint32_t baud_div)
{
    uart_result_t result;

    // Zero preserves the hardware reset/default divisor for legacy callers.
    if (baud_div == 0u) {
        return LORA_UART_RESULT_SUCCESS;
    }
    result = uart0_set_baud_div(baud_div);
    return (result == UART_RESULT_SUCCESS) ? LORA_UART_RESULT_SUCCESS :
                                             LORA_UART_RESULT_INVALID_ARGUMENT;
}

uint32_t lora_uart_status(void)
{
    return uart0_status();
}

int lora_uart_aux_ready(void)
{
    return (lora_uart_status() & UART_STATUS_LORA_AUX) != 0u;
}

/* A zero budget performs zero AUX status reads. */
lora_uart_result_t lora_uart_wait_aux_ready_timeout(uint32_t poll_budget)
{
    uint32_t poll;

    for (poll = 0u; poll < poll_budget; poll++) {
        if (lora_uart_aux_ready()) {
            return LORA_UART_RESULT_SUCCESS;
        }
    }
    return LORA_UART_RESULT_AUX_TIMEOUT;
}

lora_uart_result_t lora_uart_send_ascii_timeout(char c,
                                                 uint32_t aux_poll_budget,
                                                 uint32_t tx_poll_budget)
{
    lora_uart_result_t aux_result;
    uart_result_t tx_result;

    aux_result = lora_uart_wait_aux_ready_timeout(aux_poll_budget);
    if (aux_result != LORA_UART_RESULT_SUCCESS) {
        return aux_result;
    }

    tx_result = uart0_putc_timeout(c, tx_poll_budget);
    if (tx_result == UART_RESULT_TIMEOUT) {
        return LORA_UART_RESULT_UART_TX_TIMEOUT;
    }
    if (tx_result != UART_RESULT_SUCCESS) {
        return LORA_UART_RESULT_INVALID_ARGUMENT;
    }
    return LORA_UART_RESULT_SUCCESS;
}

lora_uart_result_t lora_uart_send_bytes_timeout(
    const uint8_t *data, uint32_t len, uint32_t aux_poll_budget_per_byte,
    uint32_t tx_poll_budget_per_byte)
{
    uint32_t i;
    lora_uart_result_t result;

    if ((data == 0) && (len != 0u)) {
        return LORA_UART_RESULT_INVALID_ARGUMENT;
    }
    for (i = 0u; i < len; i++) {
        result = lora_uart_send_ascii_timeout((char)data[i],
                                              aux_poll_budget_per_byte,
                                              tx_poll_budget_per_byte);
        if (result != LORA_UART_RESULT_SUCCESS) {
            return result;
        }
    }
    return LORA_UART_RESULT_SUCCESS;
}

lora_uart_result_t lora_uart_wait_aux_ready(void)
{
    return lora_uart_wait_aux_ready_timeout(LORA_UART_DEFAULT_AUX_POLL_BUDGET);
}

lora_uart_result_t lora_uart_send_bytes(const uint8_t *data, uint32_t len)
{
    return lora_uart_send_bytes_timeout(data, len,
                                        LORA_UART_DEFAULT_AUX_POLL_BUDGET,
                                        LORA_UART_DEFAULT_TX_POLL_BUDGET);
}

lora_uart_result_t lora_uart_send_ascii(char c)
{
    return lora_uart_send_ascii_timeout(c,
                                        LORA_UART_DEFAULT_AUX_POLL_BUDGET,
                                        LORA_UART_DEFAULT_TX_POLL_BUDGET);
}

int lora_uart_recv_byte(uint8_t *out)
{
    return uart0_getc_nonblock(out);
}
