# P13-08 D08 manual simulation

D08 integrated actual-core overflow and simultaneous/late success remain **NOT_PROVEN**. This run has three distinct lanes. The production APB wrapper plus 14 actual VHDL units runs independent AESGCM controls with legal traffic. The production `aes_icb` entity alone can be held active through its public ports for the full counter duration. The isolated P13-02 callback fixture tests wrapper priority and checker sensitivity in a separate library.

| Stimulus | Epoch result | Claim |
|---|---|---|
| Legal APB one-block START, including all-ones IV | START reloads low counter to 1; upper IV cannot preload the counter; normal completion stops it | A longer simulation after a normal terminal event cannot produce integrated overflow |
| Reset, zeroize, repeated transactions or rejected BUSY writes | Reset/restart breaks the epoch; rejected BUSY writes do not extend the packet | No known legal stimulus reliably holds the integrated epoch open; universal liveness is unproved |
| Standalone real ICB port START with no STOP, reset released and ECB not busy | 4,294,967,294 increments to all ones plus one registered overflow edge | Real ICB counter boundary only, no integrated late-success or FW release claim |

Prerequisites used in smoke: GHDL 1.0.0 (VHDL-2008 and Synopsys IEEE compatibility), ModelSim 10.5b, Python 3 with `cryptography`, Git, and the canonical Public worktree. ModelSim's `vlib`, `vcom`, `vlog`, and `vsim` must be executable.

```bash
cd /home/swp/soc/worktrees/p13-aes-public
export MODELSIM_BIN=/home/swp/intelFPGA/19.1/modelsim_ase/bin
export RUN_ROOT="/home/swp/soc/runs/p13_aes_phase08/P13-08-D08-SMOKE-$(date -u +%Y%m%dT%H%M%S%N)"
python3 -B scripts/wsl/p13_08_d08_run.py smoke
```

Owner long mode, after reviewing smoke:

```bash
cd /home/swp/soc/worktrees/p13-aes-public
export MODELSIM_BIN=/home/swp/intelFPGA/19.1/modelsim_ase/bin
export RUN_ROOT="/home/swp/soc/runs/p13_aes_phase08/P13-08-D08-OWNER-$(date -u +%Y%m%dT%H%M%S%N)"
D08_TIMEOUT_SECONDS=86400 python3 -B scripts/wsl/p13_08_d08_run.py owner-long
```

The runner compiles fresh libraries, runs the wrapper and isolated controls first, and then runs the standalone ICB to the natural edge. Monitor `icb_owner.stdout` for progress every 2^24 edges. The simulated duration is about 85.9 seconds at 50 MHz; real runtime depends on simulator and host. Increase the positive wall-clock budget if needed. Deterministic stimuli have no random seed. Checkpoint resume is unsupported; restart into a fresh directory and preserve interrupted logs. No long-run waveform is generated.

Smoke reports standalone NOT_RUN and integrated D08_NOT_PROVEN. Long mode can report OVERFLOW_REACHED_STANDALONE_ONLY; this is not integrated PASS_ACTUAL_CORE. Timeout is INCONCLUSIVE_TIMEOUT with exit 124. An incorrect assertion, binding or unexpected process exit yields BLOCK. The integrated criterion would require actual wrapper/core overflow coinciding with success and checked terminal priority, no late revival and trusted output suppression. This procedure supplies no legal way to synthesize that event.

Verify artifact integrity and attach the run ID, source_identity.json, result.json, manifest hash and true exits to the task for review. Keep raw artifacts local.

```bash
python3 - "$RUN_ROOT" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = root / 'manifest.json'
for name, expected in json.loads(manifest.read_text()).items():
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit('mismatch: ' + name)
print(hashlib.sha256(manifest.read_bytes()).hexdigest())
print((root / 'result.json').read_text())
PY
```
