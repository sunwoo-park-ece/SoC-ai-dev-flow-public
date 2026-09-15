# RV32I CPU Core Contract

The integrated CPU is a 32-bit, five-stage RV32I pipeline with IF, ID, EX, MEM, and WB stages.

## Implemented behavior

- Integer register file with x0 write suppression
- Decode, immediate generation, ALU, branch/jump, load/store, and CSR paths
- Forwarding and load-use interlocking
- Full-pipeline hold for system-bus backpressure
- Stage-valid tracking and fetch-token control across stalls, redirects, and flushes
- Commit-qualified architectural register writes and `minstret` increments
- Precise synchronous trap ordering for the verified trap, bus-fault, CSR-stall, and competing-event cases
- Canonical IALIGN=32 `mepc` behavior and one-shot MRET retirement

The current core has no cache, branch predictor, compressed-instruction extension, or external architectural commit trace. PLIC-driven asynchronous interrupts and broader ISA closure are intentionally outside this preview's implemented claim.
