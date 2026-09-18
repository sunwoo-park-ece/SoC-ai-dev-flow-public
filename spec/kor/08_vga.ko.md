# P08B VGA / VRAM 명세

> **상태:** 동결 P08B 기능 범위의 현재 활성 계약. 영문 [`../08_vga.md`](../08_vga.md)가 정본이며 이 문서는 숫자·비트·접근·상태·기준을 의미 동기화한다.
>
> **검토 소스 앵커:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. 기능 범위 승인이지 릴리스, CDC, 전체 타이밍 sign-off 선언이 아니다.

## 1. Status and Scope

활성 디스플레이 주변장치는 `AMBA_SoC_TOP`의 AHB-side `AHB_VRAM_DUAL_BUFFER`다. 휴면 `APB_VGA_Top`은 활성 인터페이스가 아니다. 범위는 canonical AHB 접근, 이중 버퍼 소유권, hardware clear, VGA scanout, firmware-visible status/control 계약이다.

`VGA-001..006`은 동결 기능 범위에서 VERIFIED 및 owner accepted이고 `VGA-007`은 OPEN이다. static CDC(`CDC-001`), full STA(`STA-001`), external I/O timing(`STA-002`), VGA/ADC warning 처분, pre-`mtvec` reset window, 독립 programmer/JTAG image-to-board binding은 이 판정 밖이다.

서사는 [CS-009](../../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md), 실행 증적은 [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md)에 있다.

## 2. Current Active Contract

### 2.1 Architecture, clock, ownership

`CLOCK_50`은 `vga_pll`에 들어가 nominal `pclk_25`를 만들고 AHB control/write side는 50 MHz `HCLK`를 사용한다. `VGA_SyncGen`, prefetch, 두 mixed-width RAM의 read side는 pixel domain이고 CPU write, control/status, `HW_Cleaner`는 HCLK domain이다. 두 domain은 request/acknowledge toggle로 교환하며 live asynchronous bank selector가 소유권 인터페이스가 아니다.

```text
CPU / AHB (HCLK)                         Pixel domain (pclk_25)
  | canonical write, status/control           | timing + prefetch
  v                                            v
AHB_VRAM_DUAL_BUFFER --request toggle--> pending swap at frame wrap
  |  \                                       /        |
  |   +-- HW_Cleaner / write mux -----------+         +--> VGA RGB/HS/VS
  +--> VRAM0 / VRAM1 dual-clock storage <--- selected front-bank read port
```

`front_bank_p`는 표시 선택이고 `front_bank_h`는 동기화된 HCLK ownership view다. reset/recovery는 VRAM0-front/VRAM1-back으로 정한다. CPU write는 HCLK back bank만, cleaner는 clear 시작 때 래치한 target bank만 사용한다.

### 2.2 Geometry, storage, pixel

visible framebuffer는 640 x 480 x 1 bpp = 307,200 bit = 38,400 byte = 9,600개의 32-bit word다. 한 줄은 20 word이며 visible coordinate는 다음과 같다.

```text
word_index = y * 20 + (x >> 5)       (0 <= x < 640, 0 <= y < 480)
bit_index  = x & 31
```

32-pixel word의 leftmost pixel은 bit 0이고 X가 증가하면 bit position도 증가한다. video active 및 display armed일 때 0은 black(`R=G=B=0`), 1은 white(`R=G=B=0xF`)다.

각 physical RAM은 HCLK write view 16,384 x 32-bit와 pclk read view 524,288 x 1-bit를 갖는다. word 0..9599 / bit 0..307199만 visible architectural storage이고 나머지는 reserved이며 software addressable하지 않다. synchronous prefetch는 구현 interface constraint이므로 firmware는 prefetch counter가 아닌 X/Y 또는 word coordinate를 사용해야 한다.

### 2.3 Operation과 bank transition

outstanding operation은 하나뿐이다. nonzero `VRAM_CONTROL` command가 operation을 시작한다. swap request는 pixel domain으로 넘어가 `(h_cnt,v_cnt)=(799,524)`에서 `(0,0)`으로 wrap할 때만 commit하고 ack가 HCLK로 돌아온다.

| 수락 명령 | 완료 전 | 완료 및 ownership 결과 |
|---|---|---|
| `SWAP` | 현재 front를 계속 표시 | frame wrap에서 swap; old back이 front; ack 후 `OP_DONE` set |
| `HW_CLEAR` | 현재 front를 계속 표시 | current back을 래치하고 word 0..9599를 0으로 write; word 9599 commit 뒤 `OP_DONE` set |
| `SWAP | HW_CLEAR` | frame wrap 전에는 현재 front 표시 | 먼저 swap, old front/new back을 래치해 clear; 마지막 clear commit 뒤 `OP_DONE` set |
| zero command | 동작 없음 | firmware 정책상 no-op, state 변화 없음 |

overlap framebuffer/control request, domain not-ready request, data commit에서 거절된 request는 ERROR이며 operation/write side effect가 없다. operation busy 동안 CPU framebuffer write는 배제된다. 어떤 operation도 표시 중 front bank를 변경하면 안 된다.

### 2.4 Reset, lock loss, display gating

pixel reset은 `HRESETn & vga_pll_locked`에서 `reset_release_sync`를 거쳐 해제된다. 동기화된 HCLK lock view가 low이면 `DOMAIN_READY=0`, ownership/recovery는 VRAM0-front로 rebase, pending request는 버리고 active operation은 `OP_ABORT`를 set한다. raw PLL lock은 모든 physical VRAM write도 gate한다. 이후 pixel readiness handshake가 완료되어야 새 command나 framebuffer write가 수락된다.

post-reset/recovery 첫 출력은 display armed가 clear되어 black이다. 성공한 swap이 display를 arm한다. framebuffer memory는 architectural reset-clear 보장이 없으므로 blank가 필요하면 ready 뒤 firmware render 또는 수락된 clear가 필요하다.

## 3. Interface / Register / Timing Contract

### 3.1 Canonical address와 AHB access

| 주소 또는 범위 | 접근 | 계약 |
|---|---|---|
| `0x2000_0000`–`0x2000_95FF` | aligned 32-bit write only | current back-buffer word 0..9599 |
| `0x2000_9600`–`0x2000_FFFF` | none | reserved gap |
| `0x2001_0000` | aligned 32-bit read / W1C write | `VRAM_STATUS` |
| `0x2001_0004` | aligned 32-bit write only | `VRAM_CONTROL` |
| 그 외 VGA-local 주소, framebuffer read, subword/misaligned 접근, CONTROL read | ERROR | physical write, event clear, operation start 없음 |

target은 address phase를 `HSEL && HTRANS[1]`로 qualify하고 다음 data phase에 address/control을 capture하며 `HREADY_IN`을 global completion qualifier로 쓴다. 정상 지원 transaction은 `HRESP=OKAY`, `HREADY=1`이다. 거절 transaction은 project two-cycle error(`HRESP=ERROR,HREADY=0`, 다음 `HRESP=ERROR,HREADY=1`)다. held data phase는 duplicate commit을 만들지 않는다.

address acceptance는 physical write completion이 아니다. framebuffer/control write는 data commit에서 raw PLL lock, synchronized readiness, idle ownership을 다시 확인한다. commit 전 loss는 zero physical write ERROR가 되며 이미 final OKAY로 commit한 write는 rollback/repeat하지 않는다. 이는 functional atomicity 계약이지 static CDC/metastability sign-off가 아니다.

misaligned CPU instruction은 CPU pre-bus misalignment path(store cause 6)를 사용한다. invalid size/alignment direct bus transaction은 local two-cycle ERROR다. terminal rejected VGA store는 firmware retry 결과가 아니라 faulting operation이다.

### 3.2 Status register: `VRAM_STATUS` (`0x2001_0000`)

| Bit | Name | Access | 의미 |
|---:|---|---|---|
| 0 | `VSYNC_EVENT` | RO / W1C | active-low `VGA_VS`의 synchronized rising/deassertion edge에 대한 sticky HCLK event |
| 1 | `OP_DONE` | RO / W1C | swap acknowledgement 또는 final clear-word commit 뒤 sticky completion |
| 2 | `OP_BUSY` | RO | live one-outstanding-operation state |
| 3 | `OP_ABORT` | RO / W1C | active operation의 lock-loss abort sticky event |
| 4 | `DOMAIN_READY` | RO | pixel/ownership recovery handshake complete |
| 31:5 | reserved | RO / W1C ignored | read zero, write effect 없음 |

1을 쓰면 각각 bit 0, 1, 3만 clear하며 0 write는 clear하지 않는다. W1C 처리가 hardware event update보다 먼저여서 coincident event는 set-dominant다. reset은 sticky event를 clear한다. `OP_BUSY`와 `DOMAIN_READY`는 live이며 W1C state가 아니다.

### 3.3 Control register: `VRAM_CONTROL` (`0x2001_0004`)

| Bit | Name | Access | 의미 |
|---:|---|---|---|
| 0 | `SWAP` | WO command | frame-boundary ownership swap request |
| 1 | `HW_CLEAR` | WO command | Section 2.3의 clear request |
| 31:2 | reserved | WO | ignored; operation을 만들지 않음 |

register는 command state를 저장하지 않고 read contract도 없다. `[1:0]==0` command는 operation을 만들지 않는다. nonzero command는 `DOMAIN_READY=1`이고 `OP_BUSY=0`일 때만 수락되며 아니면 ERROR다.

### 3.4 VGA timing과 scanout constraint

| Horizontal segment | Pixel | Vertical segment | Line |
|---|---:|---|---:|
| visible | 640 | visible | 480 |
| front porch | 16 | front porch | 10 |
| sync pulse | 96 | sync pulse | 2 |
| back porch | 48 | back porch | 33 |
| total | 800 | total | 525 |

`VGA_HS`, `VGA_VS`는 active-low다. nominal 25 MHz pclk에서 nominal frame rate는 약 59.52 Hz다. timing generator가 800 x 525 counter를 정하며 ownership swap boundary는 prefetch reset `(798,524)`과 독립된 정확한 `(799,524)->(0,0)` wrap이다. full generated-clock/board timing closure는 주장하지 않는다.

## 4. Invariants and Error Behavior

| 원인 | 필수 응답 | 없어야 할 side effect |
|---|---|---|
| canonical, ready, idle framebuffer write | HCLK back bank에 한 번 final OKAY commit | front write 또는 held `HREADY_IN` duplicate 없음 |
| unsupported address/direction/size/alignment | two-cycle ERROR | VRAM write, status mutation, operation 없음 |
| busy/not-ready framebuffer/control request | two-cycle ERROR | cleaner target, request toggle, CPU write 변화 없음 |
| data commit 전 PLL loss | two-cycle ERROR | 해당 transaction physical write 없음 |
| active operation 중 PLL loss | abort/recovery와 `OP_ABORT` sticky | lock loss 뒤 clear write 지속 없음 |

- canonical aligned word framebuffer write만 visible framebuffer storage를 바꿀 수 있다.
- clear target은 시작 후 immutable이며 주소 0..9599를 permitted HCLK edge마다 정확히 한 zero word로 쓴다.
- swap은 frame wrap에서만 보이고 combined clear는 새 displayed front를 target으로 하지 않는다.
- sticky event는 자기 W1C 전까지 보이며 unrelated W1C가 지우지 않는다.
- final OKAY framebuffer/control write는 한 physical commit, pre-commit ERROR는 zero commit에 대응한다.
- protocol simulation/사진은 static CDC, full STA, physical timing, 모든 pixel value를 증명하지 않는다.

## 5. Acceptance Criteria

| ID | Stimulus와 assertion | Pass condition |
|---|---|---|
| `VGA-AC-01` | canonical framebuffer/status/control과 gap/alias/read/subword/invalid access exercise | canonical 결과; invalid마다 two-cycle ERROR와 no side effect |
| `VGA-AC-02` | held data phase, ready/lock boundary, consecutive request | final OKAY exactly-once commit; ERROR/held phase no commit; pre-commit loss false OKAY 없음 |
| `VGA-AC-03` | swap-only, clear-only, combined, overlap, repeated command | frame-wrap swap, latched target, 0..9599, exact 9,600 clear, rejected overlap |
| `VGA-AC-04` | 각 W1C event set/clear/repeat/coincident test | VSYNC/DONE/ABORT independent sticky W1C set-dominant; BUSY/READY live |
| `VGA-AC-05` | idle/pending/clear/combined/ack-window/reset-adjacent PLL loss injection | write stop, one abort, safe ownership/black recovery, ready 후 new operation |
| `VGA-AC-06` | board에서 standalone clear/swap screen sequence 관측 | bounded photo가 expected black/restored transition만 보임 |
| `VGA-AC-07` | board에서 combined/no-write-swap sequence 관측 | bounded photo가 expected white/black/restored state만 보임 |
| `VGA-AC-08` | operator가 smoke sequence 반복 | operator가 stated bounded cycle까지 정상 동작 보고 |

criterion은 안정적인 검증 규칙이다. Run ID, 날짜, hash, raw log는 evidence만 보존한다.

## 6. Current Requirement Status

| Requirement | 상태 | Compact basis |
|---|---|---|
| `VGA-001` | VERIFIED functional scope | canonical decode/boundary/error directed verification |
| `VGA-002` | VERIFIED functional scope | aligned write-only, no read/subword side effect, firmware interface review |
| `VGA-003` | VERIFIED functional scope | ownership/contention/error/no-side-effect/CPU-fault verification |
| `VGA-004` | VERIFIED functional scope | target latch, clear-only, combined, overlap, range/count verification |
| `VGA-005` | VERIFIED functional scope | sticky W1C ordering/collision과 firmware control path |
| `VGA-006` | VERIFIED functional scope | same-RTL exact-count DV와 bounded board-visible smoke |
| `VGA-007` | OPEN | dormant APB VGA source disposition |

Historical evidence summary: `P08B-VGA-EV-01`은 AC-01..05 DV PASS, AC-06..07 photo observation, AC-08 user attestation을 분리한다. [summary](../../reports/evidence/vga-hwclear/summary.md)와 [result](../../reports/evidence/vga-hwclear/result.json)를 참조한다.

## 7. Approved Target / Deferred Work

| Item | 상태 | 범위 |
|---|---|---|
| `CDC-001` | NOT_RUN / unresolved | functional request/ack test는 static CDC sign-off가 아님 |
| `STA-001` | IN_PROGRESS | internal STA는 SCOPED_PASS 한정 |
| `STA-002` | BLOCKED | external I/O/electrical timing peer/board closure 없음 |
| VGA/ADC warnings | OPEN | critical proximity warning 명시 처분 필요 |
| `RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT` | known risk | verified safe firmware trap interval이 아님 |
| Programmer/JTAG binding | unavailable | independent SOF-to-board binding 미수집 |

## 8. Traceability

- Tracker: [`../baseline_cleanup.md`](../baseline_cleanup.md), [Korean tracker](baseline_cleanup.ko.md)
- Active RTL: [`pre_fetch_AHB_VRAM_DUAL_BUFFER.v`](../../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v), [`HW_Cleaner.v`](../../rtl/video/vram/HW_Cleaner.v), [`VGA_SyncGen.v`](../../rtl/video/vga/VGA_SyncGen.v)
- Firmware: [`vram.h`](../../firmware/include/vram.h), [`vram.c`](../../firmware/drivers/vram.c)
- Directed verification: [`tb_p08b_vga.sv`](../../verification/directed/vga/tb_p08b_vga.sv), [`tb_p08b_vga_state_matrix.sv`](../../verification/directed/vga/tb_p08b_vga_state_matrix.sv), [`tb_p08b_vga_atomicity_matrix.sv`](../../verification/directed/vga/tb_p08b_vga_atomicity_matrix.sv), [`tb_p08b_vga_cpu_fault.sv`](../../verification/directed/vga/tb_p08b_vga_cpu_fault.sv)
- Case/evidence: [CS-009](../../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md), [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md)

## Appendix A. Historical / Pre-cleanup Notes

과거 baseline에는 broad local alias, fixed OKAY/ready, immediate HCLK swap, live clear-bank target, level식 clear completion, hardware-clear board 미검증 문장이 있었다. 이는 historical only이며 현재 계약으로 쓰면 안 된다. 보존할 architecture/geometry/timing 사실은 Section 2/3으로 재조정했고 engineering alternative는 CS-009에 있다.
