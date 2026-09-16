# Engineering Roles

The approved specification is the contract shared by implementation and independent verification.

| Role | Primary responsibility | Canonical outputs |
|---|---|---|
| Chat | Clarify intent and approve specifications with the developer | decisions and approved spec changes |
| WSL Ubuntu + Codex | RTL/FW implementation, Verilator checks, vendor CLI builds, ModelSim/XSim runs, evidence normalization, engineering reports | source changes and reproducible engineering evidence |
| Antigravity | Independent testbench/DV design from the specification | tests, assertions, coverage, review findings |
| Windows Work | Presentation-oriented editing using reviewed evidence; optional GUI interaction | portfolio, PDF/PPT, interview material |

Raw execution artifacts belong under `$RUN_ROOT`; reviewed, sanitized evidence may be promoted into the public repository. Licensed/generated vendor state remains under `$VENDOR_ROOT`. Windows Work must not become the only location of engineering facts or overwrite raw evidence.

When RTL and DV disagree, clarify the specification first. Neither side should silently redefine behavior to match the other.
