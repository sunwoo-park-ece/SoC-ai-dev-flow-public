#include <stdint.h>
#include "timer.h"
#include "gpio.h"
#include "uart.h"
#include "soc_mmio.h"
#include "soc_memory_map.h"

volatile uint32_t signature;
volatile uint32_t scratch[2];
static void require(int ok)
{
    if (!ok) { signature = 0xdead0001u; for (;;) {} }
}
int main(void)
{
    volatile uint8_t *b = (volatile uint8_t *)scratch;
    volatile uint16_t *h = (volatile uint16_t *)scratch;
    unsigned i;
    scratch[0] = 0x80ff7f01u;
    require(b[0] == 1 && b[1] == 127 && b[2] == 255 && b[3] == 128);
    require(((volatile int8_t *)scratch)[2] == -1);
    require(((volatile int16_t *)scratch)[1] == (int16_t)0x80ff);
    b[1] = 0x85; h[1] = 0xf123;
    scratch[1] = scratch[0]; // immediate partial-store/load RAW exercise
    require(scratch[1] == 0xf1238501u);
    timer_start(2);
    for (i = 0; i < 32 && !timer_status(); ++i) {}
    require(timer_status() == 1 && timer_count() == 2);
    timer_clear_ready(); require(timer_status() == 0);
    timer_reload();
    gpio_write(0xa55a); gpio_set_direction(0xffff);
    require(gpio_read_output() == 0xa55a);
    require(uart0_set_baud_div(217) == 0 && uart1_set_baud_div(217) == 0);
    /* Intentional raw diagnostic traffic to exercise busy ACCESS backpressure.
     * This fixture is the sole UART owner, not a normal application API example. */
    mmio_write32(UART0_BASE, 0x31); mmio_write32(UART0_BASE, 0x32);
    mmio_write32(UART1_BASE, 0x41); mmio_write32(UART1_BASE, 0x42);
    require(mmio_read32(AES_GCM_BASE + AES_VERSION) == 0x322e3030);
    signature = 0x50313447u;
    /* Precise rejected load; no architectural access to excluded IP required. */
#ifndef FAULT_ADDRESS
#define FAULT_ADDRESS 0x40040100u
#endif
    __asm__ volatile("mv t2,%0\n.globl selected_fault\nselected_fault:\n"
                     "lw t3,0(t2)\n" : : "r"(FAULT_ADDRESS) : "t2", "t3", "memory");
    signature = 0xdead0002u; // must be cancelled by precise fault
    return 0;
}
