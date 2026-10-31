# P12A5 A2 independent verification

Production files and existing fixtures are read-only. `proof_plan.md` defines oracle independence, mutations, isolation and claim boundaries. The program uses the existing IMEM INIT_FILE parameter; reset qualification runs naturally. The only hierarchical stimulus is the existing behavioral PLL model's documented lock-loss hook. Monitors never assign production state.

From the public worktree, select a fresh run directory outside all repositories:

```sh
export PYTHONDONTWRITEBYTECODE=1
export YOSYS=/path/to/yosys
python3 -B verification/independent/p12a5_hclk_loop/suite.py --run-root "$DV_RUN/core"
python3 -B verification/independent/p12a5_hclk_loop/sensitivity.py "$DV_RUN/core/golden-semantic" "$DV_RUN/core/checker-fixtures"
python3 -B verification/independent/p12a5_hclk_loop/audit.py "$DV_RUN/core/golden-semantic" "$DV_RUN/core/hold-audit"
python3 -B verification/independent/p12a5_hclk_loop/reset.py "$DV_RUN/reset"
```

Set `DV_RUN` explicitly to a unique absolute external directory. `suite.py` preserves compile/elaboration failures and never classifies them as kills. Each mutant has target exit 0 and a specific nonzero leaf/guard/parent chain; an aggregate driver can return zero only after asserting the intended rejections. Checker-input fixtures are not DUT executions or functional mutant kills.

`oracle.py` generates instructions and independently interprets architectural effects using registers, CSR state and a byte-addressed memory image. `check.py` compares accepted request order, pre-edge BRAM inputs, payload/lanes, full retirement/GPR/CSR streams, trap cause/PC, peripheral effects and final untouched bytes. `audit.py` adds address/control stability across waits. `reset.py` checks external-reset cancellation and DMEM retention/recovery at a real UART stall. `structural.py` traverses fresh elaborated/optimized graphs; `boundaries.sv` explicitly declares excluded vendor interfaces.

These are portable simulation and structural claims, not vendor memory-collision behavior, exhaustive CDC proof, full-frame swap verification, fitted timing or board evidence. No generated runs, binaries or netlists belong in this directory.
