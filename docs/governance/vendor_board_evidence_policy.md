# Vendor Tooling and Physical Board Evidence Policy

> **Scope:** FPGA compilation flows (Quartus, Vivado), Static Timing Analysis (STA), and physical hardware bringup.  
> **Status:** Active Project Governance.  
> **Canonical Language:** English. Korean companion files (`*.ko.md`) maintain semantic equivalence.

---

## 1. Core Operating Boundary

Full vendor tool compilation (synthesis, place-and-route, bitstream assembly) and physical board/JTAG operations are **owner-operated by default unless explicitly delegated by the User**.

```text
       AI Agent (Codex / Antigravity)                    Human Owner / User
      --------------------------------                 ----------------------
1. Pre-build open regressions & RTL freeze  --->
2. Generate verified CLI runbook snippet    --->   3. Execute vendor compilation (Quartus/Vivado)
                                            <---   4. Return completion confirmation & run directory
5. Parse logs, extract timing/resource data
6. Prepare board test procedure & checklist --->   7. Program FPGA via JTAG & verify hardware
                                            <---   8. Return physical observations & measurements
9. Author unified engineering report
```

---

## 2. Vendor Execution Runbook Contract

When requested, agents generate exact, copy-pasteable CLI commands for the User to execute. Every vendor execution script or CLI snippet must enforce the following contract:

1. **Unique Run ID:** Incorporate task, feature, date, and sequence identifier (e.g., `p12_vga_cdc_20261001_01`).
2. **Out-of-Tree Run Root:** Store all intermediate files, project databases, and bitstreams strictly outside repositories under `<workspace>/runs/quartus/<feature>/<run-id>/` (or `<workspace>/runs/vivado/...`). Scripts must enforce an explicit workspace variable and fail fast if unset; fallback to the repository or current working directory is strictly prohibited.
3. **Pipeline Fail-Safe:** Enforce `set -o pipefail` in bash/zsh snippets (or shell-appropriate pipeline failure propagation) to prevent pipe masking.
4. **Explicit Exit Code Capture:** True tool exit codes must be captured and written to `exit_code.txt`.
5. **Simultaneous Logging:** Tee stdout and stderr to a dedicated log file (`wrapper.log` or `quartus_compile.log`).

### Standard CLI Wrapper Snippet Template

```bash
# Enforce pipeline failure propagation (bash/zsh)
set -o pipefail

# Fail fast if WORKSPACE is not explicitly set; never fall back to repository root
: "${WORKSPACE:?ERROR: WORKSPACE environment variable must be set (e.g. export WORKSPACE=/home/swp/soc)}"

RUN_ID="<feature>_$(date +%Y%m%d_%H%M%S)"
RUN_ROOT="${WORKSPACE}/runs/quartus/<feature>/${RUN_ID}"
mkdir -p "$RUN_ROOT"

echo "=== Starting Vendor Build [${RUN_ID}] ==="
# Execute verified build script or flow command
bash scripts/quartus/build_de10_lite.sh "$RUN_ROOT" 2>&1 | tee "$RUN_ROOT/build.log"

rc=${PIPESTATUS[0]}
printf '%s\n' "$rc" > "$RUN_ROOT/exit_code.txt"

if [ "$rc" -eq 0 ]; then
  echo "=== Vendor Build Completed Successfully [exit code 0] ==="
else
  echo "=== Vendor Build FAILED [exit code $rc] ==="
fi
exit "$rc"
```

---

## 3. Post-Build Metrics Extraction

Following build completion by the User, the agent must parse raw compilation reports and extract the following metrics:

### Required Resource and Utilization Metrics
- Logic element (LE) / LUT utilization count and percentage.
- Dedicated register (FF) count and percentage.
- Embedded memory bits / Block RAM (M9K / BRAM) utilization.
- DSP block utilization.
- PLL / Clock control block utilization.

### Required Timing and Clock Domain Metrics
- Target clock frequencies vs achieved Fmax per clock domain.
- Worst-Case Setup Slack (Worst Negative Slack, WNS).
- Worst-Case Hold Slack (WHS).
- Total Negative Slack (TNS) across each clock domain.
- Critical path endpoint, clock source, and data path breakdown.
- New timing bottlenecks or failing clock-domain crossings (CDC).
- Comparison deltas against previous milestone or Clean Baseline.

---

## 4. Static Timing Analysis (STA) and Claim Boundaries

To prevent overclaiming, agents must adhere to strict hierarchical claim boundaries:

```text
Positive Internal Slack  !=  External I/O Timing Closure
Successful Compilation   !=  Static CDC Signoff
Simulation PASS          !=  Physical Board Signoff
```

1. **Internal Slack vs I/O Timing:** A zero-TNS internal core result does not prove that external peripheral pins (e.g., VGA DAC, SDRAM, ADC, GPIO) satisfy setup, hold, and skew constraints at physical board interfaces.
2. **CDC Verification:** Vendor synthesis tools do not automatically prove clock-domain crossing correctness. Asynchronous domain crossings require architecture-appropriate structural verification (such as multi-stage synchronizers or handshake protocols) and analytically justified timing constraints (e.g., false path or max delay where appropriate), rather than an unjustified blanket false-path assignment.
3. **Disclose Limitations:** If I/O timing or CDC has not been closed, reports must explicitly state: `INTERNAL_TIMING_MET | IO_TIMING_UNPROVEN`.

---

## 5. Physical Board and Hardware Operations

### Division of Responsibilities
- **User Actions:** Physical board cabling, power sequencing, USB-Blaster / JTAG cable attachment, FPGA configuration downloading (`.sof` programming), switch/button manipulation, oscilloscope and logic analyzer probing.
- **Agent Actions:** Locating exact bitstream paths, authoring step-by-step test procedures, defining expected visual/electrical outcomes, generating pass/fail checklists, and recording reported facts.

### Board Acceptance Checklist Requirements
Every board verification session must provide a structured checklist covering:
- **Bitstream Integrity:** Exact path and SHA-256 hash of the programmed file.
- **Hardware Configuration:** Target board model (e.g., DE10-Lite), switch positions, jumper settings, and peripheral cabling.
- **Expected Stimulus-Response:** Step-by-step physical actions (e.g., "Toggle SW[0]") and expected observable responses (e.g., "HEX0 displays 'A', LEDR[0] illuminates").
- **Observation Capture:** Instructions for capturing multimeter readings, photos, or logic analyzer captures.
- **Anomalies and Gaps:** Explicit recording of visual glitches, temperature sensitivities, or power-on race conditions.

---

## 6. Storage and Licensing Firewalls

- **Local Storage Only:** Vendor project databases (`db/`, `incremental_db/`), generated IP cores, bitstreams (`.sof`, `.pof`, `.bit`), and raw timing netlists must remain strictly in local storage (`vendor-projects-private/` and `runs/`).
- **Prohibited from GitHub:** Never commit vendor-generated files, licensed IP collateral, or bitstreams to public OR private GitHub repositories.
- **Public Collateral:** The public repository retains only portable SDC constraint files, open Tcl synthesis scripts, public pin assignments, and `ip_manifest.yml` records specifying how to regenerate IP locally.
