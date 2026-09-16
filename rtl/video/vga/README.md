# VGA Publication Boundary

The VGA controllers, framebuffer management, HUD, object renderer and drawing
logic in this tree are project-authored. The historical `VGA_SyncGen` source
had no sufficiently established redistribution provenance and is classified
`REPLACE`; it is not included in the public candidate. The current
`VGA_SyncGen.v` is a spec-driven project-owned replacement for 640×480 timing.

`vga_pll` and `VRAM` remain private vendor-generated IP for Quartus. Portable
simulation equivalents are under `verification/models/clock/` and
`verification/models/memory/`.
