# Baseline SoC 메모리 서브시스템 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `memory_subsystem.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`.

> **Store payload/mask 계약 상태:** 통합 CPU는 승인된 A2 응답 독립적인 MEM payload/lane 경로를 구현한다. §7.4는 소스에 결부된 한정적 구현 관찰과 acceptance 의무·물리적 한계를 구분한다. 공개 derivative evidence packaging과 전체 acceptance는 별도이며 명세 수정 자체가 검증은 아니다.

## 현행 Legacy 계약과 보증 범위

IMEM은 IF/ID가 instantiate하는 4096×32(16 KiB), DMEM은 byte-enable을 갖는 8192×32(32 KiB) little-endian이다. 수용된 store 소유권, 응답 독립 MEM payload/mask, 등록된 byte-wise RAW merge, 1-cycle load-use interlock을 유지한다. Open model은 image가 없을 때 IMEM을 NOP, DMEM을 0으로 초기화하지만 이 기본값은 vendor BRAM 초기화/collision/reset을 증명하지 않는다. Startup은 미리 적재된 IMEM과 초기화 DMEM을 전제로 BSS만 software로 지우며 ROM에서 `.data`를 복사하지 않는다. System reset은 DMEM array를 지우지 않는다. 새 플랫폼 memory binding은 별도 재검증 대상이다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [IF_ID_Register.v](../../rtl/core/v/pipeline_regs/IF_ID_Register.v); [AHB_MEMORY_SLAVE.v](../../rtl/bus/AHB_MEMORY_SLAVE.v); [IMEM.sv](../../verification/models/memory/IMEM.sv); [memory.sv](../../verification/models/memory/memory.sv); [start.S](../../firmware/bsp/start.S).

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

통합 top-level은 유효한 transfer, 지원 size와 alignment로 qualify한 canonical 32 KiB만 선택한다. 과거 64 KiB decode/상단 절반 alias는 cleanup 전 기록이며 현재 상단 절반은 DMEM 대신 default ERROR responder로 전달된다. 두 번째 memory region을 배정하지 않는다. [Fabric decode](04_ahb_fabric.ko.md#4-address-phase-slave-decode)를 참조한다.

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

### 6.1 BRAM Edge에서 수락된 Store의 소유권

실제 DMEM 쓰기는 수락된 합법적인 store data phase에 속해야 한다. 주소 phase가 전진하는 edge(`HREADY_IN=1`)에서 유효한 `HSEL`/`HTRANS`와 `HWRITE`가 등록된 `addr_reg`, `write_en_reg`를 설정하며, 유효한 선택 transfer가 없으면 다음 쓰기 권한을 해제한다. Bus wait 동안 이 register들은 유지된다. BRAM write edge는 **edge 직전**의 등록된 주소/`write_en_reg`와 동일 store에 대응하는 live MEM-stage `HWDATA`, `byteena_a`를 사용한다. 같은 edge의 register 갱신은 다음 트랜잭션에만 적용된다.

0이 아닌 데이터나 byte-lane 의도만으로 쓰기를 허가해서는 안 된다. 미수락·취소·거부된 store는 메모리·주변장치 부작용을 발생시키지 않아야 한다. Fabric/default ERROR와 APB/VRAM 거부는 DMEM의 고정 OKAY 응답과 별개이며, 소유 fabric/slave는 잘못된 store의 부작용이 commit되기 전에 이를 거부해야 한다. ERROR에서 HWDATA를 0으로 만드는 것은 요구사항이 아니며 이 수락 규칙을 대체하지 않는다.

현재 single-master 통합에서는 등록된 DMEM 쓰기 권한과 fabric의 DMEM data-phase 소유자가 함께 전진한다. 다른 slave의 stall 중 제시된 DMEM 주소는 아직 수락되지 않았다. 최종 ERROR는 다음 주소 phase를 취소한다. `write_en_reg`는 등록된 DMEM 권한이며 현재 HSEL의 조합 복사본이 아니다. 이 계약은 BRAM wren에 global-HREADY AND gate나 새로운 DMEM wait state를 추가하지 않는다.

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

### 7.3 응답 독립적인 Payload와 Lane 의도

Aligned store data와 `CUSTOM_WRITE_MASK`는 모두 동일 MEM store의 적격성 `Q = MEM_valid && MEM_memory_write && !MEM_exc_valid`로 생성하며 최종 `HRESP`/`mem_fault_now`와 독립적이어야 한다. Mask에 `!mem_fault_now`를 AND해서는 안 된다. Custom mask는 DMEM-local 비표준 byte-lane sideband이며 transaction acceptance나 범용 AHB/AXI 쓰기 권한이 아니다. APB와 VRAM은 이를 소비하지 않는다.

Stall 및 연속 SB/SH/SW transfer에서도 주소·payload·mask는 동일한 수락 store에 대응해야 한다. 부분 쓰기는 선택되지 않은 byte를 보존해야 한다. RAW bypass는 적격 edge에서 동일 store의 데이터·mask·hazard indication을 capture하고, 이 등록된 값과 BRAM 데이터를 byte 단위로 merge해야 한다. 이전 store의 mask나 다음 EX 주소로 현재 쓰기를 qualify해서는 안 된다. 기존 lane encoding, zero-wait DMEM timing, deterministic same-word bypass는 유지한다.

Acceptance에는 실제 write-edge 주소·데이터·lane, 성공 store의 exactly-once 소유권, 거부·취소 transfer의 zero write, 연속 lane 변경, partial RAW merge, DMEM과 APB/VRAM/default 사이의 전환 및 wait와 두 ERROR phase를 확인해야 한다. 구조 검사는 sequential/blackbox 경계를 명시하고 response-to-data와 response-to-mask 의존성을 포함해야 한다. 이 acceptance 의무는 유지하며 한정된 구현 관찰은 아래에 분리한다.

### 7.4 한정된 구현 관찰과 한계

통합 CPU는 StoreAligner 적격성을 정확히 `Q`에 연결하고 data/mask를 조합 master를 통해 직접 전달한다. 이 응답 독립 경로는 C1a 이전부터 존재했다. C1a는 master size/alignment predecode와 EX request eligibility를 재구성하며 memory stage, write gate 또는 새 lane encoding을 추가하지 않는다. [CPU 구조](21_cpu_core.ko.md#203-통합-c1a-구조와-유지되는-소유권)와 [interface 검증 상태](03_cpu_interface.ko.md#72-a2-acceptance와-한정된-검증-상태)를 참조한다.

소스에 결부된 composite review는 실행된 transaction/write-edge ownership, partial RAW, held payload, reset/recovery case와 명시된 sequential/blackbox 경계의 저장된 structural graph 검사를 뒷받침한다. 별도의 유한한 master decode/alignment 근거가 이를 보충하며 physical memory edge나 whole-CPU equivalence를 독립적으로 증명하지 않는다. 과거 실행 record는 이후 문서 tree가 아니라 원래 입력에 결부된다.

Portable behavioral memory 관찰은 vendor `DONT_CARE` collision 동작, fitted timing, CDC 또는 board/reset assurance를 종결하지 않는다. 요구되는 byte-merge 계약은 불변이다. 공개 derivative packaging과 전체 acceptance는 미완료이며 tracker 상태를 승격하지 않는다.

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

실제 sideband qualification은 다음과 같다.

```text
oBRAM_HAZARD = EX_memory_read_AHB && MEM_valid && MEM_memory_write
               && !MEM_exc_valid
               && (EX effective address[31:2] == MEM effective address[31:2])
```

`EX_memory_read_AHB`에는 CPU valid/exception/raw-EX-fault/final-MEM-fault guard가 이미 포함된다. 대응하는 store의 payload/mask는 MEM이 소유하며 sideband는 범용 AHB 쓰기 권한이 아니다.

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
- stack top -> exclusive canonical DMEM end, `0x1000_8000`, 16-byte aligned.

### 12.2.1 Initial Stack ABI and Capacity Boundary

Project build는 `-march=rv32i -mabi=ilp32`(ILP32E가 아닌 standard ILP32)를 사용한다. `__stack_top = ORIGIN(DMEM) + LENGTH(DMEM) = 0x1000_8000`은 exclusive DMEM end이자 비어 있는 downward-growing stack의 초기 SP다. Standard ABI procedure는 `sp`를 16-byte 정렬로 진입하고 정렬을 유지해야 한다(MUST). Linker ASSERT는 초기 stack symbol의 하위 네 bit가 0이 아니면 거부한다. Symbol assignment는 exclusive boundary에 section이나 byte를 할당하지 않는다. 첫 stack frame은 storage 접근 전에 `sp`를 그 주소 아래로 내린다.

각 linked image의 initialized RAM과 `__bss_end`는 canonical DMEM 안에 사용 가능한 stack headroom을 남겨야 한다(MUST). 해당 image의 ELF/map과 startup binding을 확인한다. Alignment만으로 최대 call depth, worst-case stack capacity, overflow detection이나 고정 reserved stack budget을 증명하지 않는다. 그런 capacity/overflow 보증을 새로 만들지 않는다. Startup 순서는 `mtvec → sp → .bss clear → main`이며 initialized data는 ROM copy가 아닌 preload다.

### 12.3 Reset은 DMEM 전체를 Clear하지 않음

System reset은 CPU와 memory-wrapper control state를 reset하지만 DMEM array 전체를 architectural하게 erase하지 않는다.

Startup code는 다음 순서로 C runtime semantics를 만든다.

1. `mtvec`를 `__trap_entry`로 설정.
2. `sp`를 `__stack_top`으로 설정.
3. `__bss_start`부터 `__bss_end`까지 word store로 clear.
4. `main` 호출.

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

1. **역사적 DMEM coarse decode alias** — cleanup 전 top-level selection은 canonical 32 KiB보다 넓었다. 현재 접근에는 `memory_map.md`, `ahb_fabric.md`의 승인된 canonical-range/error 계약이 적용되며, 이 역사적 관찰은 alias 접근을 허용하지 않는다.
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

이는 acceptance 요구사항이며 모든 case나 physical memory primitive가 증명되었다는 주장이 아니다. §7.4는 한정된 구현 부분 범위만 기록한다.

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

- [CPU microarchitecture와 source mapping](21_cpu_core.ko.md#203-통합-c1a-구조와-유지되는-소유권).
- [CPU/AHB payload 소유권](03_cpu_interface.ko.md#71-승인된-a2-payloadmask-계약).
- [통합 fabric decode](04_ahb_fabric.ko.md#4-address-phase-slave-decode).
- 구현 anchor: [CPU StoreAligner/RAW wiring](../../rtl/core/v/top/RV32I46F_5SP_MMIO.v), [master passthrough](../../rtl/bus/AHB_MASTER.v), [DMEM captured write edge와 byte merge](../../rtl/bus/AHB_MEMORY_SLAVE.v), [top-level selection](../../rtl/soc/AMBA_SoC_TOP.v).

- `memory_map.md` — canonical address allocation.
- `cpu_interface.md` — CPU/AHB signal, custom write mask, stall, forwarding contract.
- `ahb_fabric.md` — DMEM selection 및 system response mux.
- `reset_clock.md` — reset/clock contract.
- `firmware_contract.md` — linker/startup/image generation contract.

문서가 DRAFT인 동안 active RTL과 충돌이 발견되면 해당 충돌을 명시적으로 검토해야 한다. Baseline 승인 이후에는 RTL 동작으로 memory behavior를 암묵적으로 재정의하지 말고 승인된 specification에 맞춰 implementation을 변경해야 한다.

## 18. 향후 Shared-DMEM Buffer 고려사항 (비규범적)

AXI/DMA 공유는 architecture proposal일 뿐이며 주소 배정, DMA/AXI 구현 또는 동결된 미래 설계는 승인되지 않았다. 가능한 shared-buffer interface는 독립적인 CPU/DMA request, master-owner arbitration, capture된 transaction identity/주소/데이터/byte strobe(WSTRB 또는 동등 신호), 합법적인 precommit acceptance를 사용한다. CPU `mem_fault_now`는 CPU-local이며 shared BRAM WEN/byte strobe나 다른 master의 트랜잭션을 qualify해서는 안 된다.

향후 설계 검토에서는 주소·데이터 channel pairing, 활성 byte/beat별 권한 및 partition 경계, producer-consumer 소유권, 부분 쓰기, 동일 주소 arbitration, read-during-write collision/bypass, ordering과 visibility를 결정해야 한다. Completion은 소유 트랜잭션의 commit/visibility 시점을 기준으로 정의하는 방향을 검토한다. 나중의 error는 되돌릴 수 없는 쓰기를 취소하지 못하므로 burst partial-completion과 atomic buffering 중 명시적인 정책이 필요하다. 정의되지 않은 BRAM collision이나 CPU 전용 bypass에 의존한다는 의미는 아니다. Cache/coherency와 software synchronization은 별도 계약이 필요하며 현재 no-DMA baseline과 FENCE 의미는 유지한다.
