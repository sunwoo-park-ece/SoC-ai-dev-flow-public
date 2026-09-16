#!/usr/bin/env python3
"""Bind public RTL to private Quartus IP in a disposable run directory."""

import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


IP_QIPS = {
    "IMEM": "IMEM.qip",
    "memory": "memory.qip",
    "VRAM": "VRAM.qip",
    "vga_pll": "vga_pll.qip",
    "adc_qsys": "adc_qsys/synthesis/adc_qsys.qip",
}


def tcl_path(path: Path) -> str:
    value = str(path.resolve())
    if any(character in value for character in "\n\r"):
        raise SystemExit("unsupported path character in build binding")
    # Quartus source-file assignments treat braces literally, unlike Tcl source.
    for character in ("\\", '"', "$", "[", "]"):
        value = value.replace(character, "\\" + character)
    return '"' + value + '"'


def write_mif(path: Path, depth: int, default_word: int) -> None:
    with path.open("w", encoding="ascii") as stream:
        stream.write(f"DEPTH = {depth};\nWIDTH = 32;\n")
        stream.write("ADDRESS_RADIX = DEC;\nDATA_RADIX = HEX;\nCONTENT BEGIN\n")
        for address in range(depth):
            stream.write(f"{address} : {default_word:08X};\n")
        stream.write("END;\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--generate-only", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.run_id) or args.run_id in (".", ".."):
        parser.error("run-id must be a simple directory name")

    root = Path(__file__).resolve().parents[2]
    run_root_text = os.environ.get("RUN_ROOT")
    vendor_root_text = os.environ.get("VENDOR_ROOT")
    if not run_root_text or not vendor_root_text:
        parser.error("RUN_ROOT and VENDOR_ROOT are required local environment variables")
    run_root = Path(run_root_text).resolve()
    vendor_root = Path(vendor_root_text).resolve()
    if run_root == root or root in run_root.parents:
        parser.error("RUN_ROOT must remain outside the public checkout")
    if run_root == vendor_root or vendor_root in run_root.parents:
        parser.error("RUN_ROOT must remain outside the private active vault")
    ip_root = vendor_root / "fpga/quartus/ip"
    qips = {name: ip_root / relative for name, relative in IP_QIPS.items()}
    missing = [str(path) for path in qips.values() if not path.is_file()]
    if missing:
        parser.error("missing private IP bindings: " + ", ".join(missing))

    profile = json.loads((root / "fpga/quartus/build_profiles.json").read_text())
    source_groups = profile["source_groups"]
    project = run_root / "de10_lite/quartus" / args.run_id / "project"
    memory_dir = project.parent / "mem"
    project.mkdir(parents=True, exist_ok=True)
    memory_dir.mkdir(parents=True, exist_ok=True)
    for name, depth, word in (("IMEM", 4096, 0x00000013), ("DMEM", 8192, 0)):
        write_mif(memory_dir / f"{name}.mif", depth, word)

    sources = []
    for group in ("common_verilog", "aes_vhdl_dependency_order"):
        for pattern in source_groups[group]:
            matches = sorted(root.glob(pattern))
            if not matches:
                parser.error(f"no public source matches {pattern}")
            sources.extend(path for path in matches if path.is_file())
    sources = list(dict.fromkeys(sources))
    qsf = [
        'set_global_assignment -name FAMILY "MAX 10"',
        f'set_global_assignment -name DEVICE {profile["target"]["device"]}',
        f'set_global_assignment -name TOP_LEVEL_ENTITY {profile["top"]}',
        'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files',
        'set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"',
        'set_global_assignment -name NUM_PARALLEL_PROCESSORS 4',
        'set_global_assignment -name MIF_FILE ../mem/IMEM.mif',
        'set_global_assignment -name MIF_FILE ../mem/DMEM.mif',
        f'set_global_assignment -name SDC_FILE {tcl_path(root / "fpga/quartus/constraints/de10_lite.sdc")}',
    ]
    for path in sorted((root / "rtl/core/v").rglob("*")):
        if path.is_dir():
            qsf.append(f'set_global_assignment -name SEARCH_PATH {tcl_path(path)}')
    for source in sources:
        kind = "VHDL_FILE" if source.suffix == ".vhd" else "VERILOG_FILE"
        qsf.append(f'set_global_assignment -name {kind} {tcl_path(source)}')
    for qip in qips.values():
        qsf.append(f'set_global_assignment -name QIP_FILE {tcl_path(qip)}')
    placement_file = os.environ.get("PRIVATE_BINDINGS_JSON")
    placements = {}
    if placement_file:
        placement_path = Path(placement_file).resolve()
        if placement_path == root or root in placement_path.parents:
            parser.error("PRIVATE_BINDINGS_JSON must remain outside the public checkout")
        placements = json.loads(placement_path.read_text()).get("pll_placements", {})
        for node, location in placements.items():
            if not re.fullmatch(r"PLL_[0-9]+", location) or any(c in node for c in '"\\$[]\n\r'):
                parser.error("invalid local PLL binding")
            qsf.append(f'set_location_assignment {location} -to "{node}"')
    qsf.append(f'source {tcl_path(root / "fpga/quartus/constraints/de10_lite_pins.tcl")}')
    (project / "AMBA_SoC_TOP.qsf").write_text("\n".join(qsf) + "\n")
    (project / "AMBA_SoC_TOP.qpf").write_text('PROJECT_REVISION = "AMBA_SoC_TOP"\n')
    (project.parent / "binding_manifest.json").write_text(json.dumps({
        "profile": "PRIVATE_QUARTUS", "public_source_root": str(root),
        "private_ip_root": str(ip_root), "public_source_count": len(sources),
        "private_ip_names": list(qips), "firmware": "NOP/zero compile-only defaults",
        "local_pll_placements": placements,
        "project": str(project),
    }, indent=2) + "\n")
    print(f"Generated {project} with {len(sources)} public sources and {len(qips)} private IP bindings")
    if args.generate_only:
        return 0
    quartus = shutil.which("quartus_sh")
    if not quartus:
        parser.error("quartus_sh was not found on PATH")
    with (project.parent / "quartus_compile.log").open("w") as stream:
        result = subprocess.run([quartus, "--flow", "compile", "AMBA_SoC_TOP"],
                                cwd=project, stdout=stream, stderr=subprocess.STDOUT,
                                check=False)
    print(f"Quartus exit={result.returncode}; log={project.parent / 'quartus_compile.log'}")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
