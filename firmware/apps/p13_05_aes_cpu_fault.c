#include <stdint.h>
#ifndef P13_FAULT
#define P13_FAULT 0
#endif
#if P13_FAULT == 0
#define P13_ADDR "0x40040100"
#define P13_OP "lw t2,0(t0)"
#elif P13_FAULT == 1
#define P13_ADDR "0x40040100"
#define P13_OP "sw t2,0(t0)"
#elif P13_FAULT == 2
#define P13_ADDR "0x40040008"
#define P13_OP "lb t2,0(t0)"
#elif P13_FAULT == 3
#define P13_ADDR "0x40040008"
#define P13_OP "lh t2,0(t0)"
#elif P13_FAULT == 4
#define P13_ADDR "0x40040008"
#define P13_OP "sb t2,0(t0)"
#elif P13_FAULT == 5
#define P13_ADDR "0x40040008"
#define P13_OP "sh t2,0(t0)"
#elif P13_FAULT == 6
#define P13_ADDR "0x40040009"
#define P13_OP "lh t2,0(t0)"
#elif P13_FAULT == 7
#define P13_ADDR "0x4004000a"
#define P13_OP "lw t2,0(t0)"
#elif P13_FAULT == 8
#define P13_ADDR "0x40040009"
#define P13_OP "sh t2,0(t0)"
#elif P13_FAULT == 9
#define P13_ADDR "0x4004000a"
#define P13_OP "sw t2,0(t0)"
#else
#error invalid fault case
#endif
/* Disassembly-labelled intentional fault; never a C misaligned dereference. */
__attribute__((naked,noinline)) static void fault(void){
 __asm__ volatile("li t0," P13_ADDR "\nli t2,0x12345678\n"
 ".globl p13_fault_instruction\np13_fault_instruction:\n" P13_OP "\n"
 ".globl p13_younger\np13_younger:\nli t4,0x10000000\nsw t2,0(t4)\n"
 ".globl p13_fault_end\np13_fault_end:\nj p13_fault_end\n" ::: "memory");
}
int main(void){fault();for(;;)__asm__ volatile("nop");}
