# P08B VGA / VRAM Specification

> **Status:** Current active contract for the frozen P08B functional scope. English is canonical; [`kor/08_vga.ko.md`](kor/08_vga.ko.md) is semantically synchronized.
>
> **Reviewed source anchor:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. This is functional-scope acceptance, not a release, CDC, or full timing-sign-off claim.

## 1. Status and Scope

The active display peripheral is the AHB-side `AHB_VRAM_DUAL_BUFFER` instance in `AMBA_SoC_TOP`; dormant `APB_VGA_Top` is not an active interface. The scope comprises canonical AHB access, double-buffer ownership, hardware clear, VGA scanout, and the firmware-visible status/control contract.

`VGA-001..006` are VERIFIED for the frozen functional scope and owner accepted. `VGA-007` is OPEN. Static CDC (`CDC-001`), full STA (`STA-001`), external I/O timing (`STA-002`), VGA/ADC warning disposition, the pre-`mtvec` reset window, and independent programmer/JTAG image-to-board binding are outside this verdict.

The engineering narrative is [CS-009](../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md); execution evidence is [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md).

## 2. Current Active Contract

### 2.1 Architecture, clocks, and ownership

`CLOCK_50` feeds `vga_pll`; its nominal pixel output is `pclk_25` while the AHB control/write side uses 50 MHz `HCLK`. `VGA_SyncGen`, prefetch, and the read sides of both mixed-width RAMs are in the pixel domain. CPU writes, control/status state, and `HW_Cleaner` are in HCLK. The two domains exchange request/acknowledge toggles; a live asynchronous bank select is not the ownership interface.

```text
CPU / AHB (HCLK)                         Pixel domain (pclk_25)
  | canonical writes, status/control          | timing + prefetch
  v                                           v
AHB_VRAM_DUAL_BUFFER --request toggle--> pending swap at frame wrap
  |  \                                      /        |
  |   +-- HW_Cleaner / write mux ----------+         +--> VGA RGB/HS/VS
  |                 |
  +--> VRAM0 / VRAM1 dual-clock storage <--- selected front-bank read port
```

`front_bank_p` is the display selection and `front_bank_h` is the synchronized HCLK ownership view. Reset/recovery establishes VRAM0 front and VRAM1 back. CPU writes always target the HCLK back bank; the cleaner uses a target bank latched when its clear begins.

### 2.2 Geometry, storage, and pixels

The visible framebuffer is 640 x 480 x 1 bpp = 307,200 bits = 38,400 bytes = 9,600 32-bit words. There are 20 words per line. For visible coordinates:

```text
word_index = y * 20 + (x >> 5)       (0 <= x < 640, 0 <= y < 480)
bit_index  = x & 31
```

The leftmost pixel of a 32-pixel word is bit 0; increasing X selects increasing bit positions. A zero bit drives black (`R=G=B=0`), and a one bit drives white (`R=G=B=0xF`) when video is active and display is armed.

Each physical RAM has a 16,384 x 32-bit HCLK write view and a 524,288 x 1-bit pclk read view. Only words 0..9599 / bits 0..307199 are visible architectural storage; the remaining physical capacity is reserved and is not software addressable. Read-side synchronous prefetch is an implementation interface constraint: software must use X/Y or word coordinates, never the prefetch counter.

### 2.3 Operations and bank transitions

Only one operation may be outstanding. A nonzero accepted `VRAM_CONTROL` command starts an operation. A swap request crosses to the pixel domain, commits only at `(h_cnt,v_cnt)=(799,524)` transitioning to `(0,0)`, then returns an acknowledgement to HCLK.

| Accepted command | Before completion | Completion and resulting ownership |
|---|---|---|
| `SWAP` | current front remains displayed until frame wrap | swap at frame wrap; old back becomes front; `OP_DONE` sets after ack |
| `HW_CLEAR` | current front remains displayed | latch current back; write zero to words 0..9599; `OP_DONE` sets after word 9599 commit |
| `SWAP | HW_CLEAR` | current front remains displayed until frame wrap | swap first; latch old front/new back and clear it; `OP_DONE` sets after final clear commit |
| zero command | no operation | accepted as no-op by firmware policy; no state change |

An overlapping framebuffer/control request, a request while domain readiness is absent, or a request rejected at data commit receives ERROR and no operation/write side effect. CPU framebuffer writes are excluded while an operation is busy. No operation may modify the displayed front bank.

### 2.4 Reset, lock loss, and display gating

The pixel reset is released through `reset_release_sync` from `HRESETn & vga_pll_locked`. While the synchronized HCLK lock view is low, `DOMAIN_READY` is low, ownership/recovery state is rebased to VRAM0-front, pending requests are discarded, and an active operation sets `OP_ABORT`. Raw PLL lock also gates every physical VRAM write. A later valid pixel-domain readiness handshake is required before a new command or framebuffer write is accepted.

The first post-reset/recovery output is black because display arming is cleared; a successfully committed swap arms output. Framebuffer memory contents are not an architectural reset-clear guarantee. Firmware needing blank content must render or issue an accepted clear after readiness.

## 3. Interface / Register / Timing Contract

### 3.1 Canonical address and AHB access

| Address or range | Access | Contract |
|---|---|---|
| `0x2000_0000`–`0x2000_95FF` | aligned 32-bit write only | Current back-buffer words 0..9599. |
| `0x2000_9600`–`0x2000_FFFF` | none | Reserved gap. |
| `0x2001_0000` | aligned 32-bit read / W1C write | `VRAM_STATUS`. |
| `0x2001_0004` | aligned 32-bit write only | `VRAM_CONTROL`. |
| all other VGA-local addresses, framebuffer reads, subword/misaligned accesses, and CONTROL reads | ERROR | No physical write, event clear, or operation start. |

The target qualifies address phase with `HSEL && HTRANS[1]`, captures address/control for the following data phase, and uses `HREADY_IN` as the global completion qualifier. A normal supported transaction returns `HRESP=OKAY`, `HREADY=1`. A rejected transaction returns the project two-cycle error: first `HRESP=ERROR,HREADY=0`, then `HRESP=ERROR,HREADY=1`. The held data phase cannot duplicate a commit.

Address acceptance is not physical write completion. For framebuffer/control writes, raw PLL lock, synchronized readiness, and idle ownership are revalidated at the data commit phase. Loss before commit turns the transfer into ERROR with zero physical writes; a write that has already committed with final OKAY is neither rolled back nor repeated. This is a functional atomicity contract, not static CDC/metastability sign-off.

Misaligned CPU instructions take the CPU's pre-bus misalignment path (store cause 6); a direct bus transaction with invalid VGA size/alignment receives the local two-cycle ERROR. A terminal rejected VGA store is a faulting operation, not a firmware-retry result.

### 3.2 Status register: `VRAM_STATUS` (`0x2001_0000`)

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `VSYNC_EVENT` | RO / W1C | Sticky HCLK event on synchronized rising/deassertion edge of active-low `VGA_VS`. |
| 1 | `OP_DONE` | RO / W1C | Sticky completion after swap acknowledgement or final clear-word commit. |
| 2 | `OP_BUSY` | RO | Live one-outstanding-operation state. |
| 3 | `OP_ABORT` | RO / W1C | Sticky lock-loss abort of an active operation. |
| 4 | `DOMAIN_READY` | RO | Pixel/ownership recovery handshake complete. |
| 31:5 | reserved | RO / W1C ignored | Reads zero; writes have no defined effect. |

Writing one clears only bits 0, 1, and 3 respectively; writing zero does not clear them. W1C processing occurs before hardware event update, so a coincident event is set-dominant. Reset clears the sticky events. `OP_BUSY` and `DOMAIN_READY` are live and are not W1C state.

### 3.3 Control register: `VRAM_CONTROL` (`0x2001_0004`)

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `SWAP` | WO command | Request frame-boundary ownership swap. |
| 1 | `HW_CLEAR` | WO command | Request clear as defined in Section 2.3. |
| 31:2 | reserved | WO | Ignored; they do not create an operation. |

The register stores no command state and has no read contract. A command with bits `[1:0]==0` creates no operation. A nonzero command is accepted only when `DOMAIN_READY=1` and `OP_BUSY=0`; otherwise its transfer is rejected as above.

### 3.4 VGA timing and scanout constraints

| Horizontal segment | Pixels | Vertical segment | Lines |
|---|---:|---|---:|
| visible | 640 | visible | 480 |
| front porch | 16 | front porch | 10 |
| sync pulse | 96 | sync pulse | 2 |
| back porch | 48 | back porch | 33 |
| total | 800 | total | 525 |

`VGA_HS` and `VGA_VS` are active-low. With nominal 25 MHz pclk, the nominal frame rate is about 59.52 Hz. The timing generator itself defines the 800 x 525 counters; the owner swap boundary is the explicit final-count wrap `(799,524)->(0,0)`, independent of the prefetch reset at `(798,524)`. Full generated-clock and board timing closure are not claimed.

## 4. Invariants and Error Behavior

| Cause | Required response | Required absence of side effect |
|---|---|---|
| canonical, ready, idle framebuffer write | one final OKAY commit to HCLK back bank | no front-bank write or duplicate under held `HREADY_IN` |
| unsupported address/direction/size/alignment | two-cycle ERROR | no VRAM write, status mutation, or operation |
| busy or not-ready framebuffer/control request | two-cycle ERROR | no cleaner target change, request toggle, or CPU write |
| PLL loss before data commit | two-cycle ERROR | no physical write for that transfer |
| PLL loss during active operation | abort/recovery; `OP_ABORT` sticky | no continued physical clear write after lock loss |

The following MUST always hold:

- Only canonical aligned word framebuffer writes may change visible framebuffer storage.
- A clear target is immutable after clear starts and clear writes exactly one zero word per permitted HCLK edge for addresses 0..9599.
- Swap is visible only at the defined pixel frame wrap; a combined clear never targets its displayed new front.
- Sticky events remain observable until their own W1C acknowledgement; unrelated W1C bits do not clear them.
- A final OKAY framebuffer/control write corresponds to exactly one physical commit; a pre-commit ERROR corresponds to zero.
- Static CDC, full STA, physical timing, and every displayed pixel value are not inferred from a protocol simulation or a photograph.

## 5. Acceptance Criteria

| ID | Stimulus and assertion | Pass condition |
|---|---|---|
| `VGA-AC-01` | Exercise canonical framebuffer/status/control accesses, gap/alias/read/subword/invalid accesses. | Canonical requests have documented result; each invalid request has two-cycle ERROR and no side effect. |
| `VGA-AC-02` | Hold data phase, vary ready/lock boundary, and issue consecutive requests. | Exactly-once physical commit for final OKAY; no commit for ERROR or held phase; no false OKAY after pre-commit loss. |
| `VGA-AC-03` | Exercise swap-only, clear-only, combined, overlap, and repeated commands. | Frame-wrap swap, latched clear target, 0..9599 range, exactly 9,600 clear writes, and rejected overlaps are observed. |
| `VGA-AC-04` | Set, clear, repeat, and coincide each W1C event with hardware event generation. | VSYNC/DONE/ABORT are independent sticky W1C events with set-dominant collision; BUSY/READY are live. |
| `VGA-AC-05` | Inject lock loss idle, pending swap, active clear, combined clear, acknowledgement window, and reset-adjacent states. | Writes stop, active operation aborts once, recovery returns safe ownership/black gating, and a new operation is possible after ready. |
| `VGA-AC-06` | Observe standalone hardware-clear/swap screen sequence on board. | Bounded photographs show the expected visible black/restored transition only. |
| `VGA-AC-07` | Observe combined and no-write-swap board sequence. | Bounded photographs show expected white/black/restored visible states only. |
| `VGA-AC-08` | Board operator repeats the smoke sequence. | Operator reports normal operation through the stated bounded cycle count. |

Criteria are stable verification rules. Run IDs, timestamps, hashes, and raw logs are retained only in evidence.

## 6. Current Requirement Status

| Requirement | Status | Compact basis |
|---|---|---|
| `VGA-001` | VERIFIED functional scope | Canonical decode/boundary/error directed verification. |
| `VGA-002` | VERIFIED functional scope | Aligned write-only policy, no read/subword side effect, and firmware interface review. |
| `VGA-003` | VERIFIED functional scope | Ownership, contention, error/no-side-effect, and CPU-fault verification. |
| `VGA-004` | VERIFIED functional scope | Target latch, clear-only, combined, overlap, and range/count verification. |
| `VGA-005` | VERIFIED functional scope | Sticky W1C ordering/collision and firmware control path. |
| `VGA-006` | VERIFIED functional scope | Same-RTL exact-count DV plus bounded board-visible smoke evidence. |
| `VGA-007` | OPEN | Dormant APB VGA source disposition. |

Historical evidence is intentionally compact: `P08B-VGA-EV-01` covers `VGA-AC-01..08` with DV PASS for AC-01..05, photo observation for AC-06..07, and user attestation for AC-08. See [summary](../reports/evidence/vga-hwclear/summary.md) and [result](../reports/evidence/vga-hwclear/result.json).

## 7. Approved Target / Deferred Work

| Item | Status | Boundary |
|---|---|---|
| `CDC-001` | NOT_RUN / unresolved | Functional request/ack testing is not static CDC sign-off. |
| `STA-001` | IN_PROGRESS | Internal STA is SCOPED_PASS only, not full closure. |
| `STA-002` | BLOCKED | External I/O/electrical timing has no complete peer/board closure. |
| VGA/ADC warnings | OPEN | Critical proximity warnings require explicit disposition. |
| `RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT` | known risk | Not a verified safe firmware trap interval. |
| Programmer/JTAG binding | unavailable | No independent SOF-to-board binding was captured. |

## 8. Traceability

- Tracker: [`baseline_cleanup.md`](baseline_cleanup.md) and [Korean tracker](kor/baseline_cleanup.ko.md)
- Active RTL: [`pre_fetch_AHB_VRAM_DUAL_BUFFER.v`](../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v), [`HW_Cleaner.v`](../rtl/video/vram/HW_Cleaner.v), [`VGA_SyncGen.v`](../rtl/video/vga/VGA_SyncGen.v)
- Firmware: [`vram.h`](../firmware/include/vram.h), [`vram.c`](../firmware/drivers/vram.c)
- Directed verification: [`tb_p08b_vga.sv`](../verification/directed/vga/tb_p08b_vga.sv), [`tb_p08b_vga_state_matrix.sv`](../verification/directed/vga/tb_p08b_vga_state_matrix.sv), [`tb_p08b_vga_atomicity_matrix.sv`](../verification/directed/vga/tb_p08b_vga_atomicity_matrix.sv), [`tb_p08b_vga_cpu_fault.sv`](../verification/directed/vga/tb_p08b_vga_cpu_fault.sv)
- Case and evidence: [CS-009](../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md), [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md)

## Appendix A. Historical / Pre-cleanup Notes

Earlier baseline text described broad local aliases, fixed OKAY/ready behavior, immediate HCLK swap, a live clear-bank selection, level-style clear completion, and no hardware-clear board evidence. Those descriptions are historical only; they must not be used as the current contract. The retained architecture/geometry/timing facts were reconciled into Sections 2 and 3; engineering alternatives are in CS-009.
