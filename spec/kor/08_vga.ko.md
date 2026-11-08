# P08B VGA / VRAM 명세

> **상태:** 현재 VGA / VRAM 계약. Owner가 승인한 P08B 기능 범위는 VERIFIED prerequisite이고 `CDC-001`은 이후 implementation, independent behavioral DV, structural CDC review가 accepted되기 전까지 OPEN이다. 영문 [`../08_vga.md`](../08_vga.md)가 정본이며 이 문서는 숫자·비트·접근·상태·기준을 의미 동기화한다.
>
> **검토 소스 앵커:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. 기능 범위 승인이지 릴리스, CDC, 전체 타이밍 sign-off 선언이 아니다.

> **C08 diagnostic ABI 개정:** Section 3.2의 bit 5 및 bits 31:16, Sections 3.2.1–3.2.4, Section 5.2는 Owner/Chat spec review 대기 중인 normative draft다. 아직 구현·검증되지 않았다. 기존 bits 4:0, functional timing, accepted P08B criterion은 계약을 유지한다. 위 source anchor는 새 diagnostic의 근거가 아니다.

## 현행 계약과 source/evidence 경계

Source `35e4633a53a080402526ef751d128df120f311a9`에는 C08 diagnostic ABI인 STATUS bit 5 IS_CDC와 bits 31:16 LOCK_LOSS_COUNT가 있다. §6의 후속 C08 disposition이 앞의 diagnostic 미구현/미실행 표기를 대체하지만 §6.1/§7.2의 physical-assurance exception 제안을 채택하지는 않는다. 동결된 operation, frame-wrap ACK, clear-count, no-side-effect, reset/abort, recovery 의무를 유지한다. C08-PHYS-001 NOT_PROVEN, VGA-CDC-AC-09 BLOCK/NOT_VERIFIED, CDC-001/VER-003 OPEN, STA-001 IN_PROGRESS, STA-002 BLOCKED, SYNCASYNCNET NOT_WAIVED는 그대로다.

P12 G16 Owner 수용은 해당 Health image의 정상 VGA/Health dashboard와 Owner 관찰 정상 KEY0 restart에 한정된다. 동기 UART/VGA same-N 내용, hardware CLEAR, trap injection, 모든 lock-loss event, reset branch 순서, M9K write-edge atomicity는 증명하지 않는다. 과거 P08B functional evidence와 후속 P12 digital/board 범위는 별도이며 현재 source의 physical safety나 release를 보증하지 않는다.

추적: [pre_fetch_AHB_VRAM_DUAL_BUFFER.v](../../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v); [HW_Cleaner.v](../../rtl/video/vram/HW_Cleaner.v); [vram.c](../../firmware/drivers/vram.c); [summary.md](../../reports/evidence/vga-hwclear/summary.md).

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
| 5 | `IS_CDC` | RO / W1C | 관측된 lock-loss-associated sampled CPU framebuffer write-command / final accepted AHB response 불일치의 sticky fault. reset 값 0. Section 3.2.1 참조 |
| 15:6 | reserved | RAZ / WI | read zero, write ignored |
| 31:16 | `LOCK_LOSS_COUNT` | RO / WI | captured PLL lock-loss episode의 16-bit saturating count. reset 값 0, saturation `0xFFFF`. Section 3.2.2 참조 |

1 write는 bit 0, 1, 3과 (이번 개정의) bit 5만 선택적으로 clear하며 0 write는 acknowledge하지 않는다. 같은 HCLK edge의 hardware set이 W1C clear보다 우선한다. 기존 bits 4:0의 reset/event priority와 timing은 유지한다. `OP_BUSY`와 `DOMAIN_READY`는 live이며 W1C state가 아니다. bits 31:16, 15:6, 4, 2의 write는 ignored다. 어떤 STATUS write도 counter를 바꾸거나 선택하지 않은 event를 acknowledge할 수 없다.

`HRESETn=0`은 두 새 diagnostic과 pending diagnostic event/transaction history를 clear한다. bit-5 selective W1C만 `IS_CDC`의 software clear이고, `HRESETn`만 reset source다. PLL loss, pixel reset, ownership-epoch invalidation, recovery는 두 diagnostic이나 pending captured loss를 지우면 안 된다. counter에는 software clear가 없고 bit-5 W1C도 counter를 바꾸지 않는다. reset asserted 동안 reset이 diagnostic set/clear보다 우선하며 release 이후 hardware set이 W1C보다 우선한다.

STATUS access는 framebuffer/control readiness rejection gate를 사용하지 않는다. 따라서 aligned status read/W1C write는 `OP_BUSY=1` 또는 `DOMAIN_READY=0`에서도 수락될 수 있다. 수락된 W1C bus write는 선택 event acknowledge만 수행하며 VRAM word write가 아니다.

### 3.2.1 Sampled-command mismatch와 transaction association

diagnostic은 bank write-port interface의 HCLK-sampled **CPU-attributable framebuffer write command**와 **동일한 captured data-phase transaction**의 response를 관측한다. command intent, address/data, selected bank, command multiplicity를 관측하며 독립 BRAM bitcell acknowledgement가 아니다. supported aligned canonical framebuffer word write의 비교 기준은 final OKAY일 때 CPU command 정확히 1회, final ERROR일 때 0회다. Cleaner write, CONTROL/STATUS transfer, unsupported address/size/direction, unrelated bus phase는 제외한다.

terminal response는 HCLK completion edge에서 local `HREADY=1`과 `HREADY_IN=1`이 모두 성립해야 globally accepted다. ERROR의 첫 `HREADY=0` cycle은 final completion이 아니다. `HREADY_IN=0`일 때 OKAY는 held이며 accepted가 아니다. early/held-phase observation은 독립 completed comparison을 만들면 안 된다. out-of-completion CPU command를 기록한다면 같은 transaction에 command-timing/multiplicity violation으로 결합하여 terminal comparison까지 유지해야 한다. synthetic completion, duplicate transaction, Cleaner write attribution은 금지한다.

command/response disagreement가 검출되고 **동시에** 해당 outstanding data-phase interval에서 lock-loss association이 관측된 transaction만 `IS_CDC`를 set한다. association은 sampled invalid raw lock 또는 contemporaneous transaction association이 명확한 captured loss notice다. delayed untagged loss notification을 이전 completion이나 무관한 이후 transaction에 소급 적용하면 안 된다. ambiguous association은 diagnostic coverage 밖이다. 이후 loss 전에 정상 완료된 command는 mismatch가 아니며, CPU command 0회의 정상 loss-rejected ERROR도 fault가 아니다. CPU framebuffer transaction 없는 captured loss는 counter만 증가시킨다.

monitor는 관측 전용이며 functional commit, write-enable, AHB response, bank ownership, reset, recovery control을 구동하면 안 된다. `IS_CDC=0`은 observed qualified mismatch가 없었다는 의미뿐이다. response와 write-command가 같은 Boolean expression을 공유하면 비교가 vacuous할 수 있고 synthesis가 redundant logic을 제거할 수도 있다. monitor 보존이나 zero flag 모두 독립성을 증명하지 않는다. physical memory write edge 근처 lock transition, metastability, pulse width, 실제 bitcell effect는 sampled-command proof 밖이다.

### 3.2.2 Captured PLL loss episode, arm/rearm, clock stop

episode는 diagnostic capture가 armed일 때 captured `vga_pll_locked:1→0` transition이며 low cycle 수가 아니다. `HRESETn` 이후 capture는 disarmed/pending 없음으로 시작한다. initial lock=0과 첫 lock acquisition은 counter를 증가시키지 않는다. arming의 stable lock은 `HRESETn=1` 동안 synchronized lock=1을 최소 두 번 연속 HCLK에서 관측한 것이다. 이는 digital qualification interval이며 analog PLL stability 증명이 아니다.

stable-lock qualification 및 이전 captured notice의 acknowledgement/retirement가 끝나고 capture/transfer channel이 idle일 때만 arm한다. 첫 captured loss는 capture를 disarm하고 HCLK consume까지 pending episode 하나를 보존한다. consume은 `LOCK_LOSS_COUNT`를 한 번 증가시키거나 `0xFFFF`를 유지하고 notice를 acknowledge한다. rearm은 loss 이후 **새** stable-lock qualification과 capture/acknowledgement 완료를 모두 요구한다. 지속 low는 rearm할 수 없다. capture, transfer, acknowledgement, disarmed recovery 중 loss는 coalesce하거나 count되지 않을 수 있다. loss-event FIFO나 모든 physical event의 정확한 counter가 아니다.

asynchronous capture mechanism은 armed 상태에서 성공적으로 captured된 episode를 PLL/pixel epoch reset에도 보존해야 한다. HCLK가 stop하면 retirement, counter update, software observation은 HCLK restart까지 지연된다. `HRESETn` asserted가 아닌 한 그동안 captured pending notice를 보존해야 한다. PCLK stop/restart 자체는 lock-loss episode나 counter reset이 아니고 diagnostic transfer는 PCLK progress에 의존하면 안 된다. 이미 disarmed일 때 loss는 count되지 않을 수 있다. arbitrary short pulse capture는 보장하지 않는다. minimum capture/rearm pulse width와 physical implementation 한계는 이후 device/board evidence가 필요하다.

### 3.2.3 STATUS sampling과 해석

aligned STATUS read 하나는 globally accepted read-completion edge에서 완전한 32-bit HCLK-visible register image를 sample한다. 두 diagnostic field는 같은 pre-update image에서 읽고 그 edge에 retired된 update는 이후 read에서 보인다. held read는 독립 completion이 아니다. 이는 software의 counter/flag torn read를 막지만 pending asynchronous loss capture, transaction diagnosis, counter retirement, 다른 live status field를 external edge와 atomic하게 ordering하지 않는다. pending notice가 반환 count에 아직 없을 수 있고 fault와 count가 동시에 보일 필요도 없다.

`HRESETn` 없는 interval에서 양 endpoint count가 `0xFFFF` 미만이면 positive ordinary counter difference는 test setup 및 event provenance가 valid할 때 captured/retired loss opportunity만 증명한다. 모든 physical loss나 특정 write edge stress를 증명하지 않는다. saturation 이후 추가 loss 수는 알 수 없으며 modulo/wrap subtraction은 금지한다. `COUNT=0`은 physical loss 부재를 인증하지 않고 `COUNT>0 && IS_CDC=0`도 physical commit이나 CDC correctness를 증명하지 않는다. fault W1C 이후 counter retention 및 delayed capture retirement 때문에 두 field를 하나의 event log로 취급할 수도 없다.

### 3.2.4 Firmware / Health diagnostic 사용

firmware는 하나의 `vram_status()` 결과에서 두 field를 얻는다. bit 5는 fault이고 `(status >> 16) & 0xFFFF`는 captured count다. explicit bit-5 W1C 전에 snapshot을 read/report해야 한다. routine `vram_clear_events()` 및 operation/VSYNC housekeeping mask는 bits 0, 1, 3만 유지한다. bit 5를 acknowledge하거나 저장한 full STATUS를 event-clear mask로 write-back하면 안 된다. 현재 driver API가 새 explicit fault-clear operation을 구현한다고 주장하지 않는다. pending newly diagnosed mismatch는 software가 old history를 clear해도 sticky bit를 set/re-set할 수 있다.

Health qualification은 기존 READY/VSYNC/SWAP/DONE progress 및 abort/error rule을 계속 요구한다. diagnostic은 이를 보완하며 zero fault나 nonzero counter만으로 Health PASS 또는 `VGA-CDC-AC-09`를 만족할 수 없다. framebuffer는 write-only다. readiness precheck는 MMIO race, terminal ERROR trap, automatic retry/trap recovery 부재를 해소하지 않는다. 이후 board stress는 독립 external lock-loss/stimulus timing evidence와 capture/arm 조건 확인이 필요하다. internal counter만으로 edge-near loss opportunity를 입증할 수 없다.

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
| `vram_clear_cdc_fault()` | STATUS bit 5 W1C만 write; LOCK_LOSS_COUNT 불변 | `void`; recovery/board-safety 보증이 아님 |
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

### 5.2 Diagnostic 개정 acceptance case (구현 diagnostic; 한정 evidence)

새 criterion은 `VGA-AC-01..08` 및 `VGA-CDC-AC-01..09`를 대체하지 않으며 accepted implementation/DV evidence가 없다. positive case와 아래 counterexample은 이후 별도 범위 승인으로 independent transaction/event oracle 기반 verification이 필요하다. 이번 문서 개정은 test execution을 승인하지 않는다.

| ID | Required case와 counterexample | Pass condition |
|---|---|---|
| `VGA-DIAG-AC-01` | initial lock low, acquisition, qualified arm, sustained loss 1회; low 유지 | startup/acquisition count 0; captured armed loss 1회만 증가; low cycle 반복 증가 없음 |
| `VGA-DIAG-AC-02` | loss/ack/relock/rearm; rearm 전 rapid pulse; saturation | rearm 뒤 새 qualified episode는 1회 증가; unarmed/rapid loss의 개별 count 보장 없음; `0xFFFF` wrap 금지 |
| `VGA-DIAG-AC-03` | qualified same-transaction loss-associated command/response mismatch와 matching OKAY/command 1회, ERROR/command 0회 비교 | qualified mismatch만 bit 5 set; framebuffer traffic 없는 loss는 count만 변경. 이후 isolated negative control로 production state 변경 없이 checker sensitivity 확인 필요 |
| `VGA-DIAG-AC-04` | held OKAY, ERROR wait/final, early command, Cleaner/CONTROL/unsupported traffic, delayed untagged notice | global completion 및 transaction identity로 비교; excluded traffic은 bit 5 set 금지; unrelated/retroactive association 없음 |
| `VGA-DIAG-AC-05` | selective/routine W1C, zero write, RO/reserved write, simultaneous set/clear | selected sticky event만 clear; bit-5 hardware set이 W1C보다 우선; count/live/unselected field 불변 |
| `VGA-DIAG-AC-06` | PLL/pixel reset, HCLK/PCLK stop/restart, 이후 HRESETn | diagnostic/pending captured loss는 PLL/pixel recovery에도 보존; HCLK restart 뒤 1회 retire; transfer에 PCLK 불필요; HRESETn은 diagnostic history clear |
| `VGA-DIAG-AC-07` | retirement와 coincident STATUS read, pending transfer, fault clear, saturation; Health progress 없음 | 하나의 pre-update register image; asynchronous total-order 보장 없음; counter delta 한계 적용; diagnostic만으로 Health/AC09 PASS 금지 |
| `VGA-DIAG-AC-08` | common-logic matching, edge-near/uncaptured short loss, count 0, count positive/fault 0 | coverage 한계를 보고하고 physical signoff/perfect event-count로 변환 금지; independent board stimulus evidence 별도 필요 |

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

**C08 evidence disposition:** 별도 승인된 diagnostic ABI/implementation에는 captured loss episode, diagnostic behavior 및 Boolean lock-gating에 대한 current-candidate portable digital 검증이 제한된 범위로 존재한다. 이 상태 설명은 앞의 diagnostic draft/not-executed 표기를 대체하며 ABI나 acceptance case는 바꾸지 않는다. 물리적인 edge-near raw PLL lock-loss 안전성은 **NOT_PROVEN / UNDETERMINABLE**이며, 가용 증거로 입증된 결함은 없다. `IS_CDC=0`과 captured `LOCK_LOSS_COUNT`는 물리적 안전성 인증이 아니다. Positive internal timing과 fitted combinational SCC 0도 reset/RDC 안전성이나 AHB/M9K write-edge 원자성을 입증하지 않는다. `VGA-CDC-AC-09`는 **BLOCK / NOT_VERIFIED**, `SYNCASYNCNET`은 **NOT_WAIVED**를 유지한다.

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

### 6.1 Assurance 범위 — 주장 경계 초안

> **PROPOSED / NOT_ACCEPTED:** 이 절과 §7.2는 검토 초안이다. 현재 operating contract, acceptance criterion, requirement 상태를 바꾸지 않는다.

기존 functional evidence는 established valid epoch에서의 제한된 동작을 뒷받침한다. 그 범위는 nominal 50 MHz HCLK/reference와 25 MHz pixel clock, stable clock operation, destination-domain release를 갖는 qualified system reset, one-outstanding command 및 정상 request/commit/ACK와 selected-bank RAM handoff다. 이는 evidence envelope이며 새로운 device operating specification도, 모든 물리적 startup/lock-loss event가 그 epoch를 확립한다는 보장도 아니다. Clock-progress 가정은 liveness를 한정하며, clock stop이 임의의 ACK나 completion을 허용하지 않는다.

공통의 effective reset assertion과 유효한 release가 성립하면 조건부 abort/rebase 순서를 뒷받침한다. **R1**은 여전히 모든 required PLL invalidation이 두 reset branch를 clear할 것을 요구한다. **R2**는 pixel READY/ACK/pending invalidation과 HCLK abort/rebase가 stale state를 fresh로 소비하기 전에 완료될 것을 요구한다. 두 release stage, diagnostic count 또는 positive STA만으로 어느 전제도 입증되지 않는다. 최소 raw LOW width, differential reset skew 또는 edge-near AHB/WE/M9K bitcell atomicity는 인증하지 않는다.

미입증 물리 조건은 assurance claim의 제한이며 acceptance stimulus의 제외가 아니다. Short loss나 asymmetric capture loss를 `VGA-CDC-AC-05/06/08/09`에서 암묵적으로 제거하지 않는다. Required-event coverage, immediate write suppression, no-side-effect, abort, stale-event suppression은 계속 binding이다. 정본 [assurance limitation register](physical_assurance_limitations.ko.md#c08-phys-001)를 참조한다.


## 7. Approved Target / Deferred Work

### 7.1 C08 물리적 보장 의무 — post-baseline 실행 범위

`C08-PHYS-001`은 HCLK/PCLK/VRAM WE edge 근처의 비동기 raw PLL `locked` 하강, 최소 loss/capture/rearm pulse, 분리된 reset의 capture/release skew와 reconvergence, AHB final response와 M9K write-edge 원자성에 대한 미입증 물리적 보장만 식별한다. 해당 qualification 작업은 현재 baseline-cleanup 실행 대기열에서 제외하고 **`POST_BASELINE_P12_PHYSICAL_QUALIFICATION`**에 배정한다. 이는 조건부 물리 증거 실행 일정이며 승인된 safety waiver, VERIFIED 결과 또는 기존 cleanup gate의 면제가 아니다.

기존 digital test와 Boolean gating은 모델링된 clock/reset 가정 안에서 제한된 동작을 확인한다. Device pulse width, metastability, routing skew, 물리적 reset capture 또는 edge-near lock transition의 RAM commit 동작까지 보장하지 않는다. `VGA-CDC-AC-05/09`를 포함한 현재 immediate-write-suppression, abort, recovery, no-side-effect 및 ownership 계약은 변경하거나 면제하지 않는다. C09 dual-clock-memory qualification, ADC timing exception 및 외부 I/O closure는 별도 의무이며 이 항목으로 이관되지 않는다.

기존 제한된 범위의 개발/보드 관찰을 edge-near PLL loss 안전성의 증거로 제시하면 안 된다. 그 보장을 요구하는 board-use 또는 deployment 주장은 향후 증거와 Owner acceptance 전까지 미인증 상태다. Diagnostic fault flag 0이나 captured loss count로 그러한 주장을 승인할 수 없다.

담당자는 VGA/clock-reset specification maintainer이며 board owner가 물리 실행과 acceptance를 담당한다. 물리적 lock-loss 안전성 주장 전, 관련 clock/reset/PLL/M9K 설정 또는 write-commit 변경 시, lock-loss 이상 관측 시 재진입해야 한다. Active safety defect가 입증되면 통상적 이관으로 처리하지 않고 즉시 corrective/restricted-use review가 필요하다.

향후 acceptance에는 정확한 source/IP/bitstream/board binding, primary MAX10/ALTPLL/M9K pulse/reset/write-edge 계약, NOT_ANALYZABLE 공백을 명시한 해당 timing/RDC 및 reset-branch/diagnostic-capture coverage, 그리고 계약이나 분석만으로 보장할 수 없는 부분의 targeted physical evidence가 필요하다. 물리 자극과 clock/write edge의 관계는 독립 관측해야 하며 diagnostic counter로 추정하면 안 된다. Safety 주장 전 Owner review에서 남은 가정을 모두 해결해야 하고 미해결 사례는 NOT_VERIFIED로 유지한다.

[Cleanup exit gate](../baseline_cleanup.md#3-cleanup-exit-gate)는 모든 BC High/Blocker 항목의 VERIFIED를 계속 요구한다. `CDC-001 OPEN`, `VER-003 OPEN`, `STA-001 IN_PROGRESS`, `STA-002 BLOCKED`, `VGA-CDC-AC-09 BLOCK / NOT_VERIFIED`를 보존한다. BC row, gate taxonomy, reset spec 또는 release checklist는 완화하지 않는다. [C08 deferred obligation](baseline_cleanup.ko.md#23a-c08-물리적-보장-의무)을 참조한다.

Owner-authorized uncommitted C09 `rd_aclr(1'b0)` binding은 보존한다. 이번 개정은 read latency, bank isolation, reset/recovery, first-visible-pixel 계약을 바꾸지 않는다. C09 physical primitive behavior는 별도의 P12 device/physical work로 유지한다.

이번 개정 밖의 proposed follow-up: [memory map](../01_memory_map.md)의 historical W1C summary/legacy VGA link, [firmware contract](../19_firmware_contract.md)의 legacy clear 용어, [Health firmware contract](../22_soc_health_firmware.md)의 향후 diagnostic reporting을 정리한다. memory-map address/width ownership은 불변이며 해당 문서들은 detailed peripheral semantics를 owning spec에 위임한다. 이번 개정은 tracker에 C08 physical-obligation 범위 설명만 추가하며 driver, Health qualification, evidence acceptance는 바꾸지 않는다.

| Item | 상태 | 범위 |
|---|---|---|
| `CDC-001` | OPEN | 이 명세가 normative request/commit/ACK/ownership/recovery contract를 정의한다. 이후 implementation, independent behavioral DV, structural CDC review가 필요 |
| `STA-001` | IN_PROGRESS | internal STA는 SCOPED_PASS 한정 |
| `STA-002` | BLOCKED | external I/O/electrical timing peer/board closure 없음 |
| VGA/ADC warnings | OPEN | critical proximity warning 명시 처분 필요 |
| `RESET_WINDOW_UNPROTECTED_BEFORE_MTVEC_COMMIT` | known risk | verified safe firmware trap interval이 아님 |
| Programmer/JTAG binding | unavailable | independent SOF-to-board binding 미수집 |

### 7.2 Bounded assurance 제안 — 활성 예외 아님

> **PROPOSED / NOT_ACCEPTED:** 기존 RTL과 모든 active behavior를 유지한다. 이 제안은 주장 한계를 기록하며 물리적 safety waiver를 부여하지 않는다.

`C08-PHYS-001`의 단일 정본 record는 [assurance limitation register](physical_assurance_limitations.ko.md#c08-phys-001)에 두며 §7.1의 accepted 실행 일정과 주장 경계를 유지한다. 물리 상태는 `NOT_PROVEN`, 예외 요청은 `PROPOSED / NOT_ACCEPTED`다. AC09의 essential R1/R2 dependency는 [cleanup §3.1](baseline_cleanup.ko.md#31-proposed-limited-assurance-disposition)의 supplemental-claim 예외 경로에 들어갈 수 없다.

Limited internal engineering checkpoint는 기존 조건부 functional evidence와 모든 residual blocker를 설명할 수 있다. 이는 Clean Baseline v1 release, deployment safety certification, AC09 acceptance 또는 stable PLIC/AXI stage로 진행할 권한이 아니다. Required-event class 축소나 부적합한 reset/startup 가정은 채택 전 별도 frozen-contract 결정이 필요하며 exception record로 도입할 수 없다.


## 8. Traceability

- Tracker: [`../baseline_cleanup.md`](../baseline_cleanup.md), [Korean tracker](baseline_cleanup.ko.md)
- Active RTL: [`pre_fetch_AHB_VRAM_DUAL_BUFFER.v`](../../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v), [`HW_Cleaner.v`](../../rtl/video/vram/HW_Cleaner.v), [`VGA_SyncGen.v`](../../rtl/video/vga/VGA_SyncGen.v)
- Firmware: [`vram.h`](../../firmware/include/vram.h), [`vram.c`](../../firmware/drivers/vram.c)
- Directed verification: [`tb_p08b_vga.sv`](../../verification/directed/vga/tb_p08b_vga.sv), [`tb_p08b_vga_state_matrix.sv`](../../verification/directed/vga/tb_p08b_vga_state_matrix.sv), [`tb_p08b_vga_atomicity_matrix.sv`](../../verification/directed/vga/tb_p08b_vga_atomicity_matrix.sv), [`tb_p08b_vga_cpu_fault.sv`](../../verification/directed/vga/tb_p08b_vga_cpu_fault.sv)
- Case/evidence: [CS-009](../../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md), [P08B-VGA-EV-01](../../reports/evidence/vga-hwclear/summary.md)

## Appendix A. Historical / Pre-cleanup Notes

과거 baseline에는 broad local alias, fixed OKAY/ready, immediate HCLK swap/direct live bank selection, live clear-bank target, level식 clear completion, hardware-clear board 미검증 문장이 있었다. 이는 historical only이며 현재 계약으로 쓰면 안 된다. 현재 request/commit/ACK ownership protocol과 P05 lock-qualified reset architecture가 direct-selector 설명을 대체한다. 보존할 architecture/geometry/timing 사실은 Section 2/3으로 재조정했고 engineering alternative는 CS-009에 있다.
