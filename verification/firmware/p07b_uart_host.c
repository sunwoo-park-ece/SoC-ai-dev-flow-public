#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "lora_uart.h"
#include "soc_memory_map.h"
#include "uart.h"

typedef struct { uint32_t addr; uint32_t value; } write_record_t;
typedef struct {
    uint32_t values[64];
    unsigned count;
    unsigned index;
    uint32_t fallback;
    unsigned reads;
} status_script_t;

static write_record_t writes[128];
static unsigned write_count;
static status_script_t uart0_script;
static status_script_t uart1_script;
static uint32_t uart0_data;
static uint32_t uart1_data;
static unsigned uart0_status_reads_at_data[32];
static unsigned uart0_data_write_count;

static status_script_t *script_for(uint32_t addr)
{
    return (addr == UART0_BASE + UART_STATUS) ? &uart0_script : &uart1_script;
}

static void set_script(status_script_t *script, const uint32_t *values,
                       unsigned count, uint32_t fallback)
{
    unsigned i;
    assert(count <= 64u);
    script->count=count; script->index=0u; script->fallback=fallback; script->reads=0u;
    for (i=0u;i<count;i++) script->values[i]=values[i];
}

static void reset_writes(void) { write_count=0u; }

uint32_t mmio_read32(uint32_t addr)
{
    status_script_t *script;
    if (addr == UART0_BASE + UART_STATUS || addr == UART1_BASE + UART_STATUS) {
        script=script_for(addr); script->reads++;
        if (script->index<script->count) return script->values[script->index++];
        return script->fallback;
    }
    if (addr == UART0_BASE + UART_DATA) return uart0_data;
    if (addr == UART1_BASE + UART_DATA) return uart1_data;
    assert(!"unexpected UART MMIO read");
    return 0u;
}

void mmio_write32(uint32_t addr, uint32_t value)
{
    assert(write_count < 128u);
    writes[write_count].addr=addr; writes[write_count].value=value; write_count++;
    if (addr==UART0_BASE+UART_DATA) {
        uart0_status_reads_at_data[uart0_data_write_count++]=uart0_script.reads;
    }
}

static void expect_write(unsigned index, uint32_t addr, uint32_t value)
{
    assert(index<write_count); assert(writes[index].addr==addr); assert(writes[index].value==value);
}

int main(void)
{
    static const uint32_t ready[] = {UART_STATUS_TX_READY};
    static const uint32_t busy[] = {0u,0u,0u};
    static const uint32_t eventual_ready[] = {0u,UART_STATUS_TX_READY};
    static const uint32_t two_byte_lora[] = {
        UART_STATUS_LORA_AUX, UART_STATUS_TX_READY,
        UART_STATUS_LORA_AUX, UART_STATUS_TX_READY
    };
    static const uint32_t aux_then_busy[] = {UART_STATUS_LORA_AUX,0u,0u};
    static const uint32_t eventual_lora[] = {
        0u,UART_STATUS_LORA_AUX,UART_STATUS_TX_READY
    };
    static const uint8_t pair[] = {0x12u,0x34u};
    uint8_t byte=0u;

    reset_writes();
    assert(uart0_set_baud_div(217u)==UART_RESULT_SUCCESS);
    assert(uart1_set_baud_div(65535u)==UART_RESULT_SUCCESS);
    assert(uart0_set_baud_div(216u)==UART_RESULT_INVALID_ARGUMENT);
    assert(uart1_set_baud_div(0u)==UART_RESULT_INVALID_ARGUMENT);
    assert(write_count==2u);
    expect_write(0u,UART0_BASE+UART_BAUD,217u);
    expect_write(1u,UART1_BASE+UART_BAUD,65535u);

    // Zero budget means zero polls and zero DATA writes.
    set_script(&uart1_script,ready,1u,UART_STATUS_TX_READY); reset_writes();
    assert(uart1_putc_timeout('A',0u)==UART_RESULT_TIMEOUT);
    assert(uart1_script.reads==0u && write_count==0u);

    set_script(&uart1_script,ready,1u,0u); reset_writes();
    assert(uart1_putc_timeout('B',1u)==UART_RESULT_SUCCESS);
    assert(uart1_script.reads==1u && write_count==1u);
    expect_write(0u,UART1_BASE+UART_DATA,'B');

    set_script(&uart1_script,busy,3u,0u); reset_writes();
    assert(uart1_putc_timeout('C',3u)==UART_RESULT_TIMEOUT);
    assert(uart1_script.reads==3u && write_count==0u);
    set_script(&uart1_script,eventual_ready,2u,0u); reset_writes();
    assert(uart1_putc_timeout('D',2u)==UART_RESULT_SUCCESS);
    assert(uart1_script.reads==2u && write_count==1u);
    assert(uart1_write_timeout(0,1u,1u)==UART_RESULT_INVALID_ARGUMENT);
    assert(uart1_puts_timeout(0,1u)==UART_RESULT_INVALID_ARGUMENT);

    set_script(&uart1_script,0,0u,UART_STATUS_TX_READY); reset_writes();
    assert(uart1_write_timeout(pair,2u,1u)==UART_RESULT_SUCCESS);
    assert(write_count==2u); expect_write(0u,UART1_BASE+UART_DATA,0x12u);
    expect_write(1u,UART1_BASE+UART_DATA,0x34u);

    set_script(&uart1_script,0,0u,UART_STATUS_TX_READY); reset_writes();
    assert(uart1_puts_timeout("X\n",1u)==UART_RESULT_SUCCESS);
    assert(write_count==3u); expect_write(0u,UART1_BASE+UART_DATA,'X');
    expect_write(1u,UART1_BASE+UART_DATA,'\r'); expect_write(2u,UART1_BASE+UART_DATA,'\n');

    set_script(&uart1_script,0,0u,UART_STATUS_RX_ERROR|UART_STATUS_RX_READY);
    uart1_data=0xabu; reset_writes();
    assert(uart1_rx_error()); assert(uart1_getc_nonblock(&byte) && byte==0xabu);
    uart1_clear_rx_error(); expect_write(0u,UART1_BASE+UART_STATUS,UART_STATUS_RX_ERROR);
    assert(!uart1_getc_nonblock(0));

    assert(lora_uart_init(0u)==LORA_UART_RESULT_SUCCESS);
    assert(lora_uart_init(216u)==LORA_UART_RESULT_INVALID_ARGUMENT);
    set_script(&uart0_script,ready,1u,UART_STATUS_LORA_AUX); reset_writes();
    assert(lora_uart_wait_aux_ready_timeout(0u)==LORA_UART_RESULT_AUX_TIMEOUT);
    assert(uart0_script.reads==0u && write_count==0u);

    set_script(&uart0_script,busy,3u,0u); reset_writes();
    assert(lora_uart_send_ascii_timeout('L',2u,2u)==LORA_UART_RESULT_AUX_TIMEOUT);
    assert(write_count==0u);

    set_script(&uart0_script,aux_then_busy,3u,0u); reset_writes();
    assert(lora_uart_send_ascii_timeout('L',1u,2u)==LORA_UART_RESULT_UART_TX_TIMEOUT);
    assert(write_count==0u);

    set_script(&uart0_script,two_byte_lora,4u,0u); reset_writes();
    uart0_data_write_count=0u;
    assert(lora_uart_send_bytes_timeout(pair,2u,1u,1u)==LORA_UART_RESULT_SUCCESS);
    assert(write_count==2u); expect_write(0u,UART0_BASE+UART_DATA,0x12u);
    expect_write(1u,UART0_BASE+UART_DATA,0x34u);
    assert(uart0_status_reads_at_data[0]==2u && uart0_status_reads_at_data[1]==4u);
    set_script(&uart0_script,eventual_lora,3u,0u); reset_writes();
    uart0_data_write_count=0u;
    assert(lora_uart_send_ascii_timeout('E',2u,1u)==LORA_UART_RESULT_SUCCESS);
    assert(uart0_script.reads==3u && write_count==1u);
    assert(uart0_status_reads_at_data[0]==3u);
    assert(lora_uart_send_bytes_timeout(0,1u,1u,1u)==LORA_UART_RESULT_INVALID_ARGUMENT);

    puts("SUMMARY: PASS P07B UART/LoRa bounded firmware mock-MMIO verification");
    return 0;
}
