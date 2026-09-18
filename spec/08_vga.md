# P08B VGA / VRAM Specification

> **Status:** Current active contract. English is canonical; the Korean companion [`kor/08_vga.ko.md`](kor/08_vga.ko.md) is semantically aligned.
>
> **Reviewed source anchor:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. This is accepted functional scope, not a release claim.

## 1. Status and scope

The active display peripheral is `AHB_VRAM_DUAL_BUFFER`, instantiated by `AMBA_SoC_TOP`. It provides a 640 x 480, 1-bpp double-buffered framebuffer, VGA timing, swap control, and a hardware clear engine.

The frozen local source scope for `VGA-001` through `VGA-006` is owner accepted and functionally verified. It is not Clean Baseline release closure: static CDC, full STA closure, board-warning disposition, reset-window analysis, and programmer identity remain separately open. `VGA-007` (dormant APB source disposition) is also open.

The public evidence package is [`reports/evidence/vga-hwclear/`](../reports/evidence/vga-hwclear/summary.md) and the engineering narrative is [CS-009](../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md).

## 2. Current active contract

### 2.1 Architecture and storage

`AHB_VRAM_DUAL_BUFFER` is an AHB-side peripheral, not the dormant `APB_VGA_Top`. Each framebuffer bank contains 9,600 32-bit words (38,400 bytes), representing 640 x 480 1-bpp pixels. The VGA pixel reader owns the displayed bank; accepted CPU writes and an active cleaner use the other bank.

### 2.2 Canonical address and access policy

| Address | Access | Contract |
|---|---|---|
| `0x2000_0000`–`0x2000_95FF` | aligned 32-bit write only | Current writable back buffer. |
| `0x2001_0000` | read / W1C bit 0 | `VRAM_STATUS`. |
| `0x2001_0004` | write | `VRAM_CONTROL` command. |
| All other local addresses, framebuffer reads, and subword/misaligned framebuffer accesses | ERROR | No data write and no command side effect. |

Only the table above is architectural. Wider fabric selection or historical local aliases are not part of the software contract.

### 2.3 AHB response and operation acceptance

The peripheral completes an accepted request with the documented ready/response sequence. A request that cannot be accepted—for example, because the target bank is busy or not writable—gets the two-cycle AHB ERROR response. Rejected requests must not assert framebuffer write enable or start/alter an operation.

At most one cleaner operation is outstanding. Clear start latches its target bank; subsequent display-bank changes cannot redirect that operation. A swap becomes visible only at the defined VSync boundary. Software shall wait for the associated status before relying on the new ownership.

### 2.4 Control and status

`VRAM_CONTROL` issues clear, swap, and combined commands as implemented by the active RTL. `VRAM_STATUS` reports live `BUSY`/`READY` state and a sticky completion event. Bit 0 is W1C: writing one acknowledges the event; writing zero does not clear it. Set-versus-clear priority and reset behavior are defined by the RTL/DV matrix and shall remain deterministic.

## 3. Interface, register, and timing details

The framebuffer word index spans `0..9599`; a successful hardware-clear operation writes exactly those 9,600 words in its latched target bank. The pixel mapping is linear 1-bpp raster order. The RGB output is monochrome black or white from the selected display bank under the VGA timing generator.

The CPU and VGA sides are in distinct clock domains. The functional contract above does not claim static CDC closure. Similarly, the timing contract describes intended pixel/display behavior and does not claim full post-route STA closure.

## 4. Invariants and error behavior

- A canonical framebuffer write modifies only the writable bank.
- A rejected, unsupported, read, subword, or misaligned framebuffer request has no write side effect.
- A cleaner never changes banks after its target is accepted.
- A displayed image changes bank only at the defined swap boundary.
- Completion remains observable until W1C acknowledgement; BUSY and READY are live, not inferred from an IDLE-high level.
- The exact clear count is a RTL/DV property. A board photograph can corroborate a visible black/white transition but cannot establish all 9,600 individual writes.

## 5. Acceptance criteria

| ID | Criterion | Evidence class |
|---|---|---|
| `VGA-AC-01` | Canonical aperture and invalid-gap behavior are deterministic. | Directed RTL/DV |
| `VGA-AC-02` | Unsupported or unaccepted traffic returns ERROR without side effect. | Directed RTL/DV |
| `VGA-AC-03` | Busy ownership, swap, and clear-target latching are atomic. | Directed RTL/DV |
| `VGA-AC-04` | Completion is sticky W1C with deterministic ordering. | Directed RTL/DV and firmware execution |
| `VGA-AC-05` | Each accepted clear writes exactly 9,600 words to its latched bank. | Directed RTL/DV |
| `VGA-AC-06` | Hardware exhibits the expected visible clear/swap transition. | Board photographs |
| `VGA-AC-07` | Combined and no-write swap sequences show the expected visible result. | Board photographs |
| `VGA-AC-08` | The exercised image was accepted by the board operator. | Board observation |

## 6. Current requirement status

| Requirement | Status | Basis |
|---|---|---|
| `VGA-001` | VERIFIED | Canonical decode and boundary directed tests. |
| `VGA-002` | VERIFIED | Write-only/error-path DV, source review, and firmware build. |
| `VGA-003` | VERIFIED | Contention/no-side-effect and CPU fault-path DV. |
| `VGA-004` | VERIFIED | Clear-only, combined, overlap, and target-latch DV. |
| `VGA-005` | VERIFIED | W1C ordering/collision DV and firmware execution path. |
| `VGA-006` | VERIFIED functional scope | Exact-count RTL/DV plus board-visible smoke evidence; not STA/CDC closure. |
| `VGA-007` | OPEN | Dormant `APB_VGA_Top` disposition is deferred. |

Run-specific source digests, tool outcomes, photo hashes, and limitations are in the [evidence result](../reports/evidence/vga-hwclear/result.json), not in this normative contract.

## 7. Approved target and deferred work

The approved target is the frozen source behavior above. The following remain outside this acceptance:

| ID | Status | Reason |
|---|---|---|
| `CDC-001` | NOT_RUN / unresolved | No static CDC sign-off. |
| `STA-001` | IN_PROGRESS | Internal STA is SCOPED_PASS only, not full closure. |
| `STA-002` | BLOCKED | Board/I/O electrical timing ownership is unresolved. |
| VGA/ADC warnings | OPEN | Two warnings require explicit disposition. |
| Reset window | known risk | Further reset-domain analysis is required. |
| Programmer identity | unavailable | No programmer-identity evidence was captured. |

## 8. Traceability

| Contract area | Source and evidence |
|---|---|
| Active peripheral and cleaner | `rtl/video/vram/AHB_VRAM_DUAL_BUFFER.v`, `rtl/video/vram/HW_Cleaner.v` |
| Firmware interface | `firmware/include/vram.h`, `firmware/drivers/vram.c` |
| Directed verification | `verification/directed/vga/` |
| Requirement tracker | [`baseline_cleanup.md`](baseline_cleanup.md) |
| Board evidence | [`reports/evidence/vga-hwclear/`](../reports/evidence/vga-hwclear/summary.md) |
| Engineering case | [CS-009](../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md) |

## Appendix A. Historic pre-cleanup notes

Earlier baselines described permissive local aliases, fixed-success response behavior, immediate or live-bank assumptions, and level-style completion interpretations. Those notes are historical context only and must not be used as the current contract.
