# P08B VGA / VRAM Specification

> **Status:** Current VGA / VRAM contract. The owner-accepted P08B functional scope is a verified prerequisite; `CDC-001` remains OPEN until later implementation, independent behavioral DV, and structural CDC review are accepted. English is canonical; [`kor/08_vga.ko.md`](kor/08_vga.ko.md) is semantically synchronized.
>
> **Reviewed source anchor:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. This is functional-scope acceptance, not a release, CDC, or full timing-sign-off claim.

> **C08 diagnostic ABI amendment:** Section 3.2's bit 5 and bits 31:16, Sections 3.2.1–3.2.4, and Section 5.2 are a normative draft pending Owner/Chat spec review. They are not implemented or verified. Existing bits 4:0, functional timing, and accepted P08B criteria retain their contracts. The reviewed source anchor does not substantiate the new diagnostics.

## 1. Status and Scope

The active display peripheral is the AHB-side `AHB_VRAM_DUAL_BUFFER` instance in `AMBA_SoC_TOP`; dormant `APB_VGA_Top` is not an active interface. The scope comprises canonical AHB access, double-buffer ownership, hardware clear, VGA scanout, and the firmware-visible status/control contract.

`VGA-001..006` are VERIFIED for the frozen functional scope and owner accepted. `RST-002` is a VERIFIED reset/PLL-lock prerequisite. `VGA-007` and `CDC-001` remain OPEN, and `VER-003` remains OPEN for downstream asynchronous-clock/reset verification. Full STA (`STA-001`), external I/O timing (`STA-002`), VGA/ADC warning disposition, the pre-`mtvec` reset window, and independent programmer/JTAG image-to-board binding are outside the P08B verdict and are not promoted by this specification authoring stage.

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

`front_bank_p` is the pixel-domain display selection and `front_bank_h` is the HCLK-domain ownership view reconstructed only after an acknowledged swap commit during a valid operational epoch. Reset/recovery rebase is the explicit architectural exception and establishes VRAM0 front and VRAM1 back. CPU writes always target the HCLK back bank; the cleaner uses a target bank latched when its clear begins.

The normative cross-domain request is a **swap-request epoch**, not an arbitrary multi-bit payload. Every accepted command containing `SWAP=1` publishes exactly one logical swap request; a clear-only command publishes no pixel-ownership request. Any internal implementation signal used to encode or qualify that request is not itself a software-visible contract and remains subject to later structural CDC review.

### 2.2 Geometry, storage, and pixels

The visible framebuffer is 640 x 480 x 1 bpp = 307,200 bits = 38,400 bytes = 9,600 32-bit words. There are 20 words per line. For visible coordinates:

```text
word_index = y * 20 + (x >> 5)       (0 <= x < 640, 0 <= y < 480)
bit_index  = x & 31
```

The leftmost pixel of a 32-pixel word is bit 0; increasing X selects increasing bit positions. A zero bit drives black (`R=G=B=0`), and a one bit drives white (`R=G=B=0xF`) when video is active and display is armed.

Each physical RAM has a 16,384 x 32-bit HCLK write view and a 524,288 x 1-bit pclk read view. Only words 0..9599 / bits 0..307199 are visible architectural storage; the remaining physical capacity is reserved and is not software addressable. Read-side synchronous prefetch is an implementation interface constraint: software must use X/Y or word coordinates, never the prefetch counter.

### 2.3 Operations and bank transitions

An **operation request is accepted** only when an aligned, supported `VRAM_CONTROL` write reaches its final-OKAY data phase with `HREADY_IN` qualifying completion, the VGA domain still valid for acceptance, `DOMAIN_READY=1`, `OP_BUSY=0`, and command bits `[1:0] != 0`. A final-OKAY CONTROL write whose command bits are zero is a valid bus write but is **not** an operation request.

Only one operation may be outstanding. Acceptance of a nonzero command starts that operation and makes `OP_BUSY=1`; no later framebuffer write or nonzero CONTROL request may be accepted until the operation completes or is aborted/reset. STATUS reads and W1C writes are not operations and retain their separate access policy.

For an operation containing `SWAP=1`, HCLK publishes exactly one logical swap-request epoch to the pixel domain. The pixel domain may mark the request pending after synchronization, but the **ownership commit** is only the `pclk_25` edge on which the pre-edge timing state is `(h_cnt,v_cnt)=(799,524)` and `front_bank_p` toggles exactly once as the frame counters wrap to `(0,0)`. The prefetch reset point `(798,524)` is not an ownership commit.

The returning ACK acknowledges **that completed pixel-domain ownership commit**, not mere request receipt. The pixel domain shall not publish the ACK for a swap request before `front_bank_p` has committed, and clear-only operation has no swap ACK requirement. After the ACK crosses back to HCLK, the first recognized ACK event for the outstanding swap-bearing operation updates `front_bank_h` exactly once. During the possible interval between pixel commit and HCLK reconstruction, `OP_BUSY=1` prevents CPU framebuffer writes, so HCLK/pixel ownership-view latency cannot expose the displayed bank as writable.

The successful completion rules below apply to an accepted operation that remains valid in the same recovery epoch until completion. Cancellation/abort follows Section 2.4 instead; acceptance alone does not guarantee a successful commit or `OP_DONE`.

| Accepted command | Pixel-domain ownership action | Successful overall completion / `OP_DONE` |
|---|---|---|
| `SWAP` | publish one swap request; commit `front_bank_p` once at frame wrap; return one post-commit ACK | consume the synchronized ACK, update `front_bank_h`, then clear `OP_BUSY` and set sticky `OP_DONE` |
| `HW_CLEAR` | none; displayed front remains unchanged | latch the current writable back bank at acceptance; clear words 0..9599; after the physical word-9599 zero write commits, clear `OP_BUSY` and set sticky `OP_DONE` |
| `SWAP | HW_CLEAR` | same swap request/commit/ACK sequence as `SWAP` | consume ACK and update `front_bank_h`; then latch the old front/new back as clear target; keep `OP_BUSY=1`; set `OP_DONE` only after physical word-9599 clear commit |
| command bits `[1:0]==0` | none | no operation; no `OP_BUSY`, request, clear, ACK, or `OP_DONE` is created by that write |

An overlapping framebuffer/control request, a framebuffer/control request while domain readiness is absent, or either request rejected at data commit receives ERROR. A rejected framebuffer request performs zero VRAM word writes; a rejected control request issues zero commands. No accepted operation may write the displayed front bank.

### 2.4 Reset, PLL lock loss, and abort semantics

The pixel reset request is `HRESETn & vga_pll_locked` and is released only through `reset_release_sync` in `pclk_25`. Loss of either system reset or PLL lock therefore invalidates the pixel-domain ownership epoch and clears pixel-domain pending swap/display-arming state.

**System reset and PLL lock loss have different software-visible abort semantics:**

- **System reset (`HRESETn=0`)** cancels any in-flight operation as part of resetting the VGA HCLK and pixel-domain state. Sticky status, including `OP_DONE` and `OP_ABORT`, is reset; software shall not require a pre-reset abort event to remain observable after reset.
- **PLL lock loss while system reset remains released** immediately gates physical VRAM writes with raw lock, reasserts pixel reset, drops `DOMAIN_READY` as recovery is recognized, cancels the outstanding operation, and sets sticky `OP_ABORT` if an operation was active. An aborted operation shall not later produce `OP_DONE`.

If system reset or PLL lock loss cancels a swap-bearing operation before its pixel ownership commit, that canceled operation has zero required ownership commits (no commit shall occur), zero successful ACKs, and no `OP_DONE`. PLL-loss abort uses `OP_ABORT` when HCLK state remains alive; full system reset clears the old operation/status epoch. If cancellation occurs after a physical effect has already committed, that effect is not retroactively undone, but the canceled operation cannot later produce successful overall completion or `OP_DONE`.

In both cases the ownership state is rebased to VRAM0 front / VRAM1 back before new framebuffer/control acceptance. This reset/recovery rebase explicitly permits `front_bank_h` to change without a swap ACK; it is not a successful swap completion. Framebuffer contents are not an architectural reset-clear guarantee. Display arming is cleared by pixel reset, so output remains black until a later successfully committed swap arms display.

### 2.5 Recovery epoch, stale-event suppression, and liveness

`DOMAIN_READY` is a live statement that the **current** post-reset/post-lock-loss pixel ownership epoch has completed recovery. It is not an alias of raw PLL lock.

Recovery shall satisfy all of the following before `DOMAIN_READY` becomes 1:

1. system reset is released and PLL lock is valid;
2. the pixel domain has passed through its reset state for the new epoch and subsequently reached its ready state;
3. HCLK ownership is rebased to VRAM0 front / VRAM1 back;
4. request/ACK observation baselines are rebased so a pre-recovery request, ACK, or stale ready level cannot be interpreted as a new transaction.

While `DOMAIN_READY=0`, new framebuffer writes and nonzero CONTROL operations are rejected and cannot produce physical VRAM writes or command side effects. After recovery reaches `DOMAIN_READY=1` with `OP_BUSY=0`, the next valid operation, provided it remains valid in that recovery epoch until successful completion, shall be able to complete using only post-recovery state; no pre-reset/pre-lock-loss toggle, ACK, or pending request may be required for forward progress.


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

Address acceptance is not data-phase bus acceptance, and bus acceptance is not later operation completion. For framebuffer/control writes, raw PLL lock, synchronized readiness, and idle ownership are revalidated at the data phase. For a framebuffer transfer, final OKAY means exactly one physical word write to the writable back bank; pre-acceptance ERROR means zero. For a control transfer, final OKAY means exactly one register-command acceptance, not an immediate VRAM word write; any swap acknowledgement or cleaner write occurs later. A completed effect is neither rolled back nor repeated. This is a functional atomicity contract, not static CDC/metastability sign-off.

Misaligned CPU instructions take the CPU's pre-bus misalignment path (store cause 6); a direct bus transaction with invalid VGA size/alignment receives the local two-cycle ERROR. A terminal rejected VGA store is a faulting operation, not a firmware-retry result.

### 3.2 Status register: `VRAM_STATUS` (`0x2001_0000`)

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `VSYNC_EVENT` | RO / W1C | Sticky HCLK event on synchronized rising/deassertion edge of active-low `VGA_VS`. |
| 1 | `OP_DONE` | RO / W1C | Sticky **successful overall operation** completion only: post-ACK HCLK ownership reconstruction for swap-only, or final clear-word commit for clear-only / combined. Never set by an aborted operation. |
| 2 | `OP_BUSY` | RO | Live one-outstanding-operation state from accepted nonzero CONTROL request until overall completion, PLL-loss abort, or system reset. |
| 3 | `OP_ABORT` | RO / W1C | Sticky abort when PLL-domain invalidation terminates an active operation while HCLK state remains alive. Full system reset clears it with the other status state. |
| 4 | `DOMAIN_READY` | RO | Current recovery epoch is established and framebuffer/nonzero CONTROL acceptance may resume. Not merely raw PLL lock. |
| 5 | `IS_CDC` | RO / W1C | Sticky observed lock-loss-associated sampled CPU framebuffer write-command / final accepted AHB response disagreement; reset value 0. See Section 3.2.1. |
| 15:6 | reserved | RAZ / WI | Reads zero; writes ignored. |
| 31:16 | `LOCK_LOSS_COUNT` | RO / WI | 16-bit saturating captured PLL lock-loss episode count; reset value 0, saturation `0xFFFF`. See Section 3.2.2. |

Writing one selectively clears bits 0, 1, 3, and (in the amendment) 5; writing zero does not acknowledge them. Hardware set wins a same-HCLK-edge W1C clear. Existing bits 4:0 retain their reset/event priority and timing. `OP_BUSY` and `DOMAIN_READY` are live and are not W1C state. Writes to bits 31:16, 15:6, 4, and 2 are ignored: no STATUS write can change the counter or acknowledge an unselected event.

`HRESETn=0` clears both new diagnostic fields and any pending diagnostic event/transaction history. A selective bit-5 W1C is the only software clear of `IS_CDC`; `HRESETn` is its only reset source. PLL loss, pixel reset, ownership-epoch invalidation, and recovery must not erase either diagnostic or a pending captured loss. The counter has no software clear; bit-5 W1C leaves it unchanged. Reset dominates diagnostic set/clear while asserted; after reset release, hardware set dominates W1C.

Status access does not use the framebuffer/control readiness rejection gate. Consequently, an aligned status read or W1C write can be accepted while `OP_BUSY=1` or `DOMAIN_READY=0`. An accepted W1C bus write performs only the selected event acknowledgements; it is never a VRAM word write.

### 3.2.1 Sampled-command mismatch and transaction association (draft)

The diagnostic observes HCLK-sampled **CPU-attributable framebuffer write commands** at the bank write-port interface and the response of the **same captured data-phase transaction**. It observes command intent, address/data, selected bank, and command multiplicity, not an independent BRAM bitcell acknowledgement. The comparison reference is exactly one CPU command for final OKAY, and zero for final ERROR, for a supported aligned canonical framebuffer word write. Cleaner writes, CONTROL/STATUS transfers, unsupported addresses/sizes/directions, and unrelated bus phases are excluded.

A terminal response is globally accepted only at the HCLK completion edge with both local `HREADY=1` and `HREADY_IN=1`. ERROR's first `HREADY=0` cycle is not final completion. An OKAY indication while `HREADY_IN=0` is held, not accepted. Early/held-phase observations must not create standalone completed comparisons; if an out-of-completion CPU command is recorded, it must remain attached to that same transaction as a command-timing/multiplicity violation until its terminal comparison. No synthetic completion, duplicate transaction, or attribution of a Cleaner write is permitted.

Set `IS_CDC` only when this transaction has a detected command/response disagreement **and** a lock-loss association observed during that transaction's outstanding data-phase interval: sampled invalid raw lock or a captured loss notice carrying unambiguous contemporaneous transaction association. A delayed untagged loss notification must not retroactively qualify an earlier completion or an unrelated later transaction. Ambiguous association is outside diagnostic coverage. A command that completed correctly before a later loss is not a mismatch; a legitimate loss-rejected ERROR with zero CPU commands is not a fault. A captured loss without a CPU framebuffer transaction increments the counter alone.

The monitor is observational: it must not drive functional commit, write-enable, AHB response, bank ownership, reset, or recovery controls. `IS_CDC=0` means only no observed qualified mismatch. A shared Boolean expression for response and write-command can make the comparison vacuous or synthesis can eliminate redundant logic; neither a retained monitor nor a zero flag proves independence. Lock transitions near a physical memory write edge, metastability, pulse width, and actual bitcell effects remain outside sampled-command proof.

### 3.2.2 Captured PLL loss episodes, arm/rearm, and clock stops (draft)

An episode is a captured `vga_pll_locked:1→0` transition while diagnostic capture is armed, not each low cycle. After `HRESETn`, capture starts disarmed with no pending event; initial lock=0 and initial acquisition of lock do not increment the counter. Stable lock for arming means at least two consecutive HCLK observations of synchronized lock=1 while `HRESETn=1`. This is a digital qualification interval, not proof of analog PLL stability.

Arm only after that stable-lock qualification and acknowledgement/retirement of any previous captured notice, with the capture/transfer channel idle. The first captured loss disarms capture and preserves one pending episode until HCLK can consume it. Consumption increments `LOCK_LOSS_COUNT` once (or retains `0xFFFF`) and acknowledges that notice. Rearm requires a **new** stable-lock qualification after the loss plus completion of that capture/acknowledgement; a continuously low level cannot rearm. Losses during capture, transfer, acknowledgement, or disarmed recovery can coalesce or remain uncounted. This is not a loss-event FIFO or a perfect physical event counter.

An asynchronous capture mechanism must preserve an armed, successfully captured episode across PLL/pixel epoch reset. If HCLK stops, retirement, counter update, and software observation wait until HCLK restarts; the captured pending notice must survive that interval unless `HRESETn` asserts. PCLK stop/restart alone is neither a lock-loss episode nor a counter reset, and diagnostic transfer must not depend on PCLK progress. A loss while already disarmed need not be counted. No guarantee is made for arbitrary short pulses; minimum capture/rearm pulse widths and physical implementation limits require later device/board evidence.

### 3.2.3 STATUS sampling and interpretation (draft)

One aligned STATUS read samples a complete 32-bit HCLK-visible register image at its globally accepted read-completion edge. Both diagnostic fields come from the same pre-update image; updates retired at that edge appear on a subsequent read. A held read does not independently complete. This prevents torn software reads of the counter/flag but does **not** atomically order pending asynchronous loss capture, transaction diagnosis, counter retirement, or the other live status fields against an external edge. A pending notice can be absent from the returned count; fault and count visibility need not occur together.

For an interval without `HRESETn`, with both endpoint counts below `0xFFFF`, a positive ordinary counter difference demonstrates captured, retired loss opportunities only if the test setup and event provenance are valid. It does not show all physical losses or stress at a particular write edge. At saturation the true number of further losses is unknown; never use modulo/wrap subtraction. `COUNT=0` does not certify absence of physical loss; `COUNT>0 && IS_CDC=0` does not prove physical commit or CDC correctness. Counter retention after fault W1C and delayed capture retirement also prevent treating the two fields as a single event log.

### 3.2.4 Firmware / Health diagnostic use (draft)

Firmware obtains both fields through one `vram_status()` result: bit 5 is the fault and `(status >> 16) & 0xFFFF` is the captured count. Read and report that snapshot before an explicit bit-5 W1C. Routine `vram_clear_events()` and operation/VSYNC housekeeping retain masks containing only bits 0, 1, and 3; they must not acknowledge bit 5 or write a saved full STATUS value back as an event-clear mask. No current driver API is claimed to implement the new explicit fault-clear operation. A pending newly diagnosed mismatch can set/re-set the sticky bit despite software clearing older history.

Health qualification still requires the existing READY/VSYNC/SWAP/DONE progress and abort/error rules. The diagnostic supplements those observations; a zero fault or a nonzero counter is never sufficient for a Health PASS or `VGA-CDC-AC-09`. Framebuffer remains write-only; readiness prechecks do not remove MMIO races, terminal ERROR traps, or the lack of automatic retry/trap recovery. Future board stress requires independent external lock-loss/stimulus timing evidence and confirmed capture/arm conditions; the internal counter alone cannot establish an edge-near loss opportunity.

### 3.3 Control register: `VRAM_CONTROL` (`0x2001_0004`)

| Bit | Name | Access | Meaning |
|---:|---|---|---|
| 0 | `SWAP` | WO command | Request frame-boundary ownership swap. |
| 1 | `HW_CLEAR` | WO command | Request clear as defined in Section 2.3. |
| 31:2 | reserved | WO | Ignored; they do not create an operation. |

The register stores no command state and has no read contract. A supported write is accepted once at its data phase. If bits `[1:0]==0`, including a value containing only reserved bits, the write has no operation effect. If either command bit is one, the acceptance issues one operation and sets the corresponding operation state; completion occurs later at frame-wrap acknowledgement and/or after cleaner word 9599. A nonzero command is accepted only when `DOMAIN_READY=1` and `OP_BUSY=0`; otherwise its transfer is rejected as above.

### 3.4 Firmware API and usage contract

The frozen driver exposes the following bounded interface. `OK`, `TIMEOUT`, `NOT_READY`, `BUSY`, and `ABORTED` below denote the corresponding `VRAM_RESULT_*` enum values. These functions do not catch CPU bus traps produced by invalid or race-lost MMIO; their return values describe only status values observed and checks performed before their direct MMIO accesses.

| Function | Arguments and behavior | Return / limitation |
|---|---|---|
| `vram_status()` | Reads the aligned status register. | Returns the raw 32-bit status value. |
| `vram_clear_events(mask)` | Writes only `mask & (VSYNC_EVENT | OP_DONE | OP_ABORT)` to W1C status. | `void`; BUSY/READY and unselected events are not acknowledged. |
| `vram_wait_ready(poll_budget)` | Polls until `DOMAIN_READY=1`, at most `poll_budget` reads. | `OK` or `TIMEOUT`. |
| `vram_wait_vsync(poll_budget)` | Per poll, checks `OP_ABORT`, then not-ready, then `VSYNC_EVENT`. | `ABORTED`, `NOT_READY`, `OK`, or `TIMEOUT`. |
| `vram_start_operation(command)` | Masks command to `SWAP|HW_CLEAR`; prechecks READY then BUSY; zero becomes a no-op. For nonzero, clears stale DONE/ABORT then directly writes CONTROL. | `NOT_READY`, `BUSY`, or `OK`. `OK` is not proof that a later MMIO race cannot fault and is not operation completion. |
| `vram_wait_operation(poll_budget)` | Per poll, checks `OP_ABORT`, then not-ready, then `OP_DONE`. | `ABORTED`, `NOT_READY`, `OK`, or `TIMEOUT`. |
| `vram_write_word(word_offset,value)` | Directly writes `VRAM_BASE + 4*word_offset`. | `void`; performs no bounds/readiness/ownership check and provides no trap recovery. Caller must supply `0..9599` under writable-back-bank conditions. |

The normal production sequence is bounded: wait READY; render the back bank with aligned word writes; W1C stale VSYNC; wait VSYNC; call `vram_start_operation(SWAP|HW_CLEAR)`, which first W1C-clears stale DONE/ABORT; then wait for `OP_DONE` or a bounded failure result. An API result is not a substitute for the hardware access-fault contract. A standalone display-smoke diagnostic may use a different test sequence; the separately identified board-diagnostic source in the evidence is not part of the frozen source anchor and cannot redefine this production contract.

### 3.5 VGA timing and scanout constraints

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
| canonical, ready, idle framebuffer write | one final OKAY data-phase acceptance | exactly one HCLK back-bank word write; no front-bank or held-phase duplicate |
| accepted STATUS W1C write | final OKAY and selected event acknowledgement | no VRAM word write; unrelated/live fields unchanged |
| accepted nonzero CONTROL write | final OKAY and exactly one command issue | no immediate VRAM word write; later operation/ack/clear/`OP_DONE` remains distinct |
| accepted CONTROL write with command `[1:0]==0` | final OKAY and no operation | reserved bits ignored; no request, clear, or VRAM word write |
| unsupported address/direction/size/alignment | two-cycle ERROR | no VRAM write, status mutation, or command issue |
| busy or not-ready framebuffer/control request | two-cycle ERROR | no cleaner target change, request toggle, command issue, or CPU write |
| PLL loss before framebuffer/control data-phase acceptance | two-cycle ERROR | no framebuffer write or control-command issue for that transfer |
| PLL loss during active operation | abort/recovery; `OP_ABORT` sticky | no continued physical clear write after lock loss |

The following MUST always hold:

- Only canonical aligned word framebuffer writes may change visible framebuffer storage.
- A clear target is immutable after clear starts and clear writes exactly one zero word per permitted HCLK edge for addresses 0..9599.
- Swap is visible only at the defined pixel frame wrap; a combined clear never targets its displayed new front.
- Sticky events remain observable until their own W1C acknowledgement; unrelated W1C bits do not clear them.
- A final OKAY framebuffer write corresponds to exactly one physical back-bank word commit; its ERROR completion corresponds to zero.
- A final OKAY control write corresponds to one accepted register write. Only nonzero command bits issue an operation, whose later swap/clear effects and completion event are distinct from bus acceptance.
- An accepted status W1C write acknowledges only selected sticky events and never writes framebuffer memory.
- Static CDC, full STA, physical timing, and every displayed pixel value are not inferred from a protocol simulation or a photograph.
- Every accepted swap-bearing operation creates at most one pixel pending-swap transaction and at most one ownership commit.
- A swap ACK is causally downstream of its pixel-domain ownership commit; request receipt alone cannot generate the successful ACK.
- During a valid operational epoch, `front_bank_h` changes only when HCLK consumes the synchronized ACK for the currently outstanding swap-bearing operation. Reset/recovery ownership rebase to VRAM0 front is the explicit architectural exception and requires no successful swap ACK.
- Whenever a CPU framebuffer write is accepted, the selected writable bank is the non-displayed bank. Ownership-view skew during a swap is tolerated only because framebuffer writes remain blocked while `OP_BUSY=1`.
- Full system reset discards the pre-reset operation/status epoch; PLL lock loss without system reset produces the sticky `OP_ABORT` contract described above.
- Recovery must suppress stale request/ACK/ready state and permit the first valid post-recovery transaction to make forward progress.

## 5. Acceptance Criteria

| ID | Stable stimulus and assertion | Pass condition |
|---|---|---|
| `VGA-AC-01` | Exercise canonical aperture boundaries and reserved gaps. | Canonical framebuffer/status/control addresses decode deterministically and gaps/aliases do not become architectural accesses. |
| `VGA-AC-02` | Exercise unsupported read/size/alignment and unaccepted busy/not-ready traffic. | Each request returns two-cycle ERROR with no framebuffer, status, ownership, or command side effect. |
| `VGA-AC-03` | Exercise swap-only, clear-only, combined, overlap, and ownership transitions. | Swap/clear ordering is atomic, clear target remains latched, displayed front is preserved, and overlaps are rejected. |
| `VGA-AC-04` | Set, clear, repeat, and coincide VSYNC/DONE/ABORT events and inspect BUSY/READY. | Sticky W1C events are independent and deterministically ordered/set-dominant; BUSY/READY remain live. |
| `VGA-AC-05` | Start an accepted clear on a known latched bank and count cleaner physical commits/addresses. | Exactly 9,600 zero-word commits occur, covering words 0 through 9599 exactly once on that bank. |
| `VGA-AC-06` | Observe standalone hardware-clear/swap screen sequence on board. | Bounded photographs show the expected visible black/restored transition only. |
| `VGA-AC-07` | Observe combined and no-write-swap board sequence. | Bounded photographs show expected white/black/restored visible states only. |
| `VGA-AC-08` | Board operator repeats the smoke sequence. | Operator reports normal operation through the stated bounded cycle count. |

These IDs preserve the behavioral meanings published with `P08B-VGA-EV-01`; they are not reassigned to the separate held-phase or lock-loss/reset matrices. Those matrices support detailed current-contract statements but are not introduced here as new approved stable criteria. Run IDs, timestamps, hashes, and raw logs are retained only in evidence. Photographs do not prove the AC-05 count, individual MMIO transactions, CDC/STA, or programmer identity.

### 5.1 VGA CDC / ownership acceptance criteria

The existing `VGA-AC-01..08` retain their P08B meanings. The criteria below define the additional stable acceptance boundary for `CDC-001`; they are **OPEN** until later verification produces accepted evidence.

| ID | Stable assertion | Pass condition |
|---|---|---|
| `VGA-CDC-AC-01` | Operation acceptance / one-outstanding rule | Every final-OKAY nonzero CONTROL request creates exactly one operation; no second framebuffer/nonzero-CONTROL acceptance occurs while `OP_BUSY=1`. |
| `VGA-CDC-AC-02` | Frame commit / ACK causality | Every accepted swap-bearing operation that remains valid in the same recovery epoch until successful completion commits `front_bank_p` exactly once at the defined frame wrap and produces no successful ACK before that commit; no orphan/duplicate ACK is observed. Pre-commit reset/PLL-loss cancellation produces zero commits, zero successful ACKs, and no `OP_DONE`. |
| `VGA-CDC-AC-03` | HCLK ownership reconstruction | For an accepted swap that remains valid in the same recovery epoch until successful completion, `front_bank_h` changes exactly once only after the synchronized ACK for that outstanding swap. Reset/recovery rebase to VRAM0 front is the explicit ACK-free exception. Accepted CPU writes never target the displayed pixel-domain front bank. |
| `VGA-CDC-AC-04` | Command-specific completion | Successful same-epoch completion only: swap-only after ACK consumption/ownership reconstruction; clear-only after final clear-word commit; combined only after ACK/reconstruction followed by final clear-word commit. Canceled/aborted operations produce no `OP_DONE`. |
| `VGA-CDC-AC-05` | Reset / lock-loss recovery | System reset discards the old status/operation epoch; PLL lock loss aborts an active operation without later DONE, and no physical clear/CPU write continues while the VGA domain is invalid. |
| `VGA-CDC-AC-06` | Stale-event suppression | Pre-recovery request, ACK, pending-swap, or ready state cannot create a post-recovery transactional commit, ACK, `OP_DONE`, or ownership update. The required reset/recovery ownership rebase is not a stale-event transaction. |
| `VGA-CDC-AC-07` | Recovery liveness | After `DOMAIN_READY=1` and idle are re-established, the next valid operation that remains valid in that recovery epoch until successful completion completes without dependence on pre-recovery toggle/state. |
| `VGA-CDC-AC-08` | Functional async/reset DV boundary | Independent behavioral verification exercises arbitrary HCLK/pclk phase plus reset/lock-loss overlap and checks request/commit/ACK/ownership identity, duplicate/loss, abort, and liveness with an oracle not derived from DUT ownership outputs. |
| `VGA-CDC-AC-09` | Structural CDC boundary | A separate structural/static CDC review establishes that every HCLK↔pixel crossing used by the protocol has an intentional synchronizer/handshake/dual-clock-memory mechanism and any bundled-control stability assumption is explicitly justified. |

`VGA-CDC-AC-08` is behavioral proof; `VGA-CDC-AC-09` is structural CDC proof. TimeQuest generated-clock, recovery/removal, exception, and slack review remains under `STA-001` and shall not be inferred from either criterion.

### 5.2 Diagnostic amendment acceptance cases (draft; not executed)

These new criteria do not replace `VGA-AC-01..08` or `VGA-CDC-AC-01..09` and have no accepted implementation/DV evidence. Positive cases and the listed counterexamples require later scoped verification with an independent transaction/event oracle; no test execution is authorized by this document amendment.

| ID | Required case and counterexample | Pass condition |
|---|---|---|
| `VGA-DIAG-AC-01` | Initial lock low, acquisition, qualified arm, one sustained loss; hold low. | Startup/acquisition count 0; one captured armed loss increments once; low cycles do not increment again. |
| `VGA-DIAG-AC-02` | Loss/ack/relock/rearm; rapid pulses before rearm; saturation. | New qualified episode after rearm increments once; unarmed/rapid losses are not promised individual counts; `0xFFFF` never wraps. |
| `VGA-DIAG-AC-03` | Qualified same-transaction loss-associated command/response mismatch versus matching OKAY/one command and ERROR/zero commands. | Only the qualified mismatch sets bit 5; loss without framebuffer traffic changes count only. A future isolated negative control must establish checker sensitivity without changing production state. |
| `VGA-DIAG-AC-04` | Held OKAY, ERROR wait/final, early command, Cleaner/CONTROL/unsupported traffic, delayed untagged notice. | Global completion and transaction identity govern comparison; excluded traffic cannot set bit 5; no unrelated or retroactive association. |
| `VGA-DIAG-AC-05` | Selective/routine W1C, zero writes, RO/reserved writes, simultaneous set/clear. | Only selected sticky events clear; bit-5 hardware set wins W1C; count/live/unselected fields are unchanged. |
| `VGA-DIAG-AC-06` | PLL/pixel reset, stopped/restarted HCLK/PCLK, then HRESETn. | Diagnostics/pending captured loss survive PLL/pixel recovery; HCLK restart retires once; PCLK is not required for transfer; HRESETn clears diagnostic history. |
| `VGA-DIAG-AC-07` | STATUS read coincident with retirement, pending transfer, fault clear, and saturation; Health progress missing. | One pre-update register image; no asynchronous total-order claim; correct counter-delta limits; no diagnostic-only Health/AC09 PASS. |
| `VGA-DIAG-AC-08` | Common-logic matching, edge-near/uncaptured short loss, count 0, count positive with fault 0. | Coverage limitations are reported, never converted to physical signoff or perfect event-count claims; independent board stimulus evidence is separately required. |

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

CDC/reset-related requirement state remains separate from the accepted P08B rows:

| Requirement | Status | Meaning |
|---|---|---|
| `RST-002` | VERIFIED prerequisite | P05 reset/PLL-lock infrastructure is accepted and shall be preserved. |
| `CDC-001` | OPEN | This specification defines the target protocol contract; implementation/independent-DV/structural-CDC acceptance has not yet closed it. |
| `VER-003` | OPEN | Downstream asynchronous-clock/reset verification remains required. |
| `STA-001` | IN_PROGRESS | Timing/exception closure remains a separate later gate. |

**C08 evidence disposition:** The separately approved diagnostic ABI/implementation has bounded current-candidate portable digital verification for captured loss episodes, diagnostic behavior and Boolean lock-gating. This status supersedes earlier diagnostic draft/not-executed labels; it does not change their ABI or acceptance cases. Physical edge-near raw PLL lock-loss safety is **NOT_PROVEN / UNDETERMINABLE**, with no demonstrated defect established by the available evidence. `IS_CDC=0` and captured `LOCK_LOSS_COUNT` are not physical safety certifications. Positive internal timing and zero fitted combinational SCCs do not establish reset/RDC safety or AHB/M9K write-edge atomicity. `VGA-CDC-AC-09` remains **BLOCK / NOT_VERIFIED**; `SYNCASYNCNET` remains **NOT_WAIVED**.

The current criterion-to-evidence mapping is intentionally compact:

| AC ID | Current result | Evidence class | Link |
|---|---|---|---|
| `VGA-AC-01` | PASS | same-RTL directed DV | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-02` | PASS | same-RTL directed DV | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-03` | PASS | same-RTL directed DV | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-04` | PASS | same-RTL DV plus firmware execution path | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-05` | PASS | same-RTL H05 exact-count DV | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-06` | PHOTO_OBSERVED | bounded cycle-0 board photographs | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-07` | PHOTO_OBSERVED | bounded cycle-0 board photographs | [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-08` | USER_ATTESTED | bounded operator report through cycle 5 | [P08B-VGA-EV-01 result](../reports/evidence/vga-hwclear/result.json) |

### 6.1 Assurance scope — draft claim boundary

> **PROPOSED / NOT_ACCEPTED:** This subsection and §7.2 are review drafts. They do not change the active operating contract, acceptance criteria or requirement status.

Existing functional evidence supports bounded behavior in an established valid epoch: nominal 50 MHz HCLK/reference and 25 MHz pixel clock, stable clock operation, qualified system reset with destination-domain release, one outstanding command, and the normal request/commit/ACK and selected-bank RAM handoff. This is an evidence envelope, not a new device operating specification or a guarantee that every physical startup or lock-loss event establishes that epoch. Clock-progress assumptions qualify liveness; stopped clocks do not authorize a fabricated ACK or completion.

Common effective reset assertion and valid release support the conditional abort/rebase sequence. **R1** still requires every required PLL invalidation to clear both reset branches; **R2** still requires pixel READY/ACK/pending invalidation and HCLK abort/rebase before stale state can be consumed as fresh. Neither premise is established merely by two release stages, a diagnostic count or positive STA. No minimum raw LOW width, differential reset skew or edge-near AHB/WE/M9K bitcell atomicity is certified.

The unproved physical conditions are restrictions on assurance claims, not excluded acceptance stimuli. Short or asymmetrically captured losses are not silently removed from `VGA-CDC-AC-05/06/08/09`. Required-event coverage, immediate write suppression, no-side-effect, abort and stale-event suppression remain binding. See the canonical [assurance limitation register](physical_assurance_limitations.md#c08-phys-001).


## 7. Approved Target / Deferred Work

### 7.1 C08 physical-assurance obligation — post-baseline execution scope

`C08-PHYS-001` identifies only the unproven physical guarantee for asynchronous raw PLL `locked` fall near HCLK/PCLK/VRAM WE, minimum loss/capture/rearm pulses, split reset capture/release skew and reconvergence, and AHB final response versus M9K write-edge atomicity. Its qualification work is removed from the current baseline-cleanup execution queue and assigned to **`POST_BASELINE_P12_PHYSICAL_QUALIFICATION`**. This is conditional physical-evidence scheduling, not an accepted safety waiver, a VERIFIED result, or an exemption from an existing cleanup gate.

Existing digital tests and Boolean gating establish bounded behavior under their modeled clock/reset assumptions. They do not bound device pulse widths, metastability, routing skew, physical reset capture or RAM commit behavior at an edge-near lock transition. Current immediate-write-suppression, abort, recovery, no-side-effect and ownership contracts, including `VGA-CDC-AC-05/09`, remain unchanged and unwaived. C09 dual-clock-memory qualification, ADC timing exceptions and external I/O closure are separate obligations; they are not deferred by this item.

Development/board observations within their existing bounded scope shall not be presented as proof of safe edge-near PLL loss. Any board-use or deployment claim requiring that guarantee remains unqualified until the future evidence and Owner acceptance exist; a zero diagnostic fault flag or a captured loss count cannot authorize such a claim.

Owner: the VGA/clock-reset specification maintainer, with the board owner responsible for physical execution and acceptance. Re-entry is required before a physical lock-loss safety claim, on relevant clock/reset/PLL/M9K configuration or write-commit changes, or on an observed lock-loss anomaly. A demonstrated active safety defect requires corrective/restricted-use review immediately, not routine deferral.

Future acceptance requires an exact source/IP/bitstream/board binding; primary MAX10/ALTPLL/M9K pulse, reset and write-edge contracts; applicable timing/RDC and reset-branch/diagnostic-capture coverage with explicit NOT_ANALYZABLE gaps; and targeted physical evidence where those contracts or analyses cannot establish the guarantee. Physical stimulus must be independently observed with respect to clock/write edges, not inferred from the diagnostic counter. Owner review must resolve every remaining assumption before a safety claim; an unclosed case remains NOT_VERIFIED.

The [cleanup exit gate](baseline_cleanup.md#3-cleanup-exit-gate) still requires every BC High/Blocker item VERIFIED. `CDC-001 OPEN`, `VER-003 OPEN`, `STA-001 IN_PROGRESS`, `STA-002 BLOCKED` and `VGA-CDC-AC-09 BLOCK / NOT_VERIFIED` are preserved. No BC row, gate taxonomy, reset specification or release checklist is relaxed. See [C08 deferred obligation](baseline_cleanup.md#23a-c08-physical-assurance-obligation).

Preserve the owner-authorized uncommitted C09 `rd_aclr(1'b0)` binding; this amendment changes no read latency, bank isolation, reset/recovery or first-visible-pixel contract. C09 physical primitive behavior remains separate P12 device/physical work.

Proposed follow-up, outside this amendment: reconcile the historical W1C summary and legacy VGA link in [memory map](01_memory_map.md), legacy clear terminology in [firmware contract](19_firmware_contract.md), and future diagnostic reporting in [Health firmware contract](22_soc_health_firmware.md). Memory-map address/width ownership is unchanged; those documents delegate detailed peripheral semantics to this owning spec. This amendment adds only the C08 physical-obligation scope note to the tracker; driver, Health qualification and evidence acceptance are unchanged.

| Item | Status | Boundary |
|---|---|---|
| `CDC-001` | OPEN | This specification defines the normative request/commit/ACK/ownership/recovery contract; later implementation, independent behavioral DV, and structural CDC review remain required. |
| `STA-001` | IN_PROGRESS | Internal STA is SCOPED_PASS only, not full closure. |
| `STA-002` | BLOCKED | External I/O/electrical timing has no complete peer/board closure. |
| VGA/ADC warnings | OPEN | Critical proximity warnings require explicit disposition. |
| `RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT` | known risk | Not a verified safe firmware trap interval. |
| Programmer/JTAG binding | unavailable | No independent SOF-to-board binding was captured. |

### 7.2 Bounded assurance proposal — not an active exception

> **PROPOSED / NOT_ACCEPTED:** Retain the existing RTL and all active behavior. This proposal documents claim limits; it grants no physical safety waiver.

`C08-PHYS-001` has one canonical record in the [assurance limitation register](physical_assurance_limitations.md#c08-phys-001); §7.1 retains its accepted scheduling and claim boundary. Its physical state is `NOT_PROVEN`, and its exception request is `PROPOSED / NOT_ACCEPTED`. Essential R1/R2 dependencies of AC09 cannot enter the proposed supplemental-claim exception route in [cleanup §3.1](baseline_cleanup.md#31-proposed-limited-assurance-disposition).

A limited internal engineering checkpoint may describe the existing conditional functional evidence and all residual blockers. It is not Clean Baseline v1 release, deployment safety certification, AC09 acceptance or permission to advance a stable PLIC/AXI stage. A narrowed required-event class or any incompatible reset/startup assumption requires a separate frozen-contract decision before adoption; it cannot be introduced by an exception record.


## 8. Traceability

- Tracker: [`baseline_cleanup.md`](baseline_cleanup.md) and [Korean tracker](kor/baseline_cleanup.ko.md)
- Active RTL: [`pre_fetch_AHB_VRAM_DUAL_BUFFER.v`](../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v), [`HW_Cleaner.v`](../rtl/video/vram/HW_Cleaner.v), [`VGA_SyncGen.v`](../rtl/video/vga/VGA_SyncGen.v)
- Firmware: [`vram.h`](../firmware/include/vram.h), [`vram.c`](../firmware/drivers/vram.c)
- Directed verification: [`tb_p08b_vga.sv`](../verification/directed/vga/tb_p08b_vga.sv), [`tb_p08b_vga_state_matrix.sv`](../verification/directed/vga/tb_p08b_vga_state_matrix.sv), [`tb_p08b_vga_atomicity_matrix.sv`](../verification/directed/vga/tb_p08b_vga_atomicity_matrix.sv), [`tb_p08b_vga_cpu_fault.sv`](../verification/directed/vga/tb_p08b_vga_cpu_fault.sv)
- Case and evidence: [CS-009](../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md), [P08B-VGA-EV-01](../reports/evidence/vga-hwclear/summary.md)

## Appendix A. Historical / Pre-cleanup Notes

Earlier baseline text described broad local aliases, fixed OKAY/ready behavior, immediate HCLK swap/direct live bank selection, a live clear-bank selection, level-style clear completion, and no hardware-clear board evidence. Those descriptions are historical only; they must not be used as the current contract. The active request/commit/ACK ownership protocol and P05 lock-qualified reset architecture supersede the direct-selector description. The retained architecture/geometry/timing facts were reconciled into Sections 2 and 3; engineering alternatives are in CS-009.
