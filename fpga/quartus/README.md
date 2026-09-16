# Public Quartus Boundary

This directory records portable design intent for the DE10-Lite target. It is
not a complete Quartus project and intentionally contains no QPF/QSF snapshot,
generated IP HDL, programming file, compiler database, or raw vendor report.

The private full-build contract is:

```text
PUBLIC_REPO + PRIVATE_VENDOR_PROJECT + LOCAL_ENV + RUN_DIR
    = private full FPGA build
```

The open-source verification contract is:

```text
PUBLIC_REPO + project-authored behavioral models
    = open lint / simulation / elaboration
```

`build_profiles.json` is the executable source list. `source_manifest.yml` is
its human-readable companion. `constraints/` holds board pin and timing intent.
Portable simulation models are under `verification/models/`; they are not
Quartus synthesis sources. Local tool and vault paths must be supplied outside
Git using `$VENDOR_ROOT` and `$RUN_ROOT`.

From the public checkout:

```bash
RUN_ROOT=/path/to/runs bash scripts/wsl/open_sim.sh example
RUN_ROOT=/path/to/runs bash scripts/wsl/modelsim_mixed.sh example
RUN_ROOT=/path/to/runs VENDOR_ROOT=/path/to/private/active \
  PRIVATE_BINDINGS_JSON=/path/to/local_pll_bindings.json \
  python3 scripts/wsl/private_quartus.py --run-id example
```

The last command generates a disposable QPF/QSF and compile-only NOP/zero MIFs
under `$RUN_ROOT/de10_lite/quartus/example/`. It references public RTL directly
and five active private QIP bindings, without copying editable RTL into the vault.
The historical G-sensor `spi_pll` remains in the private vault but is no longer
instantiated or bound by the single-PCLK G-sensor build profile.
It does not verify firmware or board behavior. The private MAX 10 build uses
the ERAM configuration mode required by initialized memory. The local-only
`PRIVATE_BINDINGS_JSON` supplies physical PLL placements without publishing
private generated hierarchy. Its JSON object has a `pll_placements` map from
private instance path to `PLL_N` location. This target's ADC block requires a
routable PLL placement; omitting that local binding can cause Fitter failure.
