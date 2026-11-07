# CPU/AHB ownership and reset evidence

## Status and scope

- Evidence ID: `CPU-AHB-C1A-EV-01`
- Result: `PASS_BOUNDED`; review status: `PENDING_REVIEW`
- Source snapshot: `c7c607353ab3dadbb0bebbc6d5e178dfbccea286`
- Evidence date: 2026-11-07
- Related requirements: `BUS-002`, `BUS-003`, `BUS-004`, `BUS-005`; this package does not change requirement status.

This package records one owner-operated, source-bound run of the CPU/AHB suite, hold and natural-reset checks. It supports only the exercised transaction and structural cases below; it is not full processor, SoC, AHB or physical sign-off.

## Contract and method

The memory, CPU interface, AHB fabric and CPU contracts are described in [memory](../../../spec/02_memory_subsystem.md), [CPU interface](../../../spec/03_cpu_interface.md), [AHB fabric](../../../spec/04_ahb_fabric.md) and [CPU core](../../../spec/21_cpu_core.md). The stimulus and independent instruction/register/byte-memory expectations are defined by `verification/independent/p12a5_hclk_loop/oracle.py`; `check.py` compares accepted transactions and physical effects with those expectations. `structural.py` checks saved optimized and unoptimized graphs, with explicit sequential and blackbox boundaries. `audit.py` checks held bus values and `reset.py` checks retention and cancellation. The testbench and runners are included in [source hashes](source_hashes.sha256).

The runner used Icarus Verilog 11.0 and Yosys 0.69+286. It recorded compiler and checker commands and exit codes; those records are not an independent operating-system execution trace. Tool exits alone do not establish the semantic verdict. The full portable source inputs observed for these checks are listed in the manifest; isolated generated mutant copies and local tool binaries are not repository inputs.

## Claim and counterexample matrix

| Claim | Contract observation and oracle | Result | Sensitivity and limit |
|---|---|---|---|
| Semantic ownership and error handling | Predicted accepted requests, byte memory and retirements compared with pre-edge bus/write observations, fault and two-cycle error behavior. | PASS_BOUNDED: 336 retirements, 67 requests, 15 physical writes, 18 traps, 11 bus errors, 2168 UART wait cycles and 16 cross-slave transition pairs. | Isolated source copies rejected `WRITE_LANES`, `WRITE_ADDRESS`, `WRITE_OWNER`; passing target and failing checker/guard/parent were separately recorded. Only exercised inputs are covered. |
| Response-to-payload structure | Saved graphs checked for response reachability to write data/mask and SCCs. | PASS_BOUNDED within the recorded model and blackbox/sequential boundaries. | Isolated source copies rejected `STRUCT_RESPONSE_DATA` and `STRUCT_RESPONSE_MASK`. This is not whole-design vendor-netlist or CDC proof. |
| Hold | Accepted bus observations checked for stable address/control over waits. | PASS_BOUNDED: 2169 held pairs. | An isolated modified trace rejected `AHB_HOLD`; this tests the checker input, not a production DUT mutation. |
| Natural reset | Expected byte-memory state compared with three 32-word observed snapshots and reset/recovery summary. | PASS_BOUNDED for this exercised scenario. | An isolated modified observation rejected `RESET_MEMORY`; same-runtime reset acknowledgement remains unproven. |

For golden cases target, checker, guard and parent returned 0. Five isolated source copies produced the named checker rejection with successful target and checker/guard/parent exit 1. The hold and reset observation fixtures likewise produced the named expected rejection. These negative controls are distinct from the golden DUT result. A later read-only replay of the existing checker was a consistency check, not a separately authored oracle.

## Reproduction and source identity

The source snapshot and portable inputs are listed in [source_hashes.sha256](source_hashes.sha256); their SHA-256 values are byte hashes, not a Git commit identifier. The run used existing `suite.py`, `audit.py` and `reset.py` under `verification/independent/p12a5_hclk_loop/`, with an external output directory. A portable, self-contained reproduction procedure including tool configuration and result custody has not yet been independently approved, so no reproduction command is asserted here.

The output inventory is held separately from this derivative; it is a post-run checksum inventory, not a cryptographic signature. The output package is pending independent review and does not refer to its own future documentation commit.

## Not run and limitations

Actual-core CPU-to-SoC AES end-to-end, the separate exhaustive master domain, natural AES overflow, a fresh fitted timing analysis on this snapshot, external I/O timing, CDC and board checks were not run in this evidence scope. Prior historical tests or a candidate fit are not represented as runs on this snapshot. No universal equivalence, formal closure, full ISA coverage, full SoC regression, board acceptance or release is claimed. Behavioral memory and structural blackboxes do not establish vendor memory behavior or physical timing. See [result.json](result.json) for machine-readable scope and verdicts.
