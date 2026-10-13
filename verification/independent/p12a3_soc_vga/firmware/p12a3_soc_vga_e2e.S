/* Test-only RV32I image; the runner archives ELF, symbols and disassembly. */
.option norvc
.option norelax
.section .start,"ax"
.global _start, fault_store, younger_sentinel, trap_entry, normal_terminal, trap_terminal
_start:
    lui s0, 0x20010
    lui s1, 0x10000
    la t0, trap_entry
    csrw mtvec, t0
ready_poll:
    lw t1, 0(s0)
    andi t2, t1, 16
    beqz t2, ready_poll
#if FAULT_CASE
    j fault_path
#else
    j normal_path
#endif
normal_path:
    lui t3, 0x20000
    li t4, 0x12345678
    sw t4, 0(t3)
    li t3, 0x200095fc
    li t4, 0x89abcdef
    sw t4, 0(t3)
    sw zero, 4(s0)
    lw t1, 0(s0)
    li t0, 0x47314f4b
    sw t0, 0(s1)
normal_terminal:
    j normal_terminal
fault_path:
    li t3, 0x20009600
    li t4, 0xa5a5a5a5
fault_store:
    sw t4, 0(t3)
younger_sentinel:
    addi a0, zero, 0x55
    sw a0, 12(s1)
    j younger_sentinel
.section .trap,"ax"
trap_entry:
    csrr t0, mcause
    csrr t1, mepc
    sw t0, 4(s1)
    sw t1, 8(s1)
    li t2, 0x47314641
    sw t2, 0(s1)
trap_terminal:
    j trap_terminal
