/* Test-only source-bound RV32I integration workload. */
.option norvc
.option norelax
.section .start,"ax"
.global _start, fault_store, younger_sentinel, trap_entry, normal_terminal, trap_terminal
_start:
 lui s0,0x20010
 lui s1,0x10000
 la t0,trap_entry
 csrw mtvec,t0
 jal ra,ready
 li s2,0x80000001
 jal ra,render
 li t0,10
 sw t0,0(s0)
#if LANE == 0
 li t0,1
 sw t0,4(s0)
 jal ra,traffic
 jal ra,done
 li t0,1
 sw t0,0(s0)
 li t0,2
 sw t0,0(s0)
 li t0,8
 sw t0,0(s0)
 li t0,2
 sw t0,4(s0)
 jal ra,done
 li t0,2
 sw t0,0(s0)
 li s2,0x55aa55aa
 jal ra,render
 li t0,3
 sw t0,4(s0)
 jal ra,traffic
 jal ra,done
 /* Leave combined DONE sticky while the observer checks a full tagged frame. */
 j success
#elif LANE == 1 || LANE == 2
 li t0,3
 sw t0,4(s0)
#if LANE == 1
 lui t3,0x20000
#else
 addi t3,s0,4
#endif
 li t4,1
fault_store:
 sw t4,0(t3)
younger_sentinel:
 li t0,0x55
 sw t0,12(s1)
 j younger_sentinel
#elif LANE == 3
 li t0,1
 sw t0,4(s0)
 jal ra,done
 j success
#elif LANE == 4
 li t0,3
 sw t0,4(s0)
abort_poll:
 lw t1,0(s0)
 andi t2,t1,8
 beqz t2,abort_poll
 /* DONE/VSYNC acknowledgements must preserve the unselected ABORT. */
 li t0,2
 sw t0,0(s0)
 li t0,1
 sw t0,0(s0)
 lw t1,0(s0)
 sw t1,16(s1)
 li t0,8
 sw t0,0(s0)
 jal ra,ready
 li s2,0x55aa55aa
 jal ra,render
 li t0,1
 sw t0,4(s0)
 jal ra,done
 j success
#endif
success:
 li t0,0x47324f4b
 sw t0,0(s1)
normal_terminal:
 j normal_terminal
#if LANE != 1 && LANE != 2
fault_store:
 sw zero,12(s1)
younger_sentinel:
 j younger_sentinel
#endif
ready:
 lw t1,0(s0)
 andi t2,t1,20
 li t3,16
 bne t2,t3,ready
 ret
done:
 lw t1,0(s0)
 andi t2,t1,2
 beqz t2,done
 ret
render:
 lui t3,0x20000
 li t4,0
 li t5,9600
render_loop:
 xor t6,t4,s2
 sw t6,0(t3)
 addi t3,t3,4
 addi t4,t4,1
 bne t4,t5,render_loop
 ret
traffic:
 li t0,0x12345678
 sw t0,20(s1)
 lw t1,20(s1)
 lui t3,0x40010
 lw t2,0(t3)
 ret
.section .trap,"ax"
trap_entry:
 csrr t0,mcause
 csrr t1,mepc
 sw t0,4(s1)
 sw t1,8(s1)
 jal ra,done
 li t0,0x47324641
 sw t0,0(s1)
trap_terminal:
 j trap_terminal
