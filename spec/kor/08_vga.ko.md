# Baseline SoC VGA / VRAM Subsystem Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/08_vga.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `ahb_fabric.md`, `reset_clock.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 관대한 framebuffer 접근 설명은 cleanup 전 baseline 기록이다. 마지막 framebuffer 문단은 A3 버스 접근 정책만 현행으로 승격하며 FW API, VGA CDC, 물리·보드 검증은 열린 상태다.

## 1. 목적

이 문서는 active FPGA baseline의 VGA / VRAM subsystem을 정의한다. 주요 범위는 다음과 같다.

- active AHB-side display architecture
- CPU-visible framebuffer 및 control/status 동작
- physical front/back buffer 구조
- 640×480 1-bpp pixel format
- VGA timing 및 pixel clock
- buffer swap semantics
- VSync status synchronization
- hardware clear engine
- firmware 사용 규칙
- 현재 CDC/protocol 한계
- 향후 major interconnect 작업 전에 해결할 baseline cleanup 항목

이 문서는 **현재 구현된 baseline**을 설명한다. 현재 RTL에 존재하지만 software가 사용하면 안 되는 implementation quirk도 명시하며, dormant VGA source나 broad address alias를 architecture feature로 승격하지 않는다.

## 2. Active Architecture Boundary

현재 실제 display path는 `AMBA_SoC_TOP`에서 직접 instantiate되는 AHB-side module이다.

```text
AHB_VRAM_DUAL_BUFFER
```

Active path는 다음과 같다.

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

현재 subsystem은 **APB peripheral이 아니다**.

`rtl/video/vga/APB_VGA_Top.v` 파일은 dormant source로 존재하지만 `AMBA_SoC_TOP`에서 instantiate되지 않는다. 따라서 해당 파일의 존재만으로 baseline architecture나 register map을 정의해서는 안 된다.

## 3. Canonical Address Map

Canonical software-visible VGA 영역은 다음과 같다.

| 주소 | 크기 | 기능 | Baseline access |
|---:|---:|---|---|
| `0x2000_0000` – `0x2000_95FF` | 38,400 B | Current back-buffer framebuffer | **32-bit write only** |
| `0x2000_9600` – `0x2000_FFFF` | — | Reserved | Software access 금지 |
| `0x2001_0000` | 4 B | `VRAM_STATUS` | Read; bit 0 W1C |
| `0x2001_0004` | 4 B | `VRAM_CONTROL` | Write command |

Top-level fabric은 전체 `0x2xxx_xxxx` region을 넓게 select하고, VGA subsystem은 lower address bit 일부만 decode한다. 따라서 실제 hardware alias가 존재할 수 있지만, 그 alias는 canonical address가 아니다.

### 3.1 Framebuffer read limitation

현재 RTL에는 back-buffer read-data path가 주석 처리되어 있다. 실제 구현에서 framebuffer address에 대한 `HRDATA`는 저장된 framebuffer word를 반환하지 않는다.

따라서 canonical framebuffer window를 CPU가 읽으면 현재 VGA slave path에서는 0이 반환된다.

즉 baseline의 CPU-facing framebuffer contract는 **write-only**이다. Firmware 및 verification은 framebuffer readback을 correctness check로 사용하면 안 된다.

## 4. AHB-Side Transfer Contract

현재 VGA slave는 selected transfer에 대해 다음을 고정 출력한다.

```text
HREADY = 1
HRESP  = OKAY
```

따라서 VGA target은 AHB wait state를 추가하지 않는다.

Valid transfer는 다음 조건으로 판단한다.

```text
HSEL == 1
and HTRANS is NONSEQ or SEQ
```

Address/control은 다음 data phase를 위해 latch되며, store data는 해당 data phase의 `HWDATA`에서 사용된다.

현재 VGA slave는 `HSIZE`, `CUSTOM_WRITE_MASK`, 또는 equivalent byte-enable signal을 사용하지 않는다.

따라서 normative baseline framebuffer access는 naturally aligned **32-bit write**뿐이다.

Byte/halfword framebuffer store는 지원 기능으로 간주하면 안 된다. 현재 firmware에 `vram_write_byte()` helper가 존재하지만, active RTL에는 byte-enable path가 없으므로 byte store가 동일 32-bit word의 나머지 byte를 보존한다는 보장이 없다. 해당 helper는 supported architectural capability가 아니라 cleanup 대상이다.

## 5. Framebuffer Geometry 및 Pixel Format

Visible image는 다음과 같다.

```text
640 pixels × 480 pixels × 1 bit/pixel
= 307,200 bits
= 38,400 bytes
= 9,600 × 32-bit words
```

한 visible row는:

```text
640 / 32 = 20 words
```

이다.

Canonical software indexing은 다음과 같다.

```text
word_index = y * 20 + (x >> 5)
bit_index  = x & 31
```

조건은:

```text
0 <= x < 640
0 <= y < 480
```

이다.

현재 validated firmware convention은 하나의 32-pixel word에서 왼쪽 pixel을 low-order bit에 배치하고 X가 증가할수록 더 높은 bit position을 사용한다. 기존 text renderer가 각 8-bit font row를 `reverse_bits()`한 뒤 packing하는 이유도 이 pixel ordering에 맞추기 위해서다.

Pixel value 의미는 다음과 같다.

| 저장 bit | VGA 출력 |
|---:|---|
| 0 | black: `R=0, G=0, B=0` |
| 1 | white: `R=0xF, G=0xF, B=0xF` |

따라서 DE10-Lite VGA 출력이 RGB 각 4 bit를 제공해도 baseline 화면 자체는 monochrome이다.

## 6. Physical VRAM Organization

Subsystem은 두 개의 Intel/Altera mixed-width dual-port RAM을 사용한다.

```text
VRAM0
VRAM1
```

각 physical buffer 설정은 다음과 같다.

```text
Port A: 16,384 × 32-bit, HCLK write side
Port B: 524,288 × 1-bit, pclk_25 read side
```

즉 buffer 하나당 524,288 bit = 64 KiB physical storage이다.

Canonical visible framebuffer로 사용하는 영역은 첫 9,600 Port-A word / 307,200 Port-B bit뿐이다. 나머지 physical RAM 영역은 software-visible framebuffer contract가 아니다.

Dual-clock RAM primitive 자체가 HCLK write와 pixel-clock read 사이의 storage crossing을 제공하지만, 상위의 buffer-selection control에는 별도 CDC 이슈가 있으며 뒤에서 다룬다.

## 7. Front / Back Buffer Ownership

`front_buffer_idx`가 physical front buffer를 선택한다.

| `front_buffer_idx` | VGA front buffer | CPU/HW-clear back buffer |
|---:|---|---|
| 0 | VRAM0 | VRAM1 |
| 1 | VRAM1 | VRAM0 |

Reset 시:

```text
front_buffer_idx = 0
```

이므로 VRAM0이 front, VRAM1이 back으로 시작한다.

CPU framebuffer window는 항상 현재 **back buffer**로 지정된 physical RAM만 접근한다. Software가 VRAM0/VRAM1을 직접 선택하는 address는 없다.

## 8. Buffer Swap

`VRAM_CONTROL.SWAP = 1`을 write하면 `front_buffer_idx`가 toggle된다.

즉:

```text
old back  -> new front
old front -> new back
```

으로 역할이 교환된다.

SWAP bit는 저장되는 state가 아니라 command이다. 0을 쓰면 swap이 발생하지 않는다.

현재 RTL은 control write가 commit되는 HCLK domain에서 `front_buffer_idx`를 즉시 변경하며 pixel-domain frame-boundary handshake는 없다.

따라서 intended firmware usage는:

```text
1. back buffer에 complete frame render
2. VSync status event 대기
3. SWAP 명령
```

이다.

이 방식은 vertical blanking 부근에서 swap하여 visible tearing 가능성을 줄이지만, 현재 구조가 formal CDC-safe atomic frame-boundary swap을 보장한다는 의미는 아니다.

## 9. VGA Pixel Clock 및 Timing

Board 50 MHz clock이 `vga_pll`로 들어가 다음 pixel clock을 생성한다.

```text
pclk_25 = 25 MHz
```

Horizontal timing:

| 구간 | Pixels |
|---|---:|
| Visible | 640 |
| Front porch | 16 |
| Sync pulse | 96 |
| Back porch | 48 |
| Total | 800 |

Vertical timing:

| 구간 | Lines |
|---|---:|
| Visible | 480 |
| Front porch | 10 |
| Sync pulse | 2 |
| Back porch | 33 |
| Total | 525 |

`VGA_HS`, `VGA_VS`는 active-low이다.

정확히 25 MHz 기준 nominal frame frequency는:

```text
25,000,000 / (800 × 525) ≈ 59.52 Hz
```

이다. 구현 주석에서 이를 일반적인 640×480 @ 약 60 Hz VGA mode로 표현한다.

Visible 영역 밖에서는 RGB output을 black으로 강제한다.

## 10. Pixel Prefetch Path

Mixed-width VRAM read port는 `pclk_25`로 동작하고 19-bit linear pixel address를 사용한다.

Subsystem에는 synchronous RAM read pipeline에 맞추기 위한 prefetch address generator가 있다. 이를 통해 `VGA_SyncGen`이 해당 visible coordinate에 도달했을 때 필요한 pixel bit가 출력된다.

Address generator는:

- visible 307,200 pixel을 scan order로 순회
- line boundary prefetch 처리
- frame 마지막 부근에서 read address를 초기화하여 다음 frame의 pixel 0을 미리 준비

한다.

Software는 내부 prefetch counter cycle에 의존하지 말고 framebuffer X/Y 또는 32-bit word coordinate 기준으로 동작해야 한다.

## 11. VSync CDC 및 Status Flag

`VGA_VS`는 25 MHz pixel domain에서 생성된다.

현재 구현은 VSync를 HCLK로 다음과 같이 3단 sample한다.

```text
vga_vsync_sig
   -> vsync_d1
   -> vsync_d2
   -> vsync_d3
```

그리고:

```text
vsync_rising_edge = vsync_d2 & ~vsync_d3
```

를 검출한다.

VGA VSync는 active-low이므로 이 rising edge는 active-low VSync pulse의 **시작이 아니라 deassertion / 끝**에 해당한다.

이 event가 검출되면 HCLK-domain `vsync_flag`가 1이 되고, software가 `VRAM_STATUS[0]`에 1을 write할 때까지 sticky 상태를 유지한다.

VSync flag는 polling 방식이며 interrupt를 생성하지 않는다.

## 12. Status 및 Control Register

### 12.1 `VRAM_STATUS` — `0x2001_0000`

| Bit | Name | Access | Baseline behavior |
|---:|---|---|---|
| 0 | `VSYNC` | R / W1C | synchronized VSync-deassertion sticky event |
| 1 | `CLEAR_DONE` | R | `HW_Cleaner.clr_done` 직접 status |
| 2 | `CLEAR_BUSY` | R | cleaner가 framebuffer word를 실제 clear하는 동안 1 |
| 31:3 | Reserved | R | 0 |

`CLEAR_DONE` 의미에 주의해야 한다.

`clr_done`은 cleaner의 `IDLE`과 `DONE` state 모두에서 high이다. 따라서 이것은 **1-cycle completion pulse가 아니며**, reset 후 idle 상태에서도 이미 1이다.

Software는 active clear 종료 판단에 `CLEAR_BUSY == 0`을 사용하는 것이 안전하다. 현재 production driver도 이 정책을 따른다.

`VRAM_STATUS` write에서 실제 동작하는 것은 bit 0뿐이다. bit 0에 1을 write하면 `VSYNC` flag가 clear되며 다른 write bit의 기능은 정의되지 않는다.

### 12.2 `VRAM_CONTROL` — `0x2001_0004`

| Bit | Name | Access | Baseline behavior |
|---:|---|---|---|
| 0 | `SWAP` | W command | front/back ownership toggle |
| 1 | `HW_CLEAR` | W command | current/resulting back buffer hardware clear 요청 |
| 31:2 | Reserved | W | ignored |

Control register는 stored read/write state가 아니라 command-style register이다. Read는 normative contract가 아니며 active VGA `HRDATA` path는 control state를 반환하지 않는다.

## 13. Hardware Clear Engine

`HW_Cleaner`는 visible back-buffer 영역의 다음 word를 모두 0으로 write한다.

```text
word 0 through word 9599 inclusive
```

Cleaner state machine은:

```text
IDLE -> CLEAR -> DONE -> IDLE
```

이다.

`CLEAR` 동안:

```text
clr_busy = 1
clr_we   = 1
```

이며 HCLK 한 cycle당 32-bit zero word 하나를 쓴다.

따라서 active clear 구간은 9,600 HCLK write cycle이며 50 MHz 기준 약:

```text
9,600 / 50 MHz = 192 us
```

이다. Command/start state transition overhead는 이 값에 포함하지 않는다.

### 13.1 Combined swap-and-clear

기존 driver는 한 control transaction에서:

```text
SWAP | HW_CLEAR
```

를 write한다.

의도된 결과는:

```text
완성된 old back을 new front로 publish
그 다음 old front = new back을 hardware clear
```

하는 것이다.

이 방식이 baseline hardware-clear의 정상적인 사용 방식이다.

### 13.2 Cleaner가 CPU framebuffer write보다 우선

`CLEAR_BUSY=1` 동안 cleaner가 back-buffer의 write address, write enable, write data mux를 소유한다.

따라서 동일 시점의 CPU framebuffer write는 실제 VRAM에 반영되지 않는다. 하지만 AHB slave는 계속:

```text
HREADY = 1
HRESP  = OKAY
```

를 반환하므로 CPU는 해당 write가 버려졌다는 사실을 알 수 없다.

**Normative software rule:** `CLEAR_BUSY=1` 동안 framebuffer에 write하면 안 된다.

### 13.3 Clear 중 추가 SWAP

Cleaner의 physical RAM target은 live `front_buffer_idx`를 기준으로 선택된다. 따라서 clear 도중 두 번째 SWAP을 수행하면 이후 cleaner write가 다른 physical buffer로 이동할 수 있다.

**Normative software rule:** `CLEAR_BUSY=1` 동안 추가 SWAP을 수행하면 안 된다.

초기의 combined `SWAP | HW_CLEAR` command는 intended exception이다. Buffer role이 먼저 변경된 후 resulting back buffer를 clear하는 용도다.

## 14. Reset Behavior

System reset 시 VGA subsystem의 주요 control state는 다음과 같이 초기화된다.

```text
front_buffer_idx = 0
vsync_flag       = 0
hw_clear_start   = 0
hw_clear_run     = 0
VRAM_ADDR        = 0
```

VGA timing counter도 pixel-clock domain에서 `HRESETn`으로 reset되며, VRAM read output/address path는 RAM IP의 asynchronous clear를 사용한다.

System reset을 두 framebuffer memory 전체를 erase하는 architectural command로 해석하면 안 된다. Known blank back buffer가 필요하면 software clear 또는 `HW_Cleaner`를 명시적으로 사용해야 한다.

`reset_clock.md`에서 정의한 것처럼 generated clock domain의 reset deassertion 및 일부 CDC는 production-quality signoff 전에 추가 cleanup이 필요하다.

## 15. Dormant APB VGA Source

`rtl/video/vga/APB_VGA_Top.v`는 active SoC top-level에서 instantiate되지 않는다.

따라서:

- canonical APB slot이 없다.
- 내부 register behavior는 baseline software-visible behavior가 아니다.
- firmware가 해당 block을 target하면 안 된다.
- future refactoring에서 `AHB_VRAM_DUAL_BUFFER`보다 우선하는 authoritative implementation으로 간주하면 안 된다.

향후 VGA control을 APB 또는 AXI-Lite로 의도적으로 migration하려면 dormant source를 조용히 활성화하는 것이 아니라 별도의 approved specification change가 필요하다.

## 16. Firmware Contract

현재 baseline firmware 지원 함수는 다음과 같다.

```text
vram_status()
vram_wait_vsync()
vram_clear_vsync()
vram_swap_and_clear()
vram_wait_clear_done()
vram_write_word()
```

Hardware-assisted double buffering의 normative sequence는 다음과 같다.

```text
current back buffer 사용 가능 상태 확인
aligned 32-bit write로 frame render
synchronized VSync event 대기
VSync flag clear
SWAP | HW_CLEAR command
CLEAR_BUSY == 0까지 대기
새로 clear된 back buffer에 다음 frame render
```

`display_smoke` diagnostic은 board diagnosis를 위해 의도적으로 다른 sequence를 사용한다.

```text
software로 9,600 back-buffer word 전부 clear
frame render
bounded VSync wait
SWAP only
```

즉 현재 display-smoke는 hardware-clear engine을 분리하여 검증한다.

Firmware는 다음 항목에 의존하면 안 된다.

- framebuffer readback
- byte/halfword framebuffer write
- noncanonical VRAM alias
- clear busy 중 framebuffer write
- clear busy 중 추가 swap

## 17. Validation Status

Migrated baseline은 active AHB VGA subsystem을 포함한 Quartus compile 성공을 재현했다.

현재 `display_smoke` image는 developer-confirmed physical-board VGA 동작이 있으며 다음을 visible하게 exercise한다.

- framebuffer 32-bit write
- 640×480 scanout
- text/pattern pixel ordering
- VSync polling progress
- software-triggered SWAP
- repeated frame publication

Host-side display-smoke test는 mocked MMIO를 사용해 framebuffer bounds, SWAP-only behavior, VSync timeout handling 및 관련 software behavior를 검사한다. CPU/RTL simulation을 의미하지 않는다.

현재 display-smoke board test만으로는 다음이 완전히 증명되지 않는다.

- hardware-clear 동작
- hardware clear 중 CPU write behavior
- framebuffer readback
- byte/halfword framebuffer store
- buffer selection의 formal CDC correctness
- generated-clock/reset timing signoff
- 모든 physical alias boundary

## 18. Baseline Cleanup Targets Before Major Feature Integration

아래 항목은 추후 통합 `baseline_cleanup.md`에 포함해야 한다.

1. **VGA top-level decode 축소** — 전체 `0x2xxx_xxxx`가 아니라 canonical framebuffer/status/control aperture만 select하도록 수정.
2. **승인된 A3 read policy 적용** — window를 write-only로 유지하고 framebuffer read는 A2 ERROR 처리하며 read 기대를 제거.
3. **승인된 A3 subword policy 적용** — byte/halfword access는 ERROR 처리하고 `vram_write_byte()` 등 API를 제거 또는 금지하며 byte strobe/RMW를 추가하지 않는다.
4. **Cleaner/CPU write arbitration 수정** — `CLEAR_BUSY=1` 동안 CPU framebuffer write를 silently acknowledge 후 discard하지 않도록 backpressure, explicit rejection/error, 또는 더 강한 ownership mechanism 도입.
5. **Cleaner target latch** — clear 시작 시 physical target을 고정하여 이후 SWAP이 in-progress clear를 redirect하지 못하게 함.
6. **Frame swap CDC-safe화** — swap을 pixel domain으로 handshake하고 가능하면 defined frame boundary에서 ownership commit.
7. **Generated-domain reset release 및 PLL-lock policy**를 `reset_clock.md`와 일치하도록 정의.
8. **`pclk_25` generated-clock timing constraint**를 완성하고 STA/CDC review 재수행.
9. **`CLEAR_DONE` semantics 명확화** — sticky completion event로 만들거나 BUSY만 사용하고 IDLE에서도 high인 done signal 의존 제거.
10. **Directed RTL verification 추가** — pixel/word boundary, status W1C, swap timing, clear length, clear/write contention, repeated command, reset, reserved address.
11. **FPGA에서 HW clear acceptance test 추가** — 현재 `display_smoke`는 의도적으로 software clear만 사용.
12. **Active/dormant VGA ambiguity 제거** — 안전한 시점에 unused `APB_VGA_Top` integration artifact를 명확히 분리 또는 제거.

## 19. Baseline Invariants

향후 approved VGA/display specification이 이 문서를 supersede하기 전까지:

1. Active display subsystem은 APB VGA peripheral이 아니라 AHB-side `AHB_VRAM_DUAL_BUFFER`이다.
2. Canonical visible framebuffer는 640×480×1 bpp = 38,400 B = 9,600 word이다.
3. CPU framebuffer access는 aligned 32-bit write만 normative하다.
4. CPU framebuffer readback은 구현되어 있지 않다.
5. Pixel 0/1은 각각 black/white에 대응한다.
6. 두 개의 physical VRAM buffer를 사용하며 software-visible window는 항상 current back buffer를 target한다.
7. Reset 시 VRAM0 front, VRAM1 back이다.
8. SWAP은 physical front/back ownership을 toggle한다.
9. VSync status는 active-low VGA VSync의 synchronized rising/deassertion edge에서 생성되는 sticky HCLK-domain flag이다.
10. VGA timing은 25 MHz pixel clock, 800×525 total, 640×480 visible이다.
11. Hardware clear는 current back buffer의 word 0..9599를 0으로 쓴다.
12. Hardware clear busy 중 software framebuffer write 및 추가 swap은 금지한다.
13. Canonical VGA aperture 밖의 broad physical alias는 unsupported이다.
14. Dormant `APB_VGA_Top.v` behavior는 active baseline contract가 아니다.

## 20. Related Specifications

이 문서는 다음 logical specification과 일관되어야 한다.

- `soc_architecture.md`
- `memory_map.md`
- `ahb_fabric.md`
- `reset_clock.md`
- future `firmware_contract.md`

추후 생성할 통합 `baseline_cleanup.md`는 이 문서와 다른 baseline specification의 cleanup item을 한곳에 모아 관리한다.

## Phase 4A-2 승인된 framebuffer/physical 목표 (버스 접근 정책 Phase 4A-3A 구현)

A3 framebuffer는 write-only, 자연 정렬된 32-bit word write만 허용한다. Read, byte/halfword write, 비정규 gap/alias는 A2 2-cycle AHB ERROR 및 CPU access fault로 처리한다. Misaligned CPU store는 bus 접근 전 cause 6 misalignment trap이 우선하고, 직접 bus-master의 misaligned framebuffer transaction은 A2 ERROR다. `VRAM_STATUS`/`VRAM_CONTROL`은 별도 register 의미를 유지한다. FW API는 `vram_write_word()`이며 legacy `vram_write_byte()`는 구현 단계에 제거/deprecate하고 readback API는 제공하지 않는다. Byte strobe/RMW hardware를 추가하지 않는다. STA-002는 VGA 출력 전압/standard/drive/load와 board timing 근거, ADC/VGA pin adjacency warning, VGA 동작 중 ADC 거동을 검토한다. 양의 내부 slack만으로 board signoff가 아니다.

**Phase 4A-3A 상태:** top AHB decode가 framebuffer 정렬 word write만 허용하고 read/subword/직접 버스 misalignment/gap/alias는 VRAM 선택 전에 거부한다. 버스 지향 테스트는 통과했다. FW API, VGA 기능/CDC, STA-002 물리 signoff는 여전히 열려 있다.
