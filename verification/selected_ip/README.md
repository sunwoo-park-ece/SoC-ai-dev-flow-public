# Selected existing-IP verification composition

Run from any directory, with a **fresh** output path outside the checkout:

```bash
python3 -B scripts/wsl/selected_ip_test.py --run-root "$RUN_ROOT" --selftest
```

`sources.json` contains explicit resolved CPU, bus, reset, memory-model, peripheral,
real AES VHDL and firmware source lists. It does not alter the legacy top/profile.
The test-only `selected_soc` retains the CPU-local IF/ID IMEM and baseline DMEM
byte-lane/RAW path, bridge and accepted-owner response mux. Only APB slots 0,1,2,4,6
are exposed; other addresses use the existing two-cycle default ERROR pattern.
This omission defines this fixture, not a new production map or frozen contract.
No VGA/VRAM, ADC, G-sensor, HEX, SW/LED or generated vendor-IP elaboration input
is supplied. Compilation with this list therefore detects accidental dependencies.

Firmware compiles only the listed sources with the unchanged RV32I flags, startup
and linker layout. IMEM and initialized DMEM contents are supplied before reset;
there is no new boot loader or startup data-copy policy. Memories are open models,
not proof of vendor read-during-write/reset/initialization behavior. Test reset
qualification is shortened to eight clocks through the existing controller
parameter; production's million-clock default is unchanged.

## Contract and proof map

| Obligation | Independent expectation / actual observation | Bound |
|---|---|---|
| CPU loads/stores and partial RAW | Literal byte/halfword signed/unsigned predicates in smoke FW, plus independent TB checks of both final words = f1238501 | Directed program, not full ISA proof |
| LoadExtender binary input behavior | Arithmetic shift/mask/sign oracle, all byte values at all offsets plus deterministic words, read/no-read and all funct3 values: 262144 cases | No universal X/Z equivalence claim |
| UART wait/ownership | Two prescribed bytes per UART; count only completing DATA ACCESS, compare ordered values, require real busy waits and stable bus payload | Digital integration; no physical serial receipt |
| Default/bridge ERROR | Monitor first ERROR/ready-low then ERROR/ready-high and trap cause 5 / ELF fault-site PC; younger signature write must not commit | One alias fault in smoke; existing component suites have their stated scope |
| GPIO / reset | Literal a55a output and async reset Hi-Z; memory retention; standalone host address/mask/RMW/W1C assertions | GPIO IRQ digital behavior remains bounded by existing P04 evidence; no new pin qualification |
| AES integration | Real VHDL library elaborated under CPU composition; CPU reads v2 VERSION. Separate existing actual-wrapper/core APB suite uses independently generated cryptography.AESGCM vectors | No claim CPU smoke performs crypto; D08 remains NOT_PROVEN |
| Trusted AES driver | Eight separately executed existing argument/version/budget/result/authentication host cases | Sampled host scope, not replay of all historical P13 tests |
| Final identity and propagation | Real source-before/after equality; original command stdout/stderr and exits; non-PASS child or guard rejects final result | No copied constants asserting unchanged state |

Owning contracts: spec/02,03,04,05,06,09,10,11,14,19,21. Existing Timer maximum-N
directed case uses controlled near-terminal internal state and retains its original
scope; it is not independent natural-overflow evidence. Existing component tests
are not relabeled independent review. Lint uses a structural AES stub only; both
CPU smoke and AES cryptographic lanes use all 14 real VHDL units.

## Counterexample design matrix and isolation

All functional lanes use unmodified production RTL with natural clock/reset/bus
stimulus. No force/deposit or mutation reaches those DUTs. Negative controls are
separate invocations with their own logs/results, never functional PASS runs.

| Fault | Target / injection | Reach and passing control | Expected rejection / propagation |
|---|---|---|---|
| Bad signature observation | TB-local sampled signature XOR 1, after reading unchanged DUT memory | `INJECTION_REACHED checker CPU_SIGNATURE`; same smoke without adapter passes | CPU_SIGNATURE comparison rejects, simulator/parent nonzero, child result FAIL |
| Missing first ERROR observation | TB-local pending observation cleared, actual bus untouched | `INJECTION_REACHED checker ERROR_PHASE` on final ERROR; same bus sequence passes without adapter | ERROR_PHASE rejects, simulator/parent nonzero, child result FAIL |
| Child command failure | Separate test command exits 37; no source/DUT mutation | Explicit CHILD_EXIT reach message; ordinary commands exit 0 | Actual launch/must path preserves target exit 37, final FAIL/nonzero |
| Forged source record | Isolated run's before-manifest hash replaced; source files untouched | GUARD_SOURCE reach message after successful target; intact record compares equal | GUARD_SOURCE_MISMATCH, target=0/guard=1/final=1, FAIL |
| GPIO direction read corruption | Host mock returns DIR XOR 0x100 (outside the requested output mask); production driver source unchanged | GPIO_DIRECTION_READ reach message; ordinary host case passes | Exact RMW result assertion dir==0x1237 rejects; parent requires that specific diagnostic |
| Load output observation corruption | TB-local sampled output XOR 1 for LB, actual LoadExtender unchanged | LOAD_OBSERVATION reach message; unadapted arithmetic oracle control passes | LOAD_EXTEND rejects with nonzero simulator exit |

`--selftest` executes these through the real parent entry point and checks named
semantic evidence plus nonzero exit and FAIL JSON. This proves these specific
checker/runner sensitivities; it does not prove that every possible defect is
detected. It is not independent review or Owner acceptance. Original logs and
failed attempts remain in external run directories. No vendor/board/STA/CDC,
production security, tracker promotion or release claim follows from this suite.
