# Baseline SoC VGA / VRAM Subsystem Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `vga.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `ahb_fabric.md`, `reset_clock.md`.

> **Phase 4A-3A reading rule:** Earlier permissive framebuffer descriptions reconstruct the pre-cleanup baseline. The final framebuffer section records the now-enforced A3 bus-access policy only; firmware API, VGA CDC, and physical/board acceptance remain open.

## 1. Purpose

This document defines the active FPGA baseline VGA / VRAM subsystem. It specifies:

- the active AHB-side display architecture,
- CPU-visible framebuffer and control/status behavior,
- physical front/back-buffer organization,
- 640×480 1-bpp pixel format,
- VGA timing and pixel-clock behavior,
- buffer-swap semantics,
- VSync status synchronization,
- the hardware-clear engine,
- software usage requirements,
- known CDC/protocol limitations,
- baseline cleanup items required before major future interconnect work.

This document describes the **implemented baseline**, including implementation quirks that software shall currently avoid. It does not promote dormant VGA source files or broad address aliases into architectural features.

## 2. Active Architectural Boundary

The active display path is the AHB-side module:

```text
AHB_VRAM_DUAL_BUFFER
```

instantiated directly in `AMBA_SoC_TOP`.

The active path is:

```text
CPU load/store path
        |
        v
   AHB fabric
        |
        v
AHB_VRAM_DUAL_BUFFER
   |            |
   | HCLK       | pclk_25
   |            |
   +--> VRAM0 --+
   +--> VRAM1 --+--> VGA pixel stream
   |
   +--> status / control
   +--> HW_Cleaner
```

The subsystem is **not** an APB peripheral in the active baseline.

`rtl/video/vga/APB_VGA_Top.v` exists as dormant source material but is not instantiated by `AMBA_SoC_TOP`; its presence shall not define the baseline architecture or register map.

## 3. Canonical Address Map

The canonical software-visible VGA region is:

| Address | Size | Function | Baseline access |
|---:|---:|---|---|
| `0x2000_0000` – `0x2000_95FF` | 38,400 B | Current back-buffer framebuffer | **32-bit write only** |
| `0x2000_9600` – `0x2000_FFFF` | — | Reserved | No software access |
| `0x2001_0000` | 4 B | `VRAM_STATUS` | Read; W1C for bit 0 |
| `0x2001_0004` | 4 B | `VRAM_CONTROL` | Write-command register |

The top-level fabric broadly selects all `0x2xxx_xxxx` addresses, while the VGA subsystem decodes only lower address bits. Consequently, physical aliases exist. Those aliases are not architectural addresses.

### 3.1 Important framebuffer-read limitation

The active RTL contains a commented-out back-buffer read-data path. As implemented, `HRDATA` returns framebuffer data for **no framebuffer address**.

A CPU read from the canonical framebuffer window therefore returns zero through the active VGA slave response path rather than the stored framebuffer word.

Accordingly, the baseline framebuffer contract is **write-only from the CPU**. Firmware and verification shall not use framebuffer readback as a correctness mechanism.

## 4. AHB-Side Transfer Contract

The active VGA slave exposes:

```text
HREADY = 1
HRESP  = OKAY
```

for all selected transfers. The VGA target therefore inserts no AHB wait state.

A transfer is treated as valid when:

```text
HSEL == 1
and HTRANS is NONSEQ or SEQ
```

Address/control are latched for the following data phase. Store data is consumed from `HWDATA` in that data phase.

The VGA slave does **not** consume `HSIZE`, `CUSTOM_WRITE_MASK`, or an equivalent byte-enable signal.

Therefore only naturally aligned **32-bit framebuffer writes** are part of the normative baseline contract.

Byte or halfword framebuffer stores shall not be relied on. The current firmware helper `vram_write_byte()` exists, but the active RTL has no byte-enable path and a byte store can overwrite the containing 32-bit framebuffer word with store-aligned data rather than preserve the other bytes. This helper is a cleanup target, not a supported architectural capability.

## 5. Framebuffer Geometry and Pixel Format

The visible image is:

```text
640 pixels × 480 pixels × 1 bit/pixel
= 307,200 bits
= 38,400 bytes
= 9,600 × 32-bit words
```

Each visible row contains:

```text
640 / 32 = 20 words
```

The canonical software word index is:

```text
word_index = y * 20 + (x >> 5)
bit_index  = x & 31
```

for:

```text
0 <= x < 640
0 <= y < 480
```

The validated firmware convention maps the leftmost pixel of each 32-pixel word to the low-order bit and advances toward higher bit positions as X increases. Existing text rendering reverses each 8-bit font row before packing specifically to match this pixel ordering.

Pixel value semantics are:

| Stored bit | VGA output |
|---:|---|
| 0 | black: `R=0, G=0, B=0` |
| 1 | white: `R=0xF, G=0xF, B=0xF` |

The baseline display is therefore monochrome even though the DE10-Lite VGA output exposes 4 bits per RGB channel.

## 6. Physical VRAM Organization

The subsystem instantiates two Intel/Altera mixed-width dual-port RAMs:

```text
VRAM0
VRAM1
```

Each physical buffer is configured as:

```text
Port A: 16,384 × 32-bit, HCLK write side
Port B: 524,288 × 1-bit, pclk_25 read side
```

This is 524,288 bits = 64 KiB of physical storage per buffer.

Only the first 9,600 Port-A words / 307,200 Port-B bits are canonical visible framebuffer storage. The remainder of each physical RAM is not part of the software-visible framebuffer contract.

The dual-clock RAM primitive itself provides the storage crossing between HCLK writes and pixel-clock reads. Higher-level buffer-selection control still contains CDC concerns described later in this document.

## 7. Front / Back Buffer Ownership

`front_buffer_idx` selects the physical front buffer:

| `front_buffer_idx` | VGA front buffer | CPU/HW-clear back buffer |
|---:|---|---|
| 0 | VRAM0 | VRAM1 |
| 1 | VRAM1 | VRAM0 |

Reset sets:

```text
front_buffer_idx = 0
```

so VRAM0 begins as front and VRAM1 as back.

The CPU framebuffer window always targets whichever physical RAM is currently designated as the **back buffer**. Software does not directly address VRAM0 versus VRAM1.

## 8. Buffer Swap

Writing `VRAM_CONTROL.SWAP = 1` toggles `front_buffer_idx`.

The command therefore performs:

```text
old back  -> new front
old front -> new back
```

The bit is a command, not stored state. Writing `0` performs no swap.

The active RTL changes `front_buffer_idx` in the HCLK domain immediately when the control write is committed. It does not implement a pixel-domain frame-boundary handshake.

The intended firmware usage is therefore:

```text
1. render a complete frame into the back buffer
2. wait for the VSync status event
3. issue SWAP
```

This reduces the probability of visible tearing by performing the swap during vertical blanking, but the current implementation does not constitute a formally CDC-safe atomic frame-boundary swap.

## 9. VGA Pixel Clock and Timing

The board 50 MHz clock feeds `vga_pll`, which generates:

```text
pclk_25 = 25 MHz
```

The VGA timing generator uses:

### Horizontal timing

| Segment | Pixels |
|---|---:|
| Visible | 640 |
| Front porch | 16 |
| Sync pulse | 96 |
| Back porch | 48 |
| Total | 800 |

### Vertical timing

| Segment | Lines |
|---|---:|
| Visible | 480 |
| Front porch | 10 |
| Sync pulse | 2 |
| Back porch | 33 |
| Total | 525 |

`VGA_HS` and `VGA_VS` are active-low.

At exactly 25 MHz, the nominal frame frequency is:

```text
25,000,000 / (800 × 525) ≈ 59.52 Hz
```

The implementation and comments refer to this as the conventional 640×480 @ approximately 60 Hz VGA mode.

RGB output is forced black outside the visible region.

## 10. Pixel Prefetch Path

The mixed-width VRAM read port is clocked by `pclk_25` and uses a 19-bit linear pixel address.

The subsystem implements a prefetch address generator so that the synchronous RAM read pipeline presents the required pixel bit when `VGA_SyncGen` reaches the corresponding visible coordinate.

The address generator:

- advances through 307,200 visible pixel positions in scan order,
- performs line-boundary prefetch handling,
- resets its linear read address around the end of the frame so pixel 0 is available for the next visible frame.

Software shall reason in framebuffer X/Y or 32-bit word coordinates rather than depending on the internal prefetch counter cycle sequence.

## 11. VSync CDC and Status Flag

`VGA_VS` originates in the 25 MHz pixel domain.

The active implementation synchronizes the VSync signal into HCLK using three sequential samples:

```text
vga_vsync_sig
   -> vsync_d1
   -> vsync_d2
   -> vsync_d3
```

and detects:

```text
vsync_rising_edge = vsync_d2 & ~vsync_d3
```

Because VGA VSync is active-low, this rising edge corresponds to **deassertion / end of the active-low VSync pulse**, not the beginning of the pulse.

When detected, the HCLK-domain `vsync_flag` becomes 1 and remains set until software clears it by writing 1 to `VRAM_STATUS[0]`.

The VSync flag is polling-based; no interrupt is generated.

## 12. Status and Control Registers

### 12.1 `VRAM_STATUS` — `0x2001_0000`

| Bit | Name | Access | Baseline behavior |
|---:|---|---|---|
| 0 | `VSYNC` | R / W1C | Sticky synchronized VSync-deassertion event flag |
| 1 | `CLEAR_DONE` | R | Direct `HW_Cleaner.clr_done` status |
| 2 | `CLEAR_BUSY` | R | 1 while the cleaner is actively writing framebuffer words |
| 31:3 | Reserved | R | 0 |

Important `CLEAR_DONE` semantics:

`clr_done` is high in both the cleaner `IDLE` and `DONE` states. It is therefore **not a one-cycle completion pulse** and is already high when the cleaner is idle after reset.

Software should use `CLEAR_BUSY == 0` to determine that active clearing has finished. The current production driver follows this policy.

Writing `VRAM_STATUS` only acts on bit 0. Writing 1 to bit 0 clears `VSYNC`; other write bits have no defined action.

### 12.2 `VRAM_CONTROL` — `0x2001_0004`

| Bit | Name | Access | Baseline behavior |
|---:|---|---|---|
| 0 | `SWAP` | W command | Toggle front/back ownership |
| 1 | `HW_CLEAR` | W command | Request hardware clear of the resulting/current back buffer |
| 31:2 | Reserved | W | Ignored |

The control register is command-style rather than stored read/write state. Reads are not part of the normative contract and the active VGA `HRDATA` path does not return control state.

## 13. Hardware Clear Engine

`HW_Cleaner` clears the visible back-buffer area by writing zero to:

```text
word 0 through word 9599 inclusive
```

The cleaner state machine is:

```text
IDLE -> CLEAR -> DONE -> IDLE
```

During `CLEAR`:

```text
clr_busy = 1
clr_we   = 1
```

and one 32-bit zero word is written per HCLK cycle.

The active clearing portion therefore requires 9,600 HCLK write cycles, approximately:

```text
9,600 / 50 MHz = 192 us
```

excluding command/start state-transition overhead.

### 13.1 Combined swap-and-clear command

The existing driver writes:

```text
SWAP | HW_CLEAR
```

in one control transaction. The intended result is:

```text
publish completed old back buffer as the new front
then clear the old front, which is now the new back
```

This is the normal baseline use of the hardware clear engine.

### 13.2 Cleaner priority over CPU framebuffer writes

While `CLEAR_BUSY=1`, the cleaner owns the back-buffer write address, write-enable, and write data mux.

A simultaneous CPU framebuffer write is therefore not applied to VRAM. However, the AHB slave still reports:

```text
HREADY = 1
HRESP  = OKAY
```

so the CPU cannot detect that the write was discarded.

**Normative software rule:** software shall not write the framebuffer while `CLEAR_BUSY=1`.

### 13.3 Swap while clear is active

The cleaner's physical RAM target is selected from the live `front_buffer_idx`. A second SWAP while clearing can therefore redirect subsequent cleaner writes to the other physical buffer.

**Normative software rule:** software shall not issue another SWAP while `CLEAR_BUSY=1`.

The combined initial `SWAP | HW_CLEAR` command is the intended exception because clearing starts after the buffer-role change and targets the resulting back buffer.

## 14. Reset Behavior

On system reset, the VGA subsystem resets control state including:

```text
front_buffer_idx = 0
vsync_flag       = 0
hw_clear_start   = 0
hw_clear_run     = 0
VRAM_ADDR        = 0
```

The VGA timing counters are also reset through `HRESETn` in the pixel-clock domain, and the VRAM read output/address path receives asynchronous clear through the RAM IP.

System reset shall **not** be treated as an architectural command to erase both framebuffer memories. Software requiring a known blank back buffer shall clear it explicitly in software or through `HW_Cleaner`.

Per `reset_clock.md`, reset deassertion and some generated-clock-domain usage require further CDC/reset cleanup before production-quality signoff.

## 15. Dormant APB VGA Source

`rtl/video/vga/APB_VGA_Top.v` is not instantiated in the active SoC top level.

Therefore:

- it has no canonical APB slot,
- its internal register behavior is not software-visible baseline behavior,
- firmware shall not target it,
- future refactoring shall not treat it as authoritative over `AHB_VRAM_DUAL_BUFFER`.

If a future architecture intentionally migrates VGA control onto APB/AXI-Lite, that change requires a new approved specification rather than silently activating this dormant source.

## 16. Firmware Contract

Current baseline firmware support includes:

```text
vram_status()
vram_wait_vsync()
vram_clear_vsync()
vram_swap_and_clear()
vram_wait_clear_done()
vram_write_word()
```

The normative sequence for hardware-assisted double buffering is:

```text
wait until current back buffer is available
render using aligned 32-bit writes
wait for synchronized VSync event
clear VSync flag
issue SWAP | HW_CLEAR
wait until CLEAR_BUSY == 0
render the next frame into the newly cleared back buffer
```

The `display_smoke` diagnostic deliberately uses a different validation sequence:

```text
software-clear all 9,600 back-buffer words
render frame
wait bounded time for VSync
issue SWAP only
```

This isolates buffer publication from the hardware-clear engine during board diagnosis.

Firmware shall not rely on:

- framebuffer readback,
- byte/halfword framebuffer writes,
- noncanonical VRAM aliases,
- writing framebuffer memory while clear is busy,
- issuing another swap while clear is busy.

## 17. Validation Status

The migrated baseline has reproduced successful Quartus compilation with the active AHB VGA subsystem.

The current `display_smoke` image has developer-confirmed physical-board VGA operation and visibly exercises:

- framebuffer 32-bit writes,
- 640×480 scanout,
- text / pattern pixel ordering,
- VSync polling progress,
- software-triggered SWAP,
- repeated frame publication.

The host-side display-smoke test uses mocked MMIO and checks framebuffer bounds, SWAP-only behavior, VSync timeout handling, and related software behavior. It is not CPU/RTL simulation.

The current display-smoke board test does **not** establish full proof of:

- hardware-clear operation,
- behavior of CPU writes attempted during hardware clear,
- framebuffer readback,
- byte/halfword framebuffer stores,
- formal CDC correctness of buffer selection,
- generated-clock/reset timing signoff,
- all physical alias boundaries.

## 18. Baseline Cleanup Targets Before Major Feature Integration

The following items shall be carried into the later consolidated `baseline_cleanup.md` plan:

1. **Tighten VGA top-level decode** to the canonical framebuffer/status/control aperture rather than selecting the full `0x2xxx_xxxx` region.
2. **Enforce frozen A3 read policy** — keep the window write-only and make framebuffer reads return A2 ERROR; remove misleading read expectations.
3. **Enforce frozen A3 access policy** — reject byte/halfword framebuffer writes; remove or prohibit `vram_write_byte()` and equivalent APIs rather than adding byte strobes/RMW.
4. **Fix cleaner/CPU write arbitration** — do not silently acknowledge and discard CPU framebuffer writes while `CLEAR_BUSY=1`; use backpressure, explicit rejection/error, or a stronger architectural ownership mechanism.
5. **Latch cleaner target ownership** at clear start so a later SWAP cannot redirect an in-progress clear operation.
6. **Make frame swap CDC-safe** — synchronize/handshake the swap into the pixel domain and preferably commit buffer ownership at a defined frame boundary.
7. **Define generated-domain reset release** and PLL-lock policy consistently with `reset_clock.md`.
8. **Add complete generated-clock timing constraints** for `pclk_25` and re-run STA/CDC review.
9. **Clarify `CLEAR_DONE` semantics** — consider a sticky completion event or rely solely on BUSY rather than using a signal that is high during IDLE.
10. **Add directed RTL verification** for pixel/word boundaries, status W1C behavior, swap timing, clear length, clear/write contention, repeated commands, reset, and reserved addresses.
11. **Add FPGA acceptance coverage for HW clear** because the current `display_smoke` board test intentionally clears in software.
12. **Remove active/dormant VGA ambiguity** by clearly separating or deleting unused `APB_VGA_Top` integration artifacts when safe to do so.

## 19. Baseline Invariants

Until a future approved VGA/display specification supersedes this document:

1. The active display subsystem is AHB-side `AHB_VRAM_DUAL_BUFFER`, not an APB VGA peripheral.
2. The canonical visible framebuffer is 640×480×1 bpp = 38,400 bytes = 9,600 words.
3. CPU framebuffer access is normative only as aligned 32-bit writes.
4. CPU framebuffer readback is not implemented.
5. Pixel 0/1 maps to black/white respectively.
6. The display uses two physical VRAM buffers and software-visible access always targets the current back buffer.
7. Reset selects VRAM0 as front and VRAM1 as back.
8. SWAP toggles physical front/back ownership.
9. VSync status is a sticky HCLK-domain flag generated from the synchronized rising/deassertion edge of active-low VGA VSync.
10. VGA timing is 800×525 total with a 25 MHz pixel clock and 640×480 visible region.
11. Hardware clear writes zero to words 0..9599 of the current back buffer.
12. Software must not write or re-swap the framebuffer while hardware clear is busy.
13. Broad physical aliases outside the canonical VGA aperture are unsupported.
14. Dormant `APB_VGA_Top.v` behavior is not part of the active baseline contract.

## 20. Related Specifications

This document shall remain consistent with:

- `soc_architecture.md`
- `memory_map.md`
- `ahb_fabric.md`
- `reset_clock.md`
- future `firmware_contract.md`

The later consolidated `baseline_cleanup.md` shall collect the cleanup items recorded here together with those from the other baseline specifications.

## Phase 4A-2 Approved Framebuffer and Physical Target (bus access policy active Phase 4A-3A)

A3 freezes framebuffer access as write-only, naturally aligned 32-bit word writes. Reads, byte/halfword writes and noncanonical gaps/aliases follow A2 two-cycle AHB ERROR and CPU access-fault handling. A misaligned CPU store instead takes the pre-bus misalignment cause 6; a direct bus-master misaligned framebuffer transaction is invalid and receives A2 ERROR. `VRAM_STATUS` and `VRAM_CONTROL` keep their separately specified semantics. Firmware uses `vram_write_word()`; `vram_write_byte()` is legacy and must be removed/deprecated during implementation, with no readback API. Current RTL's silent/partial behavior above is not the target. STA-002 requires review of VGA digital output standard, voltage, drive/load and board timing evidence, plus the ADC/VGA pin-adjacency warning and ADC behavior during relevant VGA activity; positive internal slack alone is not board signoff.

## P08B Local Candidate — Implementation Pending Review

The uncommitted P08B candidate implements the frozen replacement contract. This
section supersedes historical active-behavior descriptions above for that local
candidate only; published public `main` remains the earlier Gate 0 snapshot.

`VRAM_STATUS` is aligned 32-bit read/W1C at `0x2001_0000`:

| Bit | Name | Semantics |
|---:|---|---|
| 0 | `VSYNC_EVENT` | sticky W1C; hardware set dominates coincident clear |
| 1 | `OP_DONE` | sticky W1C after final swap acknowledge or final clear write |
| 2 | `OP_BUSY` | read-only live one-outstanding-operation state |
| 3 | `OP_ABORT` | sticky W1C for PLL-loss operation abort |
| 4 | `DOMAIN_READY` | read-only ownership/recovery handshake complete |

`VRAM_CONTROL` at `0x2001_0004` is write-only: bit 0 `SWAP`, bit 1
`HW_CLEAR`. Swap commits once at pixel wrap `(799,524)->(0,0)`. Clear writes
exactly words 0 through 9599 to a target bank latched at acceptance. Combined
operation swaps first and clears the old front/new back. A nonzero command is
accepted only while ready and idle; overlapping/not-ready accesses receive the
VGA-owned two-cycle ERROR. Unsupported framebuffer reads, sizes, gaps and local
aliases likewise ERROR without a rejected physical write.

The pixel and HCLK domains exchange request/acknowledge toggles; neither uses a
live asynchronous bank selector. PLL loss gates writes, aborts an active
operation, resets ownership to VRAM0-front/VRAM1-back through recovery, and
leaves output black until a later valid swap. Open focused/integrated DV is
PASS, while User/Chat acceptance, Quartus/TimeQuest and board evidence remain
pending/NOT_RUN. P08B therefore remains `IN_PROGRESS/PENDING_REVIEW`.

### P08B AHB write-completion atomicity

Address acceptance is not write completion. For an outstanding framebuffer or
control write, the VGA slave revalidates raw PLL lock, synchronized domain
readiness and idle ownership at the data commit phase. If a required condition
is lost before physical commit, the transfer completes as the VGA-owned
two-cycle ERROR (`HRESP=ERROR/HREADY=0`, then `HRESP=ERROR/HREADY=1`) and both
physical VRAM write enables remain zero. A write already physically committed
with final OKAY is not retroactively failed, repeated or rolled back. Thus a
final OKAY write maps to exactly one physical commit, while a pre-commit ERROR
maps to zero. `HREADY_IN=0` holds a valid data phase without repeated commits.

The simulation boundary treats lock low before the HCLK commit edge as ERROR
and lock loss after that edge as non-retroactive. This functional rule does not
claim asynchronous setup/hold or metastability closure; static CDC and vendor
timing review remain required and `NOT_RUN` at this checkpoint.

**Phase 4A-3A status:** top-level AHB decode enforces aligned word framebuffer writes and rejects reads, subword writes, misaligned direct-bus writes, gaps, and aliases before selecting VRAM. Directed bus tests pass. Firmware API cleanup, VGA functional/CDC cleanup, and STA-002 physical signoff remain open.
