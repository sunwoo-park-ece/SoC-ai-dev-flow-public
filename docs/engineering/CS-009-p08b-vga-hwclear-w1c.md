# CS-009 — P08B VGA hardware clear and W1C completion

**Status:** VERIFIED functional scope

**Requirements:** `VGA-001` through `VGA-006`
**Reviewed source:** `f28e95df2eafcb939e04ffaca728c44f74c90612`

## Context and decision

The active AHB VGA peripheral needed a single software contract for canonical decode, write-only framebuffer access, busy ownership, bank-safe clear, VSync-visible swap, and completion acknowledgement. The approved design keeps only the canonical framebuffer/status/control apertures, returns a two-cycle AHB ERROR with no side effect for unsupported or unaccepted accesses, latches a clear target, and exposes completion as sticky W1C with live BUSY/READY state.

This rejects two unsafe interpretations: treating broad historical aliases as software API, and treating an IDLE-high level as completion. A clear is issued to one latched non-display bank; a later swap cannot redirect it.

## Alternatives considered

| Alternative | Disposition | Reason |
|---|---|---|
| Preserve permissive aliases or fixed-success behavior | Rejected | Invalid/unaccepted traffic must be visible to software and side-effect free. |
| Let a clear follow the currently selected bank | Rejected | A later swap could redirect an accepted operation. |
| Treat an idle level as completion | Rejected | Completion acknowledgement requires a persistent, unambiguous event. |
| Canonical decode, latched target, and sticky W1C completion | Adopted | Establishes deterministic access, ownership, and acknowledgement semantics. |

## Evidence strategy

Directed RTL/DV establishes protocol and exact data-path properties. The board sequence corroborates only what a photograph can show: visible pattern, black/white, and restored-frame transitions. In particular, **the exact 9,600 writes per clear are established by RTL/DV (`VGA-AC-05`), not by photographs**.

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| Directed VGA RTL/DV | Decode, ERROR/no-side-effect, ownership/latching, W1C ordering, and exactly 9,600 writes to the latched bank | Static CDC or full STA closure |
| Firmware execution path | Software reaches the W1C/control interface | Programmer identity or full release readiness |
| Board photographs | Visible output transition matches the exercised sequence | Per-word clear count, hidden internal handshake, or timing sign-off |

## Board-visible sequence

The original camera files are included unchanged with their SHA-256 values in the [evidence package](../../reports/evidence/vga-hwclear/summary.md). Each image below records the expected visible state, not an internal write-count claim.

| Step | Expected visible result | Photograph |
|---|---|---|
| 1 | Pattern A is visible before the clear exercise. | ![Pattern A](../../reports/evidence/vga-hwclear/board/01-pattern-a.jpg) |
| 2 | Pattern A remains held before the transition. | ![Pattern A held](../../reports/evidence/vga-hwclear/board/02-pattern-a-held.jpg) |
| 3 | Hardware-clear result is visibly black. | ![Hardware-clear black](../../reports/evidence/vga-hwclear/board/03-hwclear-black.jpg) |
| 4 | Pattern A is restored after the selected swap/operation. | ![Pattern restored](../../reports/evidence/vga-hwclear/board/04-pattern-restored.jpg) |
| 5 | Combined-operation setup is displayed. | ![Combined setup](../../reports/evidence/vga-hwclear/board/05-combined-setup.jpg) |
| 6 | Combined operation produces the expected white result. | ![Combined white](../../reports/evidence/vga-hwclear/board/06-combined-white.jpg) |
| 7 | No-write swap produces the expected black result. | ![No-write swap black](../../reports/evidence/vga-hwclear/board/07-no-write-swap-black.jpg) |
| 8 | Final selected content is restored. | ![Final restored](../../reports/evidence/vga-hwclear/board/08-final-restored.jpg) |

## Result and limits

`VGA-001..006` are accepted as a functional scope. The board operator reported normal operation through cycle 5, and the supplied sequence is retained as public visual evidence under explicit approval. This does not claim release closure.

Open work remains: `CDC-001` is unresolved/not run for static sign-off; `STA-001` is in progress; `STA-002` is blocked; two VGA/ADC warnings need disposition; the reset window is a known risk; and programmer identity was not captured. `VGA-007` remains open.

## Traceability

- Current contract: [`spec/08_vga.md`](../../spec/08_vga.md)
- Korean companion: [`spec/kor/08_vga.ko.md`](../../spec/kor/08_vga.ko.md)
- Requirement tracker: [`spec/baseline_cleanup.md`](../../spec/baseline_cleanup.md)
- Evidence summary and machine-readable result: [`reports/evidence/vga-hwclear/`](../../reports/evidence/vga-hwclear/summary.md)
