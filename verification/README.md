# Verification

UVM and testbench source lives here.

Primary owner: **Antigravity (UVM / DV Engineer / Independent Reviewer)**.

Typical contents:

```text
verification/
├─ agents/
├─ env/
├─ sequences/
├─ scoreboard/
├─ coverage/
├─ assertions/
├─ tests/
└─ tb_top/
```

## Verification Contract

Verification intent must be derived from the authoritative documents under `spec/`, not reverse-engineered only from RTL behavior.

```text
             SPEC
              |
              v
         Antigravity
              |
              v
           UVM / DV
              |
              v
       independent evidence
```

The verification environment should independently check:
- protocol behavior
- register semantics
- error behavior
- interrupt behavior
- reset behavior
- legal/illegal transactions
- functional coverage targets
- feature-specific corner cases

If verification exposes an ambiguity in expected behavior, route the question to **Developer + ChatGPT Chat** so the SPEC is clarified before either RTL or DV is changed to match the other.

## Phase 3 engineering lanes

`models/` contains project-owned simulation-only substitutes for private memories,
PLLs and ADC IP. `directed/` contains focused memory, VGA, ADC, GSensor and CPU
tests, plus a mixed-language SoC structural smoke. They complement rather than
replace independent specification-driven DV. Run the open lanes with
`RUN_ROOT=/path/to/runs bash scripts/wsl/open_sim.sh example` and the actual
VHDL/Verilog integration lane with
`RUN_ROOT=/path/to/runs bash scripts/wsl/modelsim_mixed.sh example`.
