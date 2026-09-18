.option push
.option arch, +zicsr

.section .start, "ax", @progbits
.globl _start

_start:
    la   t0, __trap_entry
    csrw mtvec, t0

    la   sp, __stack_top

    la   t0, __bss_start
    la   t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b

2:
    call main

3:
    j    3b

.section .trap, "ax", @progbits
.balign 4
.globl __trap_entry
.type __trap_entry, @function
__trap_entry:
    csrr t0, mcause
    csrr t1, mepc
    li   t2, 0x54524150

.globl __trap_fail_stop
__trap_fail_stop:
    j    __trap_fail_stop
.size __trap_entry, . - __trap_entry

.option pop
