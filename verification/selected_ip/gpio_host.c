#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "gpio.h"
static uint32_t dir=0, out=0, pending=0x21;
static int inject_dir;
uint32_t mmio_read32(uint32_t a)
{
    switch(a) {
    case 0x40010000: return 0xabcd;
    case 0x40010004: return out;
    case 0x40010008:
        if (inject_dir) { puts("INJECTION_REACHED GPIO_DIRECTION_READ"); fflush(stdout); }
        return dir ^ (inject_dir ? 0x100u : 0u);
    case 0x4001001c: return pending;
    default: assert(!"GPIO_READ_ADDRESS"); return 0;
    }
}
void mmio_write32(uint32_t a,uint32_t v)
{
    assert((v & 0xffff0000u)==0);
    switch(a) {
    case 0x40010004: out=v; break;
    case 0x40010008: dir=v; break;
    case 0x4001001c: pending &= ~v; break;
    default: assert(!"GPIO_WRITE_ADDRESS");
    }
}
int main(int argc, char **argv)
{
    (void)argv;
    gpio_set_direction(0xffff1234); assert(dir==0x1234);
    inject_dir = argc > 1;
    gpio_set_output(3); assert(dir==0x1237);
    gpio_set_input(0x30); assert(dir==0x1207);
    gpio_write(0x1234a55a); assert(out==0xa55a);
    assert(gpio_read()==0xabcd && gpio_read_output()==0xa55a);
    assert(gpio_irq_status()==0x21); gpio_irq_clear(1);
    assert(gpio_irq_status()==0x20);
    puts("SUMMARY_PASS GPIO_HOST"); return 0;
}
