#include "uart.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

static uart_result_t uart_set_baud_div(uint32_t base, uint32_t baud_div)
{
    if ((baud_div < UART_BAUD_DIV_MIN) || (baud_div > UART_BAUD_DIV_MAX)) {
        return UART_RESULT_INVALID_ARGUMENT;
    }
    mmio_write32(base + UART_BAUD, baud_div);
    return UART_RESULT_SUCCESS;
}

static uint32_t uart_status(uint32_t base)
{
    return mmio_read32(base + UART_STATUS);
}

static int uart_tx_ready(uint32_t base)
{
    return (uart_status(base) & UART_STATUS_TX_READY) != 0u;
}

static int uart_rx_ready(uint32_t base)
{
    return (uart_status(base) & UART_STATUS_RX_READY) != 0u;
}

/* A zero budget performs zero status reads and can never write UART_DATA. */
static uart_result_t uart_putc_timeout(uint32_t base, char c,
                                       uint32_t poll_budget)
{
    uint32_t poll;

    for (poll = 0u; poll < poll_budget; poll++) {
        if (uart_tx_ready(base)) {
            mmio_write32(base + UART_DATA, (uint32_t)(uint8_t)c);
            return UART_RESULT_SUCCESS;
        }
    }
    return UART_RESULT_TIMEOUT;
}

static uart_result_t uart_write_timeout(uint32_t base, const uint8_t *data,
                                         uint32_t len,
                                         uint32_t poll_budget_per_byte)
{
    uint32_t i;
    uart_result_t result;

    if ((data == 0) && (len != 0u)) {
        return UART_RESULT_INVALID_ARGUMENT;
    }
    for (i = 0u; i < len; i++) {
        result = uart_putc_timeout(base, (char)data[i], poll_budget_per_byte);
        if (result != UART_RESULT_SUCCESS) {
            return result;
        }
    }
    return UART_RESULT_SUCCESS;
}

static uart_result_t uart_puts_timeout(uint32_t base, const char *s,
                                        uint32_t poll_budget_per_byte)
{
    uart_result_t result;

    if (s == 0) {
        return UART_RESULT_INVALID_ARGUMENT;
    }
    while (*s != '\0') {
        if (*s == '\n') {
            result = uart_putc_timeout(base, '\r', poll_budget_per_byte);
            if (result != UART_RESULT_SUCCESS) {
                return result;
            }
        }
        result = uart_putc_timeout(base, *s, poll_budget_per_byte);
        if (result != UART_RESULT_SUCCESS) {
            return result;
        }
        s++;
    }
    return UART_RESULT_SUCCESS;
}

static int uart_getc_nonblock(uint32_t base, uint8_t *out)
{
    if ((out == 0) || !uart_rx_ready(base)) {
        return 0;
    }
    *out = (uint8_t)(mmio_read32(base + UART_DATA) & 0xffu);
    return 1;
}

static uart_result_t uart_put_hex32_timeout(uint32_t base, uint32_t value,
                                             uint32_t poll_budget_per_byte)
{
    int shift;
    uart_result_t result;

    for (shift = 28; shift >= 0; shift -= 4) {
        uint32_t n = (value >> (uint32_t)shift) & 0xfu;
        char c = (char)(n < 10u ? ('0' + (char)n) :
                                 ('A' + (char)(n - 10u)));
        result = uart_putc_timeout(base, c, poll_budget_per_byte);
        if (result != UART_RESULT_SUCCESS) {
            return result;
        }
    }
    return UART_RESULT_SUCCESS;
}

static int uart_rx_error(uint32_t base)
{
    return (uart_status(base) & UART_STATUS_RX_ERROR) != 0u;
}

static void uart_clear_rx_error(uint32_t base)
{
    mmio_write32(base + UART_STATUS, UART_STATUS_RX_ERROR);
}

#define DEFINE_UART_API(index, base_address)                                      \
uart_result_t uart##index##_set_baud_div(uint32_t baud_div)                       \
{ return uart_set_baud_div(base_address, baud_div); }                             \
uint32_t uart##index##_status(void) { return uart_status(base_address); }          \
int uart##index##_tx_ready(void) { return uart_tx_ready(base_address); }           \
int uart##index##_rx_ready(void) { return uart_rx_ready(base_address); }           \
uart_result_t uart##index##_putc_timeout(char c, uint32_t budget)                 \
{ return uart_putc_timeout(base_address, c, budget); }                            \
uart_result_t uart##index##_write_timeout(const uint8_t *data, uint32_t len,      \
                                           uint32_t budget)                       \
{ return uart_write_timeout(base_address, data, len, budget); }                   \
uart_result_t uart##index##_puts_timeout(const char *s, uint32_t budget)          \
{ return uart_puts_timeout(base_address, s, budget); }                            \
uart_result_t uart##index##_put_hex32_timeout(uint32_t value, uint32_t budget)    \
{ return uart_put_hex32_timeout(base_address, value, budget); }                   \
uart_result_t uart##index##_putc(char c)                                          \
{ return uart_putc_timeout(base_address, c, UART_DEFAULT_POLL_BUDGET); }           \
uart_result_t uart##index##_write(const uint8_t *data, uint32_t len)              \
{ return uart_write_timeout(base_address, data, len, UART_DEFAULT_POLL_BUDGET); } \
uart_result_t uart##index##_puts(const char *s)                                   \
{ return uart_puts_timeout(base_address, s, UART_DEFAULT_POLL_BUDGET); }           \
int uart##index##_getc_nonblock(uint8_t *out)                                     \
{ return uart_getc_nonblock(base_address, out); }                                 \
uart_result_t uart##index##_put_hex32(uint32_t value)                             \
{ return uart_put_hex32_timeout(base_address, value, UART_DEFAULT_POLL_BUDGET); }  \
int uart##index##_rx_error(void) { return uart_rx_error(base_address); }           \
void uart##index##_clear_rx_error(void) { uart_clear_rx_error(base_address); }

DEFINE_UART_API(0, UART0_BASE)
DEFINE_UART_API(1, UART1_BASE)
