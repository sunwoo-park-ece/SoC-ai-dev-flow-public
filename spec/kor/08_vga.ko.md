# P08B VGA / VRAM 명세

> **상태:** 현재 VGA / VRAM 계약. Owner가 승인한 P08B 기능 범위는 VERIFIED prerequisite이고 `CDC-001`은 이후 implementation, independent behavioral DV, structural CDC review가 accepted되기 전까지 OPEN이다. 영문 [`../08_vga.md`](../08_vga.md)가 정본이며 이 문서는 숫자·비트·접근·상태·기준을 의미 동기화한다.
>
> **검토 소스 앵커:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. 기능 범위 승인이지 릴리스, CDC, 전체 타이밍 sign-off 선언이 아니다.

## 1. Status and Scope

활성 디스플레이 주변장치는 `AMBA_SoC_TOP`의 AHB-side `AHB_VRAM_DUAL_BUFFER`다. 휴면 `APB_VGA_Top`은 활성 인터페이스가 아니다. 범위는 canonical AHB 접근, 이중 버퍼 소유권, hardware clear, VGA scanout, firmware-visible status/control 계약이다.

`VGA-001..006`은 동결 기능 범위에서 VERIFIED 및 owner accepted다. `RST-002`는 VERIFIED reset/PLL-lock prerequisite다. `VGA-007`과 `CDC-001`은 OPEN이며 downstream async-clock/reset verification의 `VER-003`도 OPEN이다. full STA(`STA-001`), external I/O timing(`STA-002`), VGA/ADC warning 처분, pre-`mtvec` reset window, 독립 programmer/JTAG image-to-board binding은 P08B 판정 밖이며 이번 spec authoring으로 status를 승격하지 않는다.

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

`front_bank_p`는 pixel-domain 표시 선택이고 `front_bank_h`는 valid operational epoch 동안 acknowledged swap commit 뒤에만 재구성되는 HCLK-domain ownership view다. reset/recovery rebase는 명시적인 architectural exception이며 VRAM0-front/VRAM1-back으로 정한다. CPU write는 HCLK back bank만, cleaner는 clear 시작 때 래치한 target bank만 사용한다.

규범적인 cross-domain request는 임의의 multi-bit payload가 아니라 **swap-request epoch**이다. `SWAP=1`이 포함된 accepted command마다 logical swap request를 정확히 한 번 발행하고 clear-only command는 pixel ownership request를 발행하지 않는다. 이 request를 내부에서 encode/qualify하는 구현 signal 자체는 software-visible contract가 아니며 이후 structural CDC review 대상이다.

### 2.2 Geometry, storage, pixel

visible framebuffer는 640 x 480 x 1 bpp = 307,200 bit = 38,400 byte = 9,600개의 32-bit word다. 한 줄은 20 word이며 visible coordinate는 다음과 같다.

```text
word_index = y * 20 + (x >> 5)       (0 <= x < 640, 0 <= y < 480)
bit_index  = x & 31
```

32-pixel word의 leftmost pixel은 bit 0이고 X가 증가하면 bit position도 증가한다. video active 및 display armed일 때 0은 black(`R=G=B=0`), 1은 white(`R=G=B=0xF`)다.

각 physical RAM은 HCLK write view 16,384 x 32-bit와 pclk read view 524,288 x 1-bit를 갖는다. word 0..9599 / bit 0..307199만 visible architectural storage이고 나머지는 reserved이며 software addressable하지 않다. synchronous prefetch는 구현 interface constraint이므로 firmware는 prefetch counter가 아닌 X/Y 또는 word coordinate를 사용해야 한다.

### 2.3 Operation과 bank transition

**Operation request acceptance**는 aligned/supported `VRAM_CONTROL` write가 `HREADY_IN`으로 completion이 qualify된 final-OKAY data phase에 도달하고, VGA domain acceptance 조건이 여전히 유효하며, `DOMAIN_READY=1`, `OP_BUSY=0`, command bit `[1:0] != 0`일 때만 성립한다. command bit가 zero인 final-OKAY CONTROL write는 정상 bus write지만 **operation request는 아니다**.

outstanding operation은 하나뿐이다. nonzero command 수락 시 operation이 시작되고 `OP_BUSY=1`이 된다. operation completion 또는 abort/reset 전까지 뒤의 framebuffer write나 nonzero CONTROL request는 수락할 수 없다. STATUS read/W1C는 operation이 아니며 별도 access policy를 유지한다.

`SWAP=1` operation은 HCLK에서 pixel domain으로 logical swap-request epoch를 정확히 한 번 publish한다. pixel domain은 synchronization 뒤 request를 pending으로 둘 수 있지만 **ownership commit**은 pre-edge timing state가 `(h_cnt,v_cnt)=(799,524)`이고 그 `pclk_25` edge에서 `front_bank_p`가 정확히 한 번 toggle되며 frame counter가 `(0,0)`으로 wrap하는 시점뿐이다. prefetch reset `(798,524)`은 ownership commit이 아니다.

돌아오는 ACK는 request receipt가 아니라 **완료된 pixel-domain ownership commit**을 acknowledge한다. pixel domain은 `front_bank_p` commit 이전에 성공 ACK를 publish하면 안 되며 clear-only operation은 swap ACK가 필요 없다. ACK가 HCLK로 synchronize된 뒤 outstanding swap-bearing operation의 첫 ACK event를 consume할 때만 `front_bank_h`가 정확히 한 번 갱신된다. pixel commit과 HCLK reconstruction 사이에 latency가 생길 수 있으나 이 구간에는 `OP_BUSY=1`이므로 CPU framebuffer write가 차단되어 displayed bank가 writable로 노출되지 않는다.

아래 successful completion rule은 completion까지 동일 recovery epoch에서 valid하게 유지되는 accepted operation에 적용된다. Cancellation/abort는 Section 2.4를 따르며 acceptance 자체가 successful commit이나 `OP_DONE`을 보장하지 않는다.

| 수락 명령 | Pixel-domain ownership 동작 | Successful overall completion / `OP_DONE` |
|---|---|---|
| `SWAP` | swap request 1회 publish, frame wrap에서 `front_bank_p` 1회 commit, post-commit ACK 1회 반환 | synchronized ACK consume 및 `front_bank_h` update 뒤 `OP_BUSY` clear, sticky `OP_DONE` set |
| `HW_CLEAR` | 없음; displayed front 불변 | acceptance 때 current writable back bank를 latch, word 0..9599 clear, physical word-9599 zero write commit 뒤 `OP_BUSY` clear 및 sticky `OP_DONE` set |
| `SWAP | HW_CLEAR` | `SWAP`과 같은 request/commit/ACK sequence | ACK consume 및 `front_bank_h` update 뒤 old front/new back을 clear target으로 latch, `OP_BUSY=1` 유지, final clear-word commit 뒤에만 `OP_DONE` set |
| command bit `[1:0]==0` | 없음 | no operation; 해당 write는 `OP_BUSY`, request, clear, ACK, `OP_DONE`을 만들지 않음 |

overlap framebuffer/control request, domain not-ready의 framebuffer/control request, data phase에서 거절된 request는 ERROR다. 거절 framebuffer request는 VRAM word write 0회, 거절 control request는 command issue 0회다. accepted operation은 displayed front bank를 쓰면 안 된다.

### 2.4 Reset, PLL lock loss, abort semantics

pixel reset request는 `HRESETn & vga_pll_locked`이고 `pclk_25`의 `reset_release_sync`를 통해서만 해제된다. system reset 또는 PLL lock loss는 현재 pixel-domain ownership epoch를 무효화하고 pixel-domain pending swap/display-arming state를 clear한다.

**System reset과 PLL lock loss의 software-visible abort semantics는 다르다.**

- **System reset (`HRESETn=0`)**은 VGA HCLK/pixel state reset의 일부로 in-flight operation을 취소한다. `OP_DONE`, `OP_ABORT`를 포함한 sticky status도 reset되므로 software는 pre-reset abort event가 reset 이후 남아 있기를 요구하면 안 된다.
- **System reset은 유지된 채 PLL lock이 loss**되면 raw lock이 physical VRAM write를 즉시 gate하고 pixel reset을 reassert한다. recovery가 HCLK에서 인식되면 `DOMAIN_READY`가 내려가고 active operation을 취소하며 active operation이 있었다면 sticky `OP_ABORT`를 set한다. aborted operation은 이후 `OP_DONE`을 만들면 안 된다.

System reset 또는 PLL lock loss가 pixel ownership commit 전에 swap-bearing operation을 취소하면 해당 canceled operation의 required ownership commit은 0회이며(commit 발생 금지), successful ACK도 0회이고 `OP_DONE`도 없다. HCLK state가 살아 있는 PLL-loss abort는 `OP_ABORT`를 사용하며 full system reset은 old operation/status epoch를 clear한다. 이미 physical effect가 commit된 뒤 취소되면 그 effect를 소급해서 undo하지 않지만 canceled operation이 이후 successful overall completion이나 `OP_DONE`을 만들 수는 없다.

두 경우 모두 새 framebuffer/control acceptance 전에 ownership을 VRAM0-front / VRAM1-back으로 rebase한다. 이 reset/recovery rebase는 swap ACK 없이 `front_bank_h`를 변경할 수 있는 명시적 예외이며 successful swap completion이 아니다. framebuffer content는 architectural reset-clear 보장이 아니다. pixel reset이 display arming을 clear하므로 이후 성공한 swap이 display를 다시 arm할 때까지 output은 black이다.

### 2.5 Recovery epoch, stale-event suppression, liveness

`DOMAIN_READY`는 **현재** post-reset/post-lock-loss pixel ownership epoch가 recovery를 완료했다는 live 의미이며 raw PLL lock의 alias가 아니다.

`DOMAIN_READY=1` 전에는 다음이 모두 성립해야 한다.

1. system reset이 release되고 PLL lock이 valid다.
2. pixel domain이 새 epoch의 reset state를 실제로 거친 뒤 ready state에 도달했다.
3. HCLK ownership은 VRAM0-front / VRAM1-back으로 rebase됐다.
4. request/ACK observation baseline을 rebase하여 pre-recovery request, ACK, stale ready level이 새 transaction으로 해석되지 않는다.

`DOMAIN_READY=0` 동안 새 framebuffer write와 nonzero CONTROL operation은 reject되어 physical VRAM write나 command side effect를 만들 수 없다. recovery 후 `DOMAIN_READY=1`, `OP_BUSY=0`이 되면 다음 valid operation이 successful completion까지 그 recovery epoch에서 valid하게 유지된다면 post-recovery state만으로 completion할 수 있어야 하며 pre-reset/pre-lock-loss toggle, ACK, pending request에 forward progress를 의존하면 안 된다.


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

address acceptance는 data-phase bus acceptance가 아니며 bus acceptance도 이후 operation completion과 다르다. framebuffer/control write는 data phase에서 raw PLL lock, synchronized readiness, idle ownership을 다시 확인한다. framebuffer transfer의 final OKAY는 writable back bank physical word write 정확히 1회이고 pre-acceptance ERROR는 0회다. control transfer의 final OKAY는 register-command acceptance 정확히 1회이지 즉시 VRAM word write가 아니다. swap ack와 cleaner write는 이후 발생한다. 완료된 effect는 rollback/repeat하지 않는다. 이는 functional atomicity 계약이지 static CDC/metastability sign-off가 아니다.

misaligned CPU instruction은 CPU pre-bus misalignment path(store cause 6)를 사용한다. invalid size/alignment direct bus transaction은 local two-cycle ERROR다. terminal rejected VGA store는 firmware retry 결과가 아니라 faulting operation이다.

### 3.2 Status register: `VRAM_STATUS` (`0x2001_0000`)

| Bit | Name | Access | 의미 |
|---:|---|---|---|
| 0 | `VSYNC_EVENT` | RO / W1C | active-low `VGA_VS`의 synchronized rising/deassertion edge에 대한 sticky HCLK event |
| 1 | `OP_DONE` | RO / W1C | sticky **successful overall operation** completion만 의미: swap-only는 post-ACK HCLK ownership reconstruction 뒤, clear-only/combined는 final clear-word commit 뒤. aborted operation은 set 금지 |
| 2 | `OP_BUSY` | RO | accepted nonzero CONTROL request부터 overall completion, PLL-loss abort 또는 system reset까지의 live one-outstanding-operation state |
| 3 | `OP_ABORT` | RO / W1C | HCLK state가 살아 있는 동안 PLL-domain invalidation이 active operation을 종료했을 때 sticky abort. full system reset은 다른 status와 함께 clear |
| 4 | `DOMAIN_READY` | RO | current recovery epoch가 확립되어 framebuffer/nonzero CONTROL acceptance 재개 가능. raw PLL lock 자체가 아님 |
| 31:5 | reserved | RO / W1C ignored | read zero, write effect 없음 |

1을 쓰면 각각 bit 0, 1, 3만 clear하며 0 write는 clear하지 않는다. W1C 처리가 hardware event update보다 먼저여서 coincident event는 set-dominant다. reset은 sticky event를 clear한다. `OP_BUSY`와 `DOMAIN_READY`는 live이며 W1C state가 아니다.

STATUS access는 framebuffer/control readiness rejection gate를 사용하지 않는다. 따라서 aligned status read/W1C write는 `OP_BUSY=1` 또는 `DOMAIN_READY=0`에서도 수락될 수 있다. 수락된 W1C bus write는 선택 event acknowledge만 수행하며 VRAM word write가 아니다.

### 3.3 Control register: `VRAM_CONTROL` (`0x2001_0004`)

| Bit | Name | Access | 의미 |
|---:|---|---|---|
| 0 | `SWAP` | WO command | frame-boundary ownership swap request |
| 1 | `HW_CLEAR` | WO command | Section 2.3의 clear request |
| 31:2 | reserved | WO | ignored; operation을 만들지 않음 |

register는 command state를 저장하지 않고 read contract도 없다. 지원 write는 data phase에서 한 번 수락된다. `[1:0]==0`이면 reserved bit만 포함한 값도 operation effect가 없다. command bit 중 하나가 1이면 수락이 operation을 한 번 발행하고 해당 state를 set한다. completion은 뒤의 frame-wrap ack 및/또는 cleaner word 9599 이후다. nonzero command는 `DOMAIN_READY=1`이고 `OP_BUSY=0`일 때만 수락되며 아니면 ERROR다.

### 3.4 Firmware API와 사용 계약

동결 driver는 아래 bounded interface를 제공한다. 아래 `OK`, `TIMEOUT`, `NOT_READY`, `BUSY`, `ABORTED`는 대응하는 `VRAM_RESULT_*` enum 값이다. 이 함수들은 invalid 또는 race-lost MMIO가 만드는 CPU bus trap을 catch하지 않는다. 반환값은 status 관측과 direct MMIO 이전 precheck만 나타낸다.

| Function | 인수와 동작 | 반환 / 제한 |
|---|---|---|
| `vram_status()` | aligned STATUS read | raw 32-bit status 반환 |
| `vram_clear_events(mask)` | `mask & (VSYNC_EVENT | OP_DONE | OP_ABORT)`만 W1C STATUS write | `void`; BUSY/READY 및 unselected event를 ack하지 않음 |
| `vram_wait_ready(poll_budget)` | 최대 `poll_budget` read 동안 `DOMAIN_READY=1` polling | `OK` 또는 `TIMEOUT` |
| `vram_wait_vsync(poll_budget)` | poll마다 `OP_ABORT`, not-ready, `VSYNC_EVENT` 순서 확인 | `ABORTED`, `NOT_READY`, `OK`, `TIMEOUT` |
| `vram_start_operation(command)` | command를 `SWAP|HW_CLEAR`로 mask; READY 후 BUSY precheck; zero는 no-op. nonzero이면 stale DONE/ABORT를 clear하고 CONTROL direct write | `NOT_READY`, `BUSY`, `OK`; `OK`는 이후 MMIO race fault 부재나 operation completion 증명이 아님 |
| `vram_wait_operation(poll_budget)` | poll마다 `OP_ABORT`, not-ready, `OP_DONE` 순서 확인 | `ABORTED`, `NOT_READY`, `OK`, `TIMEOUT` |
| `vram_write_word(word_offset,value)` | `VRAM_BASE + 4*word_offset` direct write | `void`; bounds/readiness/ownership check와 trap recovery 없음. caller가 writable-back 조건과 `0..9599` 보장 |

normal production sequence는 bounded다. READY 대기, aligned word로 back bank render, stale VSYNC W1C, VSYNC 대기, `vram_start_operation(SWAP|HW_CLEAR)` 호출(먼저 stale DONE/ABORT W1C), `OP_DONE` 또는 bounded failure 대기 순서다. API result는 hardware access-fault contract를 대신하지 않는다. standalone display-smoke diagnostic은 다른 test sequence를 쓸 수 있다. Evidence가 별도로 식별한 board-diagnostic source는 frozen source anchor에 포함되지 않으며 이 production 계약을 재정의할 수 없다.

### 3.5 VGA timing과 scanout constraint

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
| canonical, ready, idle framebuffer write | final OKAY data-phase acceptance 1회 | HCLK back-bank word write 정확히 1회; front write/held-phase duplicate 없음 |
| accepted STATUS W1C write | final OKAY와 선택 event ack | VRAM word write 없음; unrelated/live field 불변 |
| accepted nonzero CONTROL write | final OKAY와 command issue 정확히 1회 | 즉시 VRAM word write 없음; 이후 operation/ack/clear/`OP_DONE`은 별개 |
| command `[1:0]==0` CONTROL write | final OKAY와 no operation | reserved bit 무시; request/clear/VRAM write 없음 |
| unsupported address/direction/size/alignment | two-cycle ERROR | VRAM write, status mutation, command issue 없음 |
| busy/not-ready framebuffer/control request | two-cycle ERROR | cleaner target, request toggle, command issue, CPU write 변화 없음 |
| framebuffer/control data-phase acceptance 전 PLL loss | two-cycle ERROR | 해당 transaction framebuffer write/control command issue 없음 |
| active operation 중 PLL loss | abort/recovery와 `OP_ABORT` sticky | lock loss 뒤 clear write 지속 없음 |

- canonical aligned word framebuffer write만 visible framebuffer storage를 바꿀 수 있다.
- clear target은 시작 후 immutable이며 주소 0..9599를 permitted HCLK edge마다 정확히 한 zero word로 쓴다.
- swap은 frame wrap에서만 보이고 combined clear는 새 displayed front를 target으로 하지 않는다.
- sticky event는 자기 W1C 전까지 보이며 unrelated W1C가 지우지 않는다.
- final OKAY framebuffer write는 physical back-bank word commit 정확히 1회, ERROR completion은 0회다.
- final OKAY control write는 accepted register write 1회다. nonzero command bit만 operation을 발행하며 이후 swap/clear effect와 completion event는 bus acceptance와 별개다.
- accepted STATUS W1C는 선택 sticky event만 ack하고 framebuffer memory를 쓰지 않는다.
- protocol simulation/사진은 static CDC, full STA, physical timing, 모든 pixel value를 증명하지 않는다.
- accepted swap-bearing operation 하나는 pixel pending-swap transaction을 최대 하나, ownership commit을 최대 하나만 만든다.
- swap ACK는 해당 pixel-domain ownership commit보다 causal downstream이어야 하며 request receipt만으로 successful ACK를 만들 수 없다.
- Valid operational epoch 동안 `front_bank_h`는 현재 outstanding swap-bearing operation의 synchronized ACK를 HCLK가 consume할 때만 변경된다. Reset/recovery의 VRAM0-front ownership rebase는 명시적인 architectural exception이며 successful swap ACK가 필요 없다.
- CPU framebuffer write가 수락되는 모든 순간 writable bank는 non-displayed bank여야 한다. swap 중 ownership-view skew는 `OP_BUSY=1` 동안 framebuffer write가 차단되기 때문에만 허용된다.
- full system reset은 pre-reset operation/status epoch를 폐기하고, system reset 없는 PLL lock loss는 위의 sticky `OP_ABORT` 계약을 따른다.
- recovery는 stale request/ACK/ready state를 억제해야 하며 첫 valid post-recovery transaction이 forward progress할 수 있어야 한다.

## 5. Acceptance Criteria

| ID | Stable stimulus와 assertion | Pass condition |
|---|---|---|
| `VGA-AC-01` | canonical aperture boundary와 reserved gap exercise | canonical framebuffer/status/control 주소가 결정적으로 decode되고 gap/alias가 architectural access가 되지 않음 |
| `VGA-AC-02` | unsupported read/size/alignment와 unaccepted busy/not-ready traffic exercise | 각 request가 two-cycle ERROR, framebuffer/status/ownership/command side effect 없음 |
| `VGA-AC-03` | swap-only, clear-only, combined, overlap, ownership transition exercise | swap/clear ordering atomic, target latched, displayed front 보존, overlap reject |
| `VGA-AC-04` | VSYNC/DONE/ABORT set/clear/repeat/coincident 및 BUSY/READY 확인 | independent sticky W1C, deterministic/set-dominant ordering, live BUSY/READY |
| `VGA-AC-05` | known latched bank의 accepted clear를 시작하고 cleaner physical commit/address count | 해당 bank word 0..9599를 각각 한 번, 정확히 9,600 zero-word commit |
| `VGA-AC-06` | board standalone hardware-clear/swap screen sequence 관측 | bounded photo가 expected black/restored transition만 보임 |
| `VGA-AC-07` | board combined/no-write-swap sequence 관측 | bounded photo가 expected white/black/restored state만 보임 |
| `VGA-AC-08` | operator가 smoke sequence 반복 | stated bounded cycle까지 정상 동작 보고 |

이 ID는 `P08B-VGA-EV-01`과 함께 게시된 behavioral meaning을 보존하며 별도 held-phase 또는 lock-loss/reset matrix에 재할당하지 않는다. 그 matrix는 상세 current-contract 문장을 지원하지만 여기서 새 approved stable criterion으로 만들지 않는다. Run ID, 날짜, hash, raw log는 evidence만 보존한다. 사진은 AC-05 count, individual MMIO, CDC/STA, programmer identity를 증명하지 않는다.

### 5.1 VGA CDC / ownership Acceptance Criteria

기존 `VGA-AC-01..08`은 P08B 의미를 그대로 유지한다. 아래 criterion은 `CDC-001`의 추가 stable acceptance boundary이며 이후 verification에서 accepted evidence가 만들어지기 전까지 **OPEN**이다.

| ID | Stable assertion | Pass condition |
|---|---|---|
| `VGA-CDC-AC-01` | Operation acceptance / one-outstanding rule | final-OKAY nonzero CONTROL request마다 operation이 정확히 하나 생성되고 `OP_BUSY=1` 동안 두 번째 framebuffer/nonzero-CONTROL acceptance가 없음 |
| `VGA-CDC-AC-02` | Frame commit / ACK causality | Successful completion까지 동일 recovery epoch에서 valid하게 유지되는 accepted swap-bearing operation은 defined frame wrap에서 `front_bank_p`가 정확히 한 번 commit되고 그 commit 전 successful ACK가 없으며 orphan/duplicate ACK도 없음. Pre-commit reset/PLL-loss cancellation은 commit 0회, successful ACK 0회, `OP_DONE` 없음 |
| `VGA-CDC-AC-03` | HCLK ownership reconstruction | Successful completion까지 동일 recovery epoch에서 valid하게 유지되는 accepted swap은 해당 outstanding swap의 synchronized ACK 뒤에만 `front_bank_h`가 정확히 한 번 변경됨. Reset/recovery의 VRAM0-front rebase는 명시적인 ACK-free 예외. Accepted CPU write는 displayed pixel-domain front bank를 target하지 않음 |
| `VGA-CDC-AC-04` | Command-specific completion | Successful same-epoch completion만 해당: swap-only는 ACK consume/ownership reconstruction 뒤, clear-only는 final clear-word commit 뒤, combined는 ACK/reconstruction 이후 final clear-word commit 뒤에만 완료. Canceled/aborted operation은 `OP_DONE` 없음 |
| `VGA-CDC-AC-05` | Reset / lock-loss recovery | system reset은 old status/operation epoch를 폐기하고, PLL lock loss는 active operation을 abort하며 이후 DONE을 만들지 않고 VGA domain invalid 중 physical clear/CPU write가 지속되지 않음 |
| `VGA-CDC-AC-06` | Stale-event suppression | Pre-recovery request, ACK, pending-swap, ready state가 post-recovery transactional commit, ACK, `OP_DONE`, ownership update를 만들 수 없음. Required reset/recovery ownership rebase는 stale-event transaction이 아님 |
| `VGA-CDC-AC-07` | Recovery liveness | `DOMAIN_READY=1`과 idle 재확립 뒤 successful completion까지 그 recovery epoch에서 valid하게 유지되는 다음 valid operation이 pre-recovery toggle/state 의존 없이 완료 |
| `VGA-CDC-AC-08` | Functional async/reset DV boundary | independent behavioral verification이 arbitrary HCLK/pclk phase 및 reset/lock-loss overlap을 exercise하고 DUT ownership output에서 derive하지 않은 oracle로 request/commit/ACK/ownership identity, duplicate/loss, abort, liveness를 check |
| `VGA-CDC-AC-09` | Structural CDC boundary | 별도 structural/static CDC review가 protocol에 사용되는 모든 HCLK↔pixel crossing의 intentional synchronizer/handshake/dual-clock-memory mechanism과 bundled-control stability assumption을 명시적으로 확인 |

`VGA-CDC-AC-08`은 behavioral proof, `VGA-CDC-AC-09`는 structural CDC proof다. TimeQuest generated clock, recovery/removal, exception, slack review는 `STA-001`에 남으며 어느 criterion에서도 추론하지 않는다.

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

CDC/reset 관련 requirement state는 accepted P08B row와 별도로 유지한다.

| Requirement | 상태 | 의미 |
|---|---|---|
| `RST-002` | VERIFIED prerequisite | P05 reset/PLL-lock infrastructure가 accepted 상태이며 보존해야 함 |
| `CDC-001` | OPEN | 이 명세가 target protocol contract를 정의하지만 implementation/independent-DV/structural-CDC acceptance는 아직 미종결 |
| `VER-003` | OPEN | downstream async-clock/reset verification 필요 |
| `STA-001` | IN_PROGRESS | timing/exception closure는 별도 later gate |

현재 criterion-to-evidence mapping은 다음 compact 표로 유지한다.

| AC ID | Current result | Evidence class | Link |
|---|---|---|---|
| `VGA-AC-01` | PASS | same-RTL directed DV | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-02` | PASS | same-RTL directed DV | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-03` | PASS | same-RTL directed DV | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-04` | PASS | same-RTL DV plus firmware execution path | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-05` | PASS | same-RTL H05 exact-count DV | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-06` | PHOTO_OBSERVED | bounded cycle-0 board photographs | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-07` | PHOTO_OBSERVED | bounded cycle-0 board photographs | [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md) |
| `VGA-AC-08` | USER_ATTESTED | bounded operator report through cycle 5 | [P08B-VGA-EV-01 result](../../reports/evidence/vga-hwclear/result.json) |

## 7. Approved Target / Deferred Work

| Item | 상태 | 범위 |
|---|---|---|
| `CDC-001` | OPEN | 이 명세가 normative request/commit/ACK/ownership/recovery contract를 정의한다. 이후 implementation, independent behavioral DV, structural CDC review가 필요 |
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

과거 baseline에는 broad local alias, fixed OKAY/ready, immediate HCLK swap/direct live bank selection, live clear-bank target, level식 clear completion, hardware-clear board 미검증 문장이 있었다. 이는 historical only이며 현재 계약으로 쓰면 안 된다. 현재 request/commit/ACK ownership protocol과 P05 lock-qualified reset architecture가 direct-selector 설명을 대체한다. 보존할 architecture/geometry/timing 사실은 Section 2/3으로 재조정했고 engineering alternative는 CS-009에 있다.
