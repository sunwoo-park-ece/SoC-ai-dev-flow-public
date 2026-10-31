# P12A5 A2 independent DV proof plan

Scope: production A2 CPU/master/fabric/DMEM/bridge/ADC/UART/VGA, portable OPEN_SIM bindings. Production RTL/spec/FW and existing DV remain immutable. Only this new DV directory and unique local run outputs are writable. No Quartus/board/Git integration.

Oracle: a generated RV32I program plus a separate architectural interpreter supplies ordered retired instructions, GPR values, legal/faulting bus requests, payload bytes, strobes, memory byte image, peripheral acceptance and precise trap cause/PC. Expected values never come from observed HWDATA/mask/HRESP or private MEM metadata. Accepted address history supplies data-phase ownership; BRAM inputs are sampled BEFORE the rising-edge write. Compare all active lanes and final untouched bytes. IMEM uses its existing INIT_FILE parameter, external KEY reset is allowed to run its full million-cycle qualification. No force/deposit or hierarchy writes to production state. Hierarchical observations are monitor inputs only. Existing behavioral PLL lock-loss task supplies physical-model lock stimulus, not an acceptance bypass.

Assertions: REQUEST_ORDER, RESPONSE_CONTRACT, WRITE_OWNER, WRITE_ADDRESS, WRITE_LANES, WRITE_DATA, PAYLOAD_STABLE, ERROR_FINAL_CANCEL, RETIRE_ORDER, GPR_RESULT, TRAP_CAUSE_PC, RAM_IMAGE, APB_ACCEPT, UART_POLICY, VGA_PHYSICAL, COVERAGE_COMPLETE. Missing required observations fail the guard, independently of simulator exit 0.

Mutation matrix (all conditional on demonstrated reach and correct rejection):

| Fault | Isolated source-copy injection | Reach and intended assertion |
|---|---|---|
| F -> HWDATA | CPU output AND !F | Fresh elaborated response path witness; STRUCT_RESPONSE_DATA rejects |
| F -> mask | CPU raw-mask output AND !F | Fresh elaborated response path witness; STRUCT_RESPONSE_MASK rejects even without SCC |
| Shifted mask | StoreAligner SB offset0 mask 0001 -> 0010 | Real program SB reaches physical BRAM; WRITE_LANES rejects |
| Wrong address | DMEM BRAM wraddress = addr_reg XOR 1 | Accepted real store reaches write edge; WRITE_ADDRESS rejects |
| Final ERROR phantom | DMEM WEN additionally asserted when ready, unselected, next HADDR=10000040 and nonzero lane intent | Faulting store with younger EX address reaches final ERROR; WRITE_OWNER rejects with ERROR/ready evidence |

Passing control uses the exact same source list, program and checker. Copies live only in new run subdirectories. No mutation reaches production files or golden DUT execution. Structural controls are actual re-elaboration, not saved graph edge edits. Functional mutants must compile and run, reach their target and fail the exact semantic checker; timeout/compile failure is not a kill. Leaf checker -> evidence guard -> parent return nonzero and retain original assertion. Sensitivity tests also include target=0 with missing/truncated evidence to reject cosmetic success.

Limits: vendor interiors/fitted timing, exhaustive CDC/state space, swap acknowledgement across an entire frame and existing C08/C09/R7 acceptance remain separate. Any actual production defect => preserve evidence, BLOCK and STOP; no repair of production/spec to obtain PASS.
