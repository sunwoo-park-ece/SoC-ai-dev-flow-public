#!/usr/bin/env python3
"""Regenerate a Quartus 19.1 ALTPLL with its locked output enabled.

The source variation is copied to an output directory. qmegawiz creates the
configuration XML, this helper changes only the lock-output controls, and
qmegawiz regenerates all HDL/collateral. The input variation is never edited.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


CLOCK_PARAMETERS = (
    "clk0_divide_by",
    "clk0_duty_cycle",
    "clk0_multiply_by",
    "clk0_phase_shift",
    "inclk0_input_frequency",
    "intended_device_family",
    "operation_mode",
    "pll_type",
)


def run(command: list[str], cwd: Path, log: Path) -> None:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    log.write_text(completed.stdout)
    if completed.returncode:
        raise SystemExit(f"command failed ({completed.returncode}); see {log}")


def parameters(path: Path) -> dict[str, str]:
    text = path.read_text(errors="replace")
    result: dict[str, str] = {}
    for name in CLOCK_PARAMETERS:
        match = re.search(
            rf"altpll_component\.{re.escape(name)}\s*=\s*([^,;]+)", text
        )
        if not match:
            raise SystemExit(f"missing clock parameter {name} in {path}")
        result[name] = match.group(1).strip()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-v", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--qmegawiz", required=True, type=Path)
    args = parser.parse_args()

    source_v = args.source_v.resolve()
    output_dir = args.output_dir.resolve()
    qmegawiz = args.qmegawiz.resolve()
    if not source_v.is_file() or not qmegawiz.is_file():
        raise SystemExit("source variation or qmegawiz executable not found")
    if output_dir == source_v.parent or source_v.parent in output_dir.parents:
        raise SystemExit("output directory must not be the private source directory")

    output_dir.mkdir(parents=True, exist_ok=False)
    staged_v = output_dir / "vga_pll.v"
    shutil.copy2(source_v, staged_v)

    run(
        [str(qmegawiz), "-silent", "-xmlout", staged_v.name],
        output_dir,
        output_dir / "qmegawiz_xmlout.log",
    )
    xml_path = output_dir / "vga_pll.xml"
    # qmegawiz 19.1's XML parser is whitespace-sensitive. Preserve its output
    # byte structure and make only the three wizard-state edits corresponding
    # to the GUI's "Create 'locked' output" option.
    xml_text = xml_path.read_text()
    edits = (
        (
            '<PRIVATE NAME="LOCKED_OUTPUT_CHECK" VALUE="0"/>',
            '<PRIVATE NAME="LOCKED_OUTPUT_CHECK" VALUE="1"/>',
        ),
        (
            '<CONSTANT NAME="PORT_LOCKED" VALUE="PORT_UNUSED"/>',
            '<CONSTANT NAME="PORT_LOCKED" VALUE="PORT_USED"/>',
        ),
        (
            '<USED_PORT DIRECTION="INPUT_CLK_EXT" TYPE="GND" LABEL="inclk0">',
            '<USED_PORT DIRECTION="OUTPUT" TYPE="WIRE" LABEL="locked">\n'
            '<PORT NAME="locked" SIZE="0" SIZEBASE="0" WIDTH="0" WIDTHBASE="0"/>\n'
            '</USED_PORT>\n'
            '<USED_PORT DIRECTION="INPUT_CLK_EXT" TYPE="GND" LABEL="inclk0">',
        ),
    )
    for old, new in edits:
        if xml_text.count(old) != 1:
            raise SystemExit(f"expected exactly one qmegawiz XML token: {old}")
        xml_text = xml_text.replace(old, new)
    xml_path.write_text(xml_text)

    original_parameters = parameters(source_v)
    run(
        [str(qmegawiz), "-silent", "-xmlin", xml_path.name],
        output_dir,
        output_dir / "qmegawiz_xmlin.log",
    )
    regenerated_parameters = parameters(staged_v)
    if regenerated_parameters != original_parameters:
        raise SystemExit("regenerated VGA PLL clock parameters changed unexpectedly")

    generated_text = staged_v.read_text(errors="replace")
    required = ("output\t  locked", ".locked (", 'port_locked = "PORT_USED"')
    if not all(token in generated_text for token in required):
        raise SystemExit("regenerated variation does not expose a used locked output")

    summary = {
        "generator": str(qmegawiz),
        "input": str(source_v),
        "output_directory": str(output_dir),
        "clock_parameters_before": original_parameters,
        "clock_parameters_after": regenerated_parameters,
        "locked_output": "PORT_USED",
        "generated_files": sorted(path.name for path in output_dir.iterdir() if path.is_file()),
    }
    (output_dir / "regeneration_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n"
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
