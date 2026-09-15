# Interrupt and Trap Architecture

The current baseline implements synchronous CPU traps but does not integrate a PLIC or an external asynchronous interrupt path.

- `ECALL` traps with cause 11.
- `EBREAK` takes a precise breakpoint exception with cause 3 and redirects through `mtvec`.
- Misaligned instruction, load, and store cases use causes 0, 4, and 6.
- Data-bus load/store errors use access-fault causes 5 and 7.
- Illegal SYSTEM encodings are checked; broader illegal-instruction closure remains in progress.
- `FENCE` and `FENCE.I` retire as legal no-ops because the design has no cache.
- With RV32I IALIGN=32, stored and read `mepc[1:0]` are zero; `MRET` redirects to that exact canonical value and retires once.

GPIO and switch blocks expose local IRQ signals for later integration, but these signals intentionally have no CPU/PLIC consumer in this baseline. PLIC source mapping, priority, claim/complete, CPU interrupt entry, and interrupt-state restoration are future work and are not represented as implemented.
