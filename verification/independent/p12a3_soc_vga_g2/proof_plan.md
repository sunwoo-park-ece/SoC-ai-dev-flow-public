# Bounded CPU-integrated VGA verification

The functional target is the unchanged SoC with the OPEN_SIM_VERILOG model
profile and a statically bound test-only RV32I image. Expected framebuffer
contents derive from accepted CPU word stores; addresses/data are additionally
checked against the test image's indexed pattern. Expected ownership derives
from reset baseline and accepted command history plus an independent 800x525
pixel counter. Actual internal events are passive observations, never expected
state inputs. Full system reset qualification remains 1,000,000 HCLK cycles.

P0 tests swap, clear-only, combined, selective event acknowledgements and
physical RGB corners; P1/P2 test busy stores with precise architectural fault
diagnostics while the first combined command completes. P3 resets externally
before the first natural frame commit and boots again. P4 calls the existing
connected portable PLL task once, between sampling edges after a natural commit
while combined clear is outstanding. The task's lock-count recovery and clocks
are retained. This is modeled environment stimulus, not physical PLL proof.

## Requirement to proof / mutation design matrix

All negative controls below are isolated **observation-input self-tests**.
They change a copied new raw record, recalculate its checksum, and execute the
same semantic checker and integrity guard through real leaf and parent calls.
Neither original raw nor any Production/model instance or source is altered.
Activation records bind the changed record and before/after values. Positive
control is the unchanged originating lane; a negative must report the exact
listed PID and nonzero leaf, guard and parent exits. No compile/timeout kill.

| Contract / missing guarantee | Falsifying isolated observation | Exact checker PID | Passing control |
|---|---|---|---|
| accepted bus owner / held route | change a completed transaction route | G2_BUS | P0 |
| unique request and frame commit / ACK causality | duplicate command or move ACK before commit | G2_CAUSALITY | P0 |
| bank safety / immutable clear target | change physical cleaner bank | G2_BANK | P0 |
| exact physical clear extent / first DONE | remove word9599 or move DONE before last write | G2_COMPLETION | P0 |
| selected W1C / sticky event | change W1C post-DONE bit | G2_W1C | P0 |
| independent tagged RGB | flip one white/black RGB sample | G2_PIXEL | P0 |
| precise two-cycle ERROR / ELF cause and PC | change error-final response or diagnostic cause | G2_FAULT | P1 |
| external reset / stale epoch | insert canceled DONE after reset | G2_RECOVERY | P3 |
| connected modeled loss / physical gating | mark a lock-low sample with physical WE | G2_PLL | P4 |
| source/image/run provenance | checksum-consistent altered IMEM or omitted lane | G2_IDENTITY / G2_CASE_SET | full targeted set |

Checker identity, image identity, actual process exits, artifacts, commands and
source before/after are bound in the fresh run manifest. Failed attempts are
retained. Partial executions remain incomplete and cannot support acceptance.
G3 regression, structural CDC, STA, vendor/board and acceptance are separate.
