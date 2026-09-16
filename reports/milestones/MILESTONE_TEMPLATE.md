# Milestone: <title>

## 1. Objective

Describe the engineering goal of this milestone.

## 2. Baseline / Initial Architecture

Document the starting design and the relevant constraints.

## 3. Problem / Limitation

Describe the observed issue, bottleneck, failure mode, or limitation.

## 4. Design Decision

Explain the selected change and why it was chosen over alternatives.

## 5. Implementation

Summarize the RTL / firmware / verification changes that realize the decision.

## 6. Verification Strategy

Document how correctness was checked.

Examples:
- Verilator lint / smoke simulation
- firmware-driven SoC simulation
- UVM regression
- assertion / coverage result
- FPGA synthesis / implementation
- timing analysis

## 7. Quantitative Results

Record only measured values.

| Metric | Before | After | Delta | Evidence |
|---|---:|---:|---:|---|
| Fmax | N/A | N/A | N/A | |
| WNS | N/A | N/A | N/A | |
| TNS | N/A | N/A | N/A | |
| LUT | N/A | N/A | N/A | |
| FF | N/A | N/A | N/A | |
| BRAM | N/A | N/A | N/A | |
| DSP | N/A | N/A | N/A | |
| Throughput | N/A | N/A | N/A | |
| Latency | N/A | N/A | N/A | |

Remove metrics that do not apply and add project-specific metrics when needed.

## 8. Before vs After

Summarize the architectural and behavioral difference concisely.

## 9. Trade-offs

Document costs accepted in exchange for the improvement.

Examples:
- CPI increase
- additional latency
- additional area
- more control complexity
- reduced peak throughput in a corner case

## 10. Lessons Learned

Record the engineering insight that should carry into later design decisions.

## 11. Resume / Interview Key Points

Write concise, technically defensible points derived from the evidence above.

Do not exaggerate scope or claim unverified results.

## 12. Evidence References

List traceable sources such as:
- SPEC path / revision
- Git commit / PR / diff
- simulation report
- regression report
- Quartus / Vivado timing report
- utilization report
- script output

## Evidence Classification

Use these labels when helpful:

- **Measured Fact** — directly supported by simulator / FPGA tool output
- **Design Interpretation** — engineering explanation of the measured result
- **Trade-off** — cost accepted in exchange for the improvement

If a value cannot be verified, record it as **N/A / unavailable** rather than estimating it.
