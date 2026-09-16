# Baseline SoC 메모리 서브시스템 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `memory_subsystem.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`.

## 1. 목적

이 문서는 address-map보다 한 단계 아래 수준에서 baseline SoC의 memory subsystem을 정의한다. CPU-local instruction memory, AHB-side data memory, load/store byte-lane 처리, synchronous BRAM timing, read-after-write bypass, firmware image 초기화, reset 시 memory semantics를 규정한다.

CPU pipeline 전체나 AHB fabric 전체를 정의하는 문서는 아니다. CPU-side bus timing과 pipeline stall 규칙은 `cpu_interface.md`, slave selection과 system-level response mux는 `ahb_fabric.md`에서 세부화한다.

## 2. Baseline Memory Architecture

Baseline은 instruction fetch와 data access가 분리된 Harvard-style 구조를 사용한다.

```text
                     RV32I 5-stage CPU
                    +------------------+
                    |                  |
        IF_pc ----->| Local IMEM       |
                    | 4096 x 32-bit    |
                    | 16 KiB ROM       |
                    |                  |
                    | Load / Store     |
                    +--------+---------+
                             |
                             v
                    AHB Master Interface
                             |
                             v
                      AHB-side DMEM
                    +------------------+
                    | AHB_MEMORY_SLAVE |
                    |                  |
                    |  write port      |
                    |       \          |
                    |   8192 x 32-bit  |
                    |   32 KiB BRAM    |
                    |       /          |
                    |  read port       |
                    |                  |
                    | byte-wise RAW    |
                    | bypass / merge   |
                    +------------------+
```

Baseline의 핵심 특성:

- IMEM은 CPU-local이며 AHB address decoder의 slave slot을 사용하지 않는다.
- DMEM은 CPU data-side AHB path를 통해 접근한다.
- IMEM과 DMEM은 모두 32-bit word 단위이다.
- Architectural byte ordering은 little-endian이다.
- Cache, MMU, external SDRAM, coherency mechanism, DMA master는 baseline memory subsystem에 포함되지 않는다.

## 3. Canonical Memory Region

Address allocation의 authoritative source는 `memory_map.md`이며 여기서는 context만 요약한다.

| Memory | Canonical base | Canonical size | Word count | CPU path |
|---|---:|---:|---:|---|
| IMEM | `0x0000_0000` | 16 KiB | 4096 x 32-bit | CPU-local instruction fetch |
| DMEM | `0x1000_0000` | 32 KiB | 8192 x 32-bit | CPU data-side AHB |

위 canonical capacity만 architectural contract이다. DMEM의 canonical range 밖에서 coarse RTL decode 때문에 발생하는 alias는 implementation artifact이며 이 문서의 지원 범위가 아니다.

## 4. Instruction Memory (IMEM)

### 4.1 구성

현재 FPGA 구현은 다음 single-port ROM 구성을 사용한다.

```text
Width        : 32 bits
Depth        : 4096 words
Capacity     : 16 KiB
Word address : 12 bits
Init image   : IMEM.mif
```

CPU fetch path는 다음 주소를 공급한다.

```text
IMEM.address = IF_pc[13:2]
```

따라서 `[1:0]` bit는 ROM word address에 포함되지 않으며 정상 instruction fetch는 32-bit aligned이다.

### 4.2 Fetch Timing

현재 FPGA ROM은 input address를 register하고 output은 별도 output register 없이 제공한다. Architectural 관점에서는 IF/ID pipeline과 정렬된 **synchronous one-cycle memory path**로 취급한다.

현재 RTL에서는 IMEM instance가 `IF_ID_Register` 안에 위치한다. 이 source hierarchy는 implementation detail이며 architecture requirement가 아니다. 향후 ROM wrapper를 다른 hierarchy로 옮길 수 있지만 observable fetch timing과 pipeline contract를 동일하게 유지하거나 먼저 관련 specification을 수정해야 한다.

### 4.3 IF/ID Stall 시 Instruction 보존

ROM이 synchronous이므로 IF/ID logic은 pipeline stall 동안 현재 instruction을 보존해야 한다. Active implementation은 IF/ID stall 진입 시 `irom_q`를 holding register에 저장하고 stall이 유지되는 동안 해당 instruction을 계속 decode stage에 제공한다.

따라서 memory subsystem contract는 pipeline stall 중 decode stage가 hold된 `ID_pc`보다 더 새로운 PC에 해당하는 instruction을 관측하면 안 된다고 규정한다.

### 4.4 IMEM 쓰기 가능 여부

Baseline에서 IMEM은 processor runtime 동안 read-only이다.

CPU data-side store로 IMEM을 수정하는 architectural path는 없다. Firmware update는 runtime store가 아니라 memory initialization image를 다시 build/select하는 방식으로 수행한다.

## 5. Data Memory (DMEM)

### 5.1 구성

현재 DMEM physical memory는 `HCLK`을 공유하는 logically separated read/write port를 가진 32-bit dual-port BRAM으로 구성된다.

```text
Width        : 32 bits
Depth        : 8192 words
Capacity     : 32 KiB
Word address : 13 bits
Byte lanes   : 4 x 8-bit
Init image   : DMEM.mif
```

Generated memory primitive의 사용 방식:

- Port A: 4-bit byte enable을 사용하는 write path.
- Port B: read path.
- Common clock: `HCLK`.

Vendor primitive의 mixed-port read-during-write behavior는 `DONT_CARE`로 설정되어 있다. 따라서 CPU에서 중요한 read-after-write case의 software-visible correctness는 vendor BRAM collision behavior에 의존하지 않고 `AHB_MEMORY_SLAVE`의 explicit bypass logic으로 보장한다.

### 5.2 Addressing

Canonical DMEM byte address는 다음과 같다.

```text
0x1000_0000 - 0x1000_7FFF
```

Physical BRAM word index는 read/write 모두 다음 address bit를 사용한다.

```text
HADDR[14:2]
```

Write address는 AHB data phase에 맞추기 위해 capture된다.

현재 top-level이 canonical 32 KiB보다 넓게 DMEM을 select하는 문제는 `memory_map.md`에 documented되어 있으며, 해당 alias는 두 번째 memory region처럼 사용하면 안 된다.

## 6. DMEM AHB-Side Timing

`AHB_MEMORY_SLAVE`는 explicit wait state를 추가하지 않는다.

```text
HREADY = 1
HRESP  = OKAY
```

BRAM 자체는 synchronous이다. Intended timing model은 다음과 같다.

```text
Cycle N address phase:
    CPU가 memory address/control을 제시

Clock edge N->N+1:
    BRAM read address/control capture
    store address/control을 write data phase용으로 capture

Cycle N+1 data phase:
    load data가 HRDATA로 유효
    store data가 capture된 write address와 byte mask로 commit
```

따라서 이 문서에서 **0-wait-state**란 normal pipelined address/data relationship보다 추가적인 AHB stall cycle을 넣지 않는다는 의미이다. Asynchronous combinational BRAM read라는 의미가 아니다.

현재 DMEM slave의 `HRESP`는 항상 OKAY이다. Unmapped region error 정책은 `ahb_fabric.md`, `memory_map.md`에서 정의한다.

## 7. Store Data Alignment 및 Byte Enable

CPU `StoreAligner`가 32-bit write data와 4-bit write mask를 생성한다. DMEM slave는 이 write mask를 project-specific sideband로 BRAM byte-enable input까지 전달한다.

현재 memory slave는 `HSIZE`를 이용해 자체적으로 byte enable을 생성하지 않는다. 따라서 custom write-mask path는 baseline CPU-to-DMEM implementation contract이며 `cpu_interface.md`에서도 명시해야 한다.

### 7.1 Byte-Lane 규칙

| `write_mask` bit | BRAM byte lane | Word bits | Lowest byte-address offset |
|---:|---|---|---:|
| `[0]` | lane 0 | `[7:0]` | `+0` |
| `[1]` | lane 1 | `[15:8]` | `+1` |
| `[2]` | lane 2 | `[23:16]` | `+2` |
| `[3]` | lane 3 | `[31:24]` | `+3` |

이 규칙은 little-endian architecture와 일치한다.

### 7.2 Store Operation

| Instruction | Valid address offset | Write mask | Write-data formation |
|---|---|---|---|
| `SB` | `0`, `1`, `2`, `3` | 선택된 byte lane 하나 | source byte를 4개 lane 전체에 replicate |
| `SH` | `0` | `0011` | source halfword를 2회 replicate |
| `SH` | `2` | `1100` | source halfword를 2회 replicate |
| `SW` | `0` | `1111` | source word 그대로 사용 |

Misaligned `SH`, `SW`에 대해서 active StoreAligner는 zero write mask를 만든다. 하지만 architectural handling은 CPU exception path의 synchronous misaligned-store trap이다. Zero mask는 defensive implementation behavior이며 trap contract를 대체하지 않는다.

## 8. Load Extraction 및 Extension

BRAM은 complete 32-bit aligned word를 반환한다. CPU `LoadExtender`가 해당 word에서 requested byte/halfword를 선택하고 sign/zero extension을 수행한다.

### 8.1 Load Operation

| Instruction | Alignment requirement | Selected data | Extension |
|---|---|---|---|
| `LB` | 없음 | address `[1:0]`으로 byte 선택 | sign extend |
| `LBU` | 없음 | address `[1:0]`으로 byte 선택 | zero extend |
| `LH` | address `[0] = 0` | address `[1]`으로 lower/upper half 선택 | sign extend |
| `LHU` | address `[0] = 0` | address `[1]`으로 lower/upper half 선택 | zero extend |
| `LW` | address `[1:0] = 00` | full 32-bit word | 없음 |

Misaligned halfword/word load는 synchronous CPU exception이다. Memory subsystem에서 split access로 처리하지 않는다.

## 9. Misaligned Access Contract

Baseline은 misaligned halfword/word access를 memory subsystem에서 emulate하지 않는다.

Architectural requirements:

- `LB`, `LBU`, `SB`는 모든 byte address 허용.
- `LH`, `LHU`, `SH`는 2-byte alignment 필요.
- `LW`, `SW`는 4-byte alignment 필요.
- Misaligned load는 CPU misaligned-load trap 발생.
- Misaligned store는 CPU misaligned-store trap 발생.

Physical BRAM word-address truncation을 근거로 software에서 wrap, split, silently realigned behavior를 기대하면 안 된다.

## 10. Store-to-Load Read-After-Write Hazard

### 10.1 Hazard 조건

Active CPU는 다음 back-to-back case를 감지한다.

- EX stage instruction이 load.
- MEM stage instruction이 store.
- 두 address가 같은 32-bit word를 가리킴.

현재 구현은 address bit `[31:2]`를 비교한다.

### 10.2 Bypass가 필요한 이유

Physical DMEM primitive는 mixed-port read-during-write data를 unspecified(`DONT_CARE`)로 정의한다. 따라서 store 바로 다음 cycle에 같은 word를 load할 경우 raw BRAM output만으로 old/new value 중 무엇이 반환될지 deterministic하게 보장할 수 없다.

Baseline은 이 문제를 `AHB_MEMORY_SLAVE`의 explicit byte-wise forwarding으로 해결한다.

### 10.3 Byte-Wise Merge Semantics

Hazard가 감지되면 memory slave는 다음을 capture한다.

- store write data
- store byte-enable mask
- hazard indication

Return word의 각 byte lane마다 독립적으로 다음 규칙을 적용한다.

```text
if hazard && store_byte_enable[lane] == 1:
    load_word[lane] = store_write_data[lane]
else:
    load_word[lane] = bram_read_data[lane]
```

따라서 같은 word에 대해 back-to-back `SB` 또는 `SH` 후 load가 오면 새로 쓴 byte는 forwarded data를 사용하고, 쓰지 않은 byte는 BRAM의 기존 값을 유지한다. `SW`는 네 byte 모두 forward한다.

이 merge behavior는 vendor BRAM collision mode에 software-visible correctness가 의존하지 않도록 하기 위한 baseline architectural requirement이다.

## 11. CPU Load-Use Pipeline Interaction

Memory subsystem의 synchronous load timing은 active CPU의 **one-cycle load-use hazard policy**와 결합된다.

직전 load가 생산하는 register를 다음 instruction이 즉시 consume하면:

- IF/ID를 1 cycle stall.
- ID/EX를 flush하여 bubble 삽입.
- load는 MEM/WB까지 진행.
- consumer는 이후 WB-stage forwarding으로 load result를 받음.

즉 MEM-stage load result를 이용하는 긴 combinational `HRDATA -> forwarding -> ALU/branch/PC` path에 의존하지 않는다.

정확한 pipeline-control priority와 forwarding rule은 `cpu_interface.md`가 소유하며, 이 section은 해당 규칙이 의존하는 memory timing assumption만 기록한다.

## 12. Firmware Image 및 Initialization Contract

### 12.1 Build-Time Image

현재 firmware build flow의 default depth는 physical memory와 일치한다.

```text
IMEM depth = 4096 words
DMEM depth = 8192 words
```

선택된 FPGA image는 다음 파일을 제공한다.

```text
fpga/quartus/mem/IMEM.mif
fpga/quartus/mem/DMEM.mif
```

Generated FPGA memory wrapper는 해당 MIF를 initialization image로 사용한다.

### 12.2 Linker Placement

Active linker contract:

```text
IMEM : 0x0000_0000, 16 KiB
DMEM : 0x1000_0000, 32 KiB
```

현재 section placement:

- `.start`, `.text`, `.init`, `.fini` -> IMEM.
- `.rodata`, `.srodata`, `.data`, `.sdata` -> initialized DMEM image.
- `.bss`, `.sbss`, `COMMON` -> DMEM, runtime zeroing.
- stack top -> canonical DMEM end - 4 bytes.

### 12.3 Reset은 DMEM 전체를 Clear하지 않음

System reset은 CPU와 memory-wrapper control state를 reset하지만 DMEM array 전체를 architectural하게 erase하지 않는다.

Startup code는 다음 순서로 C runtime semantics를 만든다.

1. `sp`를 `__stack_top`으로 설정.
2. `__bss_start`부터 `__bss_end`까지 word store로 clear.
3. `main` 호출.

따라서 firmware는 system reset이 assert되었다는 이유만으로 arbitrary DMEM location이 zero라고 가정하면 안 된다.

## 13. Reset Behavior

### IMEM

- Memory content는 `IMEM.mif`로 configuration initialization.
- CPU reset은 fetch-control state를 clear/realign.
- Reset이 instruction image 자체를 다시 쓰지는 않음.

### DMEM

- Memory content는 `DMEM.mif`로 configuration initialization.
- Reset은 AHB memory-slave pipeline/bypass control register를 clear.
- Reset이 32 KiB RAM 전체를 scrub하지 않음.
- `.bss` zero initialization은 firmware startup 책임.

향후 hardware memory-clear mechanism을 추가하려면 software-visible reset guarantee가 되기 전에 별도 specification으로 정의해야 한다.

## 14. Baseline Implementation Quirk / Non-Portable Detail

다음은 현재 implementation에서 관찰되는 세부사항이며 specification review 없이 일반화하면 안 된다.

1. **DMEM coarse decode alias** — top-level selection이 canonical 32 KiB보다 넓다. `memory_map.md`의 canonical range만 지원한다.
2. **Custom DMEM write-mask sideband** — byte enable이 standard AHB signal만으로 복원되지 않고 별도 project-specific sideband로 전달된다.
3. **Vendor BRAM collision mode** — mixed-port read-during-write가 `DONT_CARE`이므로 deterministic same-word store-to-load behavior는 explicit bypass logic에 의존한다.
4. **IMEM physical placement** — ROM instance가 현재 `IF_ID_Register` 안에 있지만 future hierarchy requirement는 아니다.
5. **Vendor-generated wrapper** — 정확한 Intel/Altera generated source file은 implementation artifact이다. 향후 reproducible regeneration으로 교체할 수 있으나 이 architectural contract를 유지해야 한다.

## 15. Verification Requirements

Baseline-compatible memory implementation은 최소 다음 항목을 검증해야 한다.

- IMEM address width와 4096-word capacity.
- Canonical IMEM 전체 범위의 sequential instruction fetch.
- IF/ID stall 중 instruction/PC pairing 보존.
- DMEM 8192-word capacity와 canonical address boundary.
- 네 byte lane에 대한 `SB`.
- lower/upper halfword에 대한 aligned `SH`.
- aligned `SW` full-word write.
- `LB/LBU/LH/LHU/LW` extraction/extension.
- misaligned halfword/word load/store trap.
- same-word `SB -> load`, `SH -> load`, `SW -> load` bypass.
- partial-store bypass 시 untouched byte merge correctness.
- RAW hazard가 없을 때 false bypass 없이 BRAM data 사용.
- representative ALU, branch, JALR, store consumer에 대한 one-cycle load-use behavior.
- firmware image depth와 linker region이 physical memory capacity와 일치하는지.
- startup `.bss` zeroing이 canonical DMEM을 넘지 않는지.

## 16. Baseline Memory-Subsystem Invariant

다음은 baseline architectural invariant이다.

1. IMEM은 `0x0000_0000`의 16 KiB CPU-local instruction memory이다.
2. IMEM은 4096 x 32-bit word이며 baseline CPU runtime에서는 read-only이다.
3. DMEM은 `0x1000_0000`의 32 KiB AHB-side data memory이다.
4. DMEM은 8192 x 32-bit word와 4개의 byte write-enable lane을 가진다.
5. Architectural byte order는 little-endian이다.
6. BRAM read는 synchronous이며 AHB zero wait state가 asynchronous RAM을 의미하지 않는다.
7. Partial store는 CPU StoreAligner가 생성한 byte enable을 사용한다.
8. Load data selection/extension은 CPU LoadExtender에서 수행한다.
9. Misaligned halfword/word access는 word를 나눠 처리하지 않고 trap한다.
10. Immediate same-word store-to-load RAW behavior는 byte-wise bypass/merge로 deterministic하게 보장한다.
11. Firmware image는 physical depth와 일치하는 `IMEM.mif`, `DMEM.mif`를 사용한다.
12. System reset은 full DMEM clear를 보장하지 않으며 `.bss`는 startup firmware가 clear한다.
13. Cache, external SDRAM, DMA, coherency mechanism은 baseline memory subsystem에 포함되지 않는다.

## 17. 관련 Specification

이 문서는 다음 문서와 상호작용하거나 세부화된다.

- `memory_map.md` — canonical address allocation.
- `cpu_interface.md` — CPU/AHB signal, custom write mask, stall, forwarding contract.
- `ahb_fabric.md` — DMEM selection 및 system response mux.
- `reset_clock.md` — reset/clock contract.
- `firmware_contract.md` — linker/startup/image generation contract.

문서가 DRAFT인 동안 active RTL과 충돌이 발견되면 해당 충돌을 명시적으로 검토해야 한다. Baseline 승인 이후에는 RTL 동작으로 memory behavior를 암묵적으로 재정의하지 말고 승인된 specification에 맞춰 implementation을 변경해야 한다.