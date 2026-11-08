# Baseline SoC CPU 인터페이스 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `cpu_interface.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`.


> **Store payload/mask 계약 상태:** §7.1의 승인된 A2 계약은 유지한다. 통합 CPU는 응답 독립적인 MEM payload/mask 경로를 구현하며 §7.2는 한정된 구조·simulation 근거와 남은 한계를 기록한다. 역사적 관찰은 더 새로운 동결 fault 계약을 대체하지 않는다. 실제 C1a 조합 구조 변경은 §6.4와 [CPU 구조](21_cpu_core.ko.md#203-통합-c1a-구조와-유지되는-소유권)에 설명한다.

## 현행 Legacy 계약과 보증 범위

`CPU-001`의 Owner 수용 `VERIFIED` 범위는 `EX_funct3_AHB[2:0]` 폭과 `MEM_store_data_AHB` 명칭뿐이다. EX는 주소/제어, MEM은 정렬 store data/mask를 소유한다. Master 입력명 `MEM_read_data2`는 유지하며 load readback은 별도다. HREADY wait 안정성, DMEM-local CUSTOM_WRITE_MASK/BRAM_HAZARD, pre-bus misalignment cause 4/6, 해당 MEM의 final ERROR cause 5/7을 유지한다. 실패 instruction의 실패 side effect 및 성공 retirement는 없다. 폭/명칭 수용은 generic AMBA, 전체 ISA 증명, whole-SoC 수용을 의미하지 않는다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [RV32I46F_5SP_MMIO.v](../../rtl/core/v/top/RV32I46F_5SP_MMIO.v); [AHB_MASTER.v](../../rtl/bus/AHB_MASTER.v); [README.md](../../verification/selected_ip/README.md).

## 1. 목적

이 문서는 활성 RV32I 5-stage CPU와 SoC data interconnect 사이의 architectural boundary를 정의한다. CPU pipeline state가 구현된 AHB-style bus signal에 어떻게 매핑되는지, load/store data가 어떻게 전달되는지, bus back-pressure가 pipeline을 어떻게 정지시키는지, baseline 구현이 어떤 project-specific sideband signal에 의존하는지를 규정한다.

이 문서는 **구현된 baseline contract**를 설명하며 full AMBA AHB-Lite compliance를 주장하지 않는다. 현재 interface는 AHB-Lite-derived/AHB-style 구조이며 완전한 표준 interface의 일부 기능을 생략하거나 별도 방식으로 구현한다. System slave decode와 response mux는 `ahb_fabric.md`, memory 내부 동작은 `memory_subsystem.md`에서 정의한다.

## 2. Active Boundary

Data-side CPU/bus boundary는 다음 구조로 구성된다.

```text
RV32I46F5SPMMIO
        |
        | EX-stage address/control
        | MEM-stage store data / byte mask
        | load data / bus stall return
        v
AHB_Master_Interface
        |
        v
SoC AHB-style fabric
```

활성 `AHB_Master_Interface`는 pipeline-to-bus combinational mapping logic이다. `rtl/bus/AHB_MASTER.v`에 남아 있는 과거 FSM-style `AHB_MASTER` 코드는 주석 처리되어 있으며 active architecture가 아니다.

Baseline에는 request queue, transaction buffer, outstanding-transaction table, reorder logic, 별도 CPU-side ready/valid protocol이 없다.

## 3. Pipeline-to-Bus Phase Mapping

Baseline은 CPU pipeline을 pipelined AHB address/data 관계와 직접 맞춘다.

```text
CPU stage       Bus role
---------       -----------------------------------------
EX              Address/control phase
MEM             Data phase / load result consumption
```

Load/store instruction의 기본 흐름:

```text
Cycle N / EX
    alu_result       -> HADDR
    memory_read/write-> HTRANS / HWRITE

Clock edge
    stall이 없으면 instruction이 EX -> MEM으로 이동

Cycle N+1 / MEM
    store-aligned data -> HWDATA
    load HRDATA        -> LoadExtender
```

즉 EX/MEM pipeline register 자체가 bus address/data phase 사이의 1-cycle 관계를 제공한다. 활성 master interface는 별도의 address/data pipeline register를 추가하지 않는다.

## 4. CPU-to-Master Signal

활성 CPU는 다음 data-side signal을 `AHB_Master_Interface`로 전달한다.

| CPU signal | 논리 폭 | Producer stage | 역할 |
|---|---:|---|---|
| `EX_memory_read_AHB` | 1 | EX | Read transaction 요청 |
| `EX_memory_write_AHB` | 1 | EX | Write transaction 요청 |
| `EX_alu_result_AHB` | 32 | EX | `HADDR`용 byte address |
| `EX_funct3_AHB` | 유효 3 bits | EX | Access-type metadata / transfer-size용 의도된 입력 |
| `MEM_store_data_AHB` | 32 | MEM | Aligned store write data이며 master의 `MEM_read_data2`로 연결됨 |
| `CUSTOM_WRITE_MASK` | 4 | MEM | `StoreAligner`가 생성한 store byte-lane enable |
| `oBRAM_HAZARD` | 1 | EX/MEM 관계 | Same-word store-to-load BRAM RAW hazard indication |

### 4.1 Store-Data Naming

`MEM_store_data_AHB`는 현재 구현에서 load read data가 아니다. CPU가 이 signal을 `data_memory_write_data`로 assign하며, top에서 master의 `MEM_read_data2`로 연결되어 최종적으로 `HWDATA`가 된다.

P14는 imported baseline의 `data_memory_read_data_AHB`를 `MEM_store_data_AHB`로 정리했다. 이는 명명 변경이며 EX 주소/MEM 데이터 소유권, pipeline 동작 및 master의 `MEM_read_data2` 입력은 유지된다.

### 4.2 `EX_funct3_AHB` Width Quirk

Cleanup 전 CPU module은 `EX_funct3_AHB`를 32-bit output으로 선언했지만 실제 값은 3-bit `EX_funct3`에서 왔다. Phase 4A-3A에서 CPU port를 3 bits로 정규화했다.

Architectural information width는 **3 bits**이며 과거 32-bit port는 의도된 interface contract가 아닌 source-level width mismatch였다.

## 5. Implemented Bus Signal

활성 master가 SoC 쪽에 제공하는 signal은 다음과 같다.

| Signal | 폭 | Baseline behavior |
|---|---:|---|
| `HADDR` | 32 | EX-stage ALU result를 직접 사용 |
| `HWRITE` | 1 | EX-stage store이면 `1`, 아니면 `0` |
| `HTRANS` | 2 | 유효·정렬된 load/store 버스 전송은 `NONSEQ (2'b10)`, 그 밖 및 bus 전 misalignment는 `IDLE (2'b00)` |
| `HSIZE` | 3 | Cleanup 전 미구동; Phase 4A-3A에서는 byte/halfword/word 크기로 구동 |
| `HBURST` | 3 | 항상 `3'b000` — single transfer |
| `HWDATA` | 32 | MEM-stage aligned store data |
| `HRDATA` | 32 | Fabric read data가 CPU load path로 직접 반환됨 |
| `HREADY` | 1 | Fabric completion/back-pressure 입력 |
| `HRESP` | 2 | Phase 4A-3A CPU는 최종 ERROR를 load/store access fault로 소비함 |

Baseline은 burst sequence를 생성하지 않으며 `BUSY`, `SEQ` transfer type도 사용하지 않는다. CPU load/store 하나가 각각 독립적인 single `NONSEQ` transfer가 된다.

## 6. Address Phase Contract

### 6.1 Read

EX-stage load의 경우:

```text
EX_memory_read_AHB  = 1
EX_memory_write_AHB = 0
HADDR               = EX effective byte address
HWRITE              = 0
HTRANS               = NONSEQ
HBURST               = SINGLE
```

### 6.2 Write

EX-stage store의 경우:

```text
EX_memory_read_AHB  = 0
EX_memory_write_AHB = 1
HADDR               = EX effective byte address
HWRITE              = 1
HTRANS               = NONSEQ
HBURST               = SINGLE
```

### 6.3 Memory Operation이 없는 경우

EX에 load/store가 없으면:

```text
HTRANS = IDLE
```

이때 `HADDR`는 현재 EX ALU result를 계속 반영할 수 있다. 따라서 slave/fabric은 단순히 `HADDR`만 보고 transaction으로 해석하면 안 되고 valid transfer indication과 함께 qualify해야 한다.

### 6.4 통합 C1a Request와 Alignment 구조

CPU top의 각 exported request는 다음과 같다.

```text
EX_memory_{read,write}_AHB = EX_valid && EX_memory_{read,write}
                            && !EX_exc_valid && !EX_fault_raw && !mem_fault_now
ex_fault_now = EX_valid && !EX_exc_valid && EX_fault_raw && !mem_fault_now
mem_fault_now = bus_fault_final
```

C1a 이전 request는 `!EX_fault_raw` 대신 `!ex_fault_now`를 사용했다. 기존 바깥쪽 valid/exception/final-fault guard 아래에서 두 식은 Boolean 입력에 대해 논리적으로 동등하다. 응답-qualified 중간 predicate는 request eligibility에서 제거되며 exception sequencing에서는 유지된다. 최종 MEM ERROR에서 `!mem_fault_now`가 younger EX request를 계속 취소한다. 이 Boolean 설명은 모든 X-state equivalence를 주장하지 않는다.

Master는 low-bit carry를 포함한 **기존** effective address와 funct3로 `load_size`/`store_size`, `load_aligned`/`store_aligned`를 독립적으로 predecode한다. 이전에는 request 선택으로 생성한 `HSIZE`가 `ex_address_aligned`를 거쳐 `HTRANS`에 도달했다. 통합 구조는 마지막에 대응하는 predecoded alignment를 선택한다. 새 address adder, queue, pipeline register 또는 latency를 추가하지 않는다.

| 선택 | `HSIZE` | `HTRANS=NONSEQ`의 Alignment 조건 |
|---|---|---|
| Read funct3 `000/100` | `000` | 모든 byte offset |
| Read funct3 `001/101` | `001` | address[0]=0 |
| Read funct3 `010` | `010` | address[1:0]=00 |
| Write funct3 `000` | `000` | 모든 byte offset |
| Write funct3 `001` | `001` | address[0]=0 |
| Write funct3 `010` | `010` | address[1:0]=00 |
| 선택된 unsupported funct3 | `111` | master alignment predicate는 true; 거부를 위한 invalid size를 유지하며 legal word로 변환하지 않음 |
| Request 없음 | `010` | `HTRANS=IDLE` |

두 request 입력이 모두 asserted이면 size/alignment 선택은 read가 우선하며 `HWRITE`는 write 입력을 직접 따른다. 이는 master 입력 truth table 보존이지 CPU dual request 허용이 아니다. CPU legality/exception qualification과 standalone master의 invalid-encoding 동작은 별개다. 유효한 halfword/word의 misaligned access는 bus 전송 전에 억제하며 cause 4/6을 유지한다.

Source: [CPU request qualification](../../rtl/core/v/top/RV32I46F_5SP_MMIO.v), [active master](../../rtl/bus/AHB_MASTER.v). EX 주소·제어와 대응하는 MEM payload 소유권은 불변이다. 상세 before/after 소유권 matrix는 [CPU core §20.3](21_cpu_core.ko.md#203-통합-c1a-구조와-유지되는-소유권)에 있다.

## 7. Store Data Phase

Store data는 CPU MEM stage의 `StoreAligner`가 다음 정보를 사용해 생성한다.

- `MEM_memory_write`
- `MEM_funct3`
- forwarding이 반영된 `MEM_read_data2`
- `MEM_alu_result[1:0]`

생성된 aligned 32-bit data는 CPU에서 외부로 나가고 `AHB_Master_Interface`가 이를 직접 `HWDATA`로 매핑한다.

Byte-lane mask는 `CUSTOM_WRITE_MASK`로 별도 출력되며 master 내부에서 `CUSTOM_WRITE_MASK_OUT`으로 그대로 전달된다.

따라서 baseline store에는 두 개의 병렬 정보 경로가 존재한다.

```text
Standard-style bus path:
    HADDR / HWRITE / HTRANS / HWDATA

Project-specific lane path:
    CUSTOM_WRITE_MASK[3:0]
```

Custom mask는 DMEM BRAM wrapper가 소비한다. 이는 **AMBA AHB signal이 아니며**, portable bus semantics로 간주하면 안 된다.

SB/SH/SW의 구체적인 lane formation은 `memory_subsystem.md`에서 정의한다.

### 7.1 승인된 A2 Payload/Mask 계약

EX는 bus 주소·제어 phase를 소유하고, 이에 대응하는 MEM stage는 HWDATA와 4-bit byte-lane 의도를 모두 소유한다. StoreAligner 적격성은 `Q = MEM_valid && MEM_memory_write && !MEM_exc_valid`여야 한다. Aligned data는 HWDATA에, mask는 `CUSTOM_WRITE_MASK`에 직접 연결해야 한다. **두 출력 모두 최종 HRESP/mem_fault_now와 독립적이어야 하며 mask에 `& !mem_fault_now` qualification을 추가해서는 안 된다.** MEM funct3, forwarding된 source data, address offset은 모두 동일 store에 속해야 한다. 트랜잭션 정체 중에는 소유 payload와 lane 의도가 안정적으로 유지되어야 한다.

`CUSTOM_WRITE_MASK`는 master가 그대로 전달하는 DMEM-local 비표준 lane sideband이다. 범용 AHB/AXI 쓰기 권한이나 수락 신호가 아니며 APB/VRAM은 이를 소비하지 않는다. 0이 아닌 payload/mask가 독립적으로 실제 쓰기를 발생시켜서는 안 된다. DMEM은 수락된 data-phase 소유자의 저장된 주소 및 등록된 `write_en_reg`와, BRAM edge에서 동일 소유자에 대응하는 MEM 데이터·byte enable로 commit한다. [Memory ownership](02_memory_subsystem.ko.md#61-bram-edge에서-수락된-store의-소유권)을 참조한다. 현재 EX HADDR는 이미 다음 트랜잭션에 속할 수 있으므로 현재 MEM mask와 짝지어서는 안 된다.

CPU의 최종 ERROR 예외 처리와 더 어린 request 취소는 계속 응답에 의해 qualify한다. 최종 ERROR에서 HWDATA나 mask를 0으로 만들 필요는 없다. Slave는 잘못된 트랜잭션의 부작용이 commit되기 전에 이를 거부해야 하며 응답 독립적인 데이터 생성이 failed-store-zero-side-effect 요구를 완화하지 않는다. DMEM zero-wait/OKAY, fabric/default ERROR, slave acceptance, 모든 lane encoding, 부분 쓰기, 등록된 RAW bypass를 유지한다. 이 계약은 APB latency, global-HREADY write gate, 범용 bus compliance 주장을 추가하지 않는다.

### 7.2 A2 Acceptance와 한정된 검증 상태

Acceptance에는 실제 elaborated/optimized design에서 sequential/blackbox 경계를 명시한 두 출력의 응답 독립성, 실제 DMEM write-edge 주소·데이터·lane pairing, wait 중 payload/lane 안정성 검사가 필요하다. 연속 store와 DMEM↔APB/VRAM/default 전환에서 수락된 성공 store마다 정확한 주소·lane의 쓰기가 한 번 발생하고, 미수락·취소·거부 store에서는 쓰기가 없어야 한다. 첫/최종 ERROR, partial-store RAW merge, recovery를 포함한다.

**구현 관찰:** CPU `store_aligner.memory_write`는 정확히 `Q`이며 data/mask는 `MEM_store_data_AHB`, `CUSTOM_WRITE_MASK`에 직접 연결되고 master가 그대로 전달한다. 이 경로는 C1a 이전부터 존재했다. Load 경로의 final-fault qualification은 유지되며 payload 독립성이 모든 CPU 제어에 적용되는 것은 아니다.

| 의무 | 기존 통합 소스 evidence / 한계 |
|---|---|
| Response-to-data/mask와 SCC | 저장된 unoptimized/optimized graph에서 SCC 없음, response-to-output reachability 여섯 검사는 negative이며 blackbox 일곱 개를 명시한다. Isolated response-data/mask mutant를 거부한다. Whole-SoC/vendor-netlist 증명이 아니다. |
| Ownership / lanes / waits / faults | 서로 다른 source-role을 검증한 뒤 before/after 22,000-cycle directed trace가 일치한다. Transaction별 checker는 physical store 22개, bus error 18개, partial RAW, cross-slave activity를 다룬다. Isolated lane/address/owner mutant는 의도한 결함으로 거부된다. Hold 검사는 2169 pairs를 다룬다. Count만이 oracle인 것은 아니다. |
| Master decode / alignment | 역할별 실제 compiler-execution record가 before/after/isolated-mutant를 결부한다. 각각 4096 vectors에서 oracle failure 0/0/512이며 mutant checker/guard/parent가 거부한다. 유한한 standalone-master domain이지 whole-CPU formal equivalence가 아니다. |
| Reset / integration | 자연 reset/recovery, precise fault cause/PC 및 실제 AES-core 통합 검사가 실행된 case를 뒷받침한다. Behavioral memory model은 vendor BRAM collision 동작이나 board reset 안전을 입증하지 않는다. |

이 소스에 결부된 관찰에는 한정된 composite review 근거가 있으며 공개 derivative packaging은 미완료이다. 해당 부분 범위에서만 ‘전부 미검증’ 설명을 대체한다. Tracker requirement 승격, 더 넓은 trap/ISA 의무 종결, universal SCC 부재, fitted timing, 외부 I/O/CDC/board acceptance를 뜻하지 않는다. Run별 record는 명세 밖에서 불변으로 보존하며 문서 수정으로 과거 source binding을 소급 변경하지 않는다.

### 7.3 향후 Shared-Buffer Interface (비규범적)

향후 CPU/DMA 공유에는 master별 request 소유권, arbitration, capture된 주소·데이터·strobe가 필요하다. 여기에는 독립적으로 수락되는 주소·데이터 channel의 pairing과 WSTRB 또는 동등 lane 의도가 포함된다. CPU `mem_fault_now`는 자신의 예외·request 취소에 유용하지만 shared BRAM WEN/byte strobe나 다른 master의 수락된 쓰기를 gate해서는 안 된다. 권한, 동일 주소 ordering, collision/bypass, visibility, completion은 별도 검토 interface가 필요하다. [향후 memory 고려사항](02_memory_subsystem.ko.md#18-향후-shared-dmem-buffer-고려사항-비규범적)을 참조한다. 이 note는 AXI/DMA 구현, 주소 배정, fence/coherency 변경 또는 동결된 미래 설계를 승인하지 않는다.

## 8. Load Return Path

Fabric `HRDATA`는 `AHB_Master_Interface`에서 변형 없이 CPU로 전달된다.

```text
HRDATA -> HRDATA_to_CPU -> HRDATA_FROM_AHB -> LoadExtender
```

CPU `LoadExtender`는 MEM-stage metadata(`MEM_memory_read`, `MEM_funct3`, `MEM_alu_result[1:0]`)를 사용해 반환된 32-bit word에서 byte/halfword/word를 선택하고 sign/zero extension을 수행한다.

따라서:

- bus/fabric은 32-bit word container를 반환하고,
- subword extraction은 CPU가 담당하며,
- DMEM subword write는 custom write mask로 제어되고,
- CPU가 LB/LH/SB/SH를 지원한다고 해서 peripheral MMIO도 자동으로 subword access를 지원하는 것은 아니다.

Peripheral MMIO access policy는 `memory_map.md`, `firmware_contract.md`에서 정의한다.

## 9. Transfer Size (`HSIZE`) 상태

### 9.1 Cleanup 전 관찰과 Phase 4A-3A 구현

`AHB_Master_Interface`는 다음 port를 선언한다.

```text
input  EX_funct3[2:0]
output HSIZE[2:0]
```

Cleanup 전 module에는 `HSIZE` driver가 없었지만 Phase 4A-3A에서 load/store funct3로 결정적으로 구동한다.

따라서 검증된 load/store 범위에서 `HSIZE`는 정의된 project bus signal이며 미지원 encoding은 성공한 word 전송으로 처리되지 않는다.

### 9.2 유지되는 DMEM sideband 동작

`HSIZE`가 구동돼도 DMEM data path는 project 전용 sideband를 유지한다.

- DMEM은 CPU에서 별도의 4-bit byte-enable mask를 받는다.
- `AHB_MEMORY_SLAVE`는 `HSIZE`에서 byte enable을 생성하지 않는다.
- AHB-to-APB bridge는 `HSIZE`를 검증하고 정렬된 word MMIO만 허용하며 APB byte strobe는 생성하지 않는다.
- Load subword extraction은 CPU 내부에서 32-bit word를 대상으로 수행한다.

이 sideband는 baseline DMEM에 국한되며 일반 AHB/AXI 계약이 아니다.

### 9.3 Phase 4A-3A 활성 mapping

Phase 4A-3A는 아래 mapping을 채택했다. 전체 AHB-Lite compliance 주장은 아니다.

| ISA access | Project `HSIZE` |
|---|---|
| byte (`LB/LBU/SB`) | `3'b000` |
| halfword (`LH/LHU/SH`) | `3'b001` |
| word (`LW/SW`) | `3'b010` |

지향 HSIZE 테스트에서 위 여덟 가지 load/store encoding을 검증했다.

## 10. Bus Back-Pressure와 Pipeline Stall

Master는 다음 signal을 생성한다.

```text
bus_stall_req = ~HREADY
```

그리고 이를 CPU `HazardUnit`으로 반환한다.

`bus_stall_req == 1`이면 active hazard logic이 highest-priority full-pipeline freeze를 적용한다.

```text
IF_ID_stall  = 1
ID_EX_stall  = 1
EX_MEM_stall = 1
MEM_WB_stall = 1

IF_ID_flush  = 0
ID_EX_flush  = 0
EX_MEM_flush = 0
MEM_WB_flush = 0
```

이 override는 combinational hazard logic의 다른 hazard/trap/flush 결정 뒤에서 적용된다. 따라서 `HREADY`가 low인 동안 bus back-pressure가 branch/trap flush 진행과 load-use 처리보다 높은 effective priority를 가진다.

### 10.1 Stall 중 Stability Requirement

CPU pipeline 자체가 transaction state를 hold하기 때문에, slave/fabric이 `HREADY`를 deassert하면 full-pipeline freeze에 의해 관련 address/control/data state가 transfer 완료 시점까지 안정적으로 유지되어야 한다.

Baseline에는 CPU pipeline을 계속 진행시키면서 transaction을 따로 보존할 master-side skid buffer나 request register가 없다.

### 10.2 `HREADY` Contract

Fabric은 global `HREADY`를 의미 없이 낮추면 안 된다. Master의 `bus_stall_req`는 `HTRANS`로 추가 qualify하지 않고 `~HREADY`만 사용하므로, `HREADY=0`이면 CPU 전체 pipeline이 정지한다.

System-level `HREADY` generation은 `ahb_fabric.md`에서 정의한다.

## 11. Back-to-Back Transfer

### 11.1 Zero-Wait Slave

Baseline DMEM처럼 zero-wait slave에서는 pipeline이 자연스럽게 매 cycle 새로운 address phase를 발행할 수 있다.

```text
Cycle N     EX: access A address/control
            MEM: previous instruction data phase

Cycle N+1   EX: access B address/control
            MEM: access A data phase
```

이것이 EX/MEM pipeline mapping의 의도된 high-throughput 동작이다.

### 11.2 Wait-State Slave

Selected path가 `HREADY=0`을 내보내면 hazard unit이 모든 pipeline stage를 freeze한다. 따라서 EX-stage address/control과 MEM-stage data-phase 정보는 fabric이 stall을 해제할 때까지 유지된다.

이 동작은 APB setup/access sequence 때문에 1 HCLK보다 긴 시간이 걸릴 수 있는 AHB-to-APB bridge transfer에서 특히 중요하다.

## 12. Load-Use Hazard와의 관계

CPU는 load 바로 다음 instruction이 load result를 사용하는 경우 별도의 one-cycle load-use interlock을 가진다.

Bus stall이 없을 때 load-use hazard가 검출되면:

```text
IF_ID_stall = 1
ID_EX_flush = 1
```

을 적용하고 older load는 WB 방향으로 진행시킨다. Consumer는 이후 WB-stage forwarding으로 load result를 받으며, MEM-load result를 같은 cycle의 EX combinational path로 직접 forwarding하지 않는다.

`bus_stall_req`가 동시에 assert되면 bus-stall override가 모든 stage를 freeze하고 bus 완료까지 load-use flush도 억제한다.

두 stall은 역할이 다르다.

- **load-use stall**: register data availability 문제 해결
- **bus stall**: interconnect transaction completion 문제 해결

## 13. Store-to-Load BRAM Hazard Sideband

CPU는 추가로 다음 signal을 생성한다.

```text
oBRAM_HAZARD =
    EX_memory_read &&
    MEM_memory_write &&
    (EX effective address[31:2] == MEM address[31:2])
```

즉 MEM의 store 바로 뒤 EX의 load가 동일한 32-bit word를 접근하는 경우를 검출한다.

`oBRAM_HAZARD`는 DMEM slave로 직접 전달되며, DMEM은 store data와 byte mask를 사용해 byte-wise merge/bypass를 수행한다. 이 signal은 **memory-implementation-specific**이며 generic bus protocol의 일부가 아니다.

Architectural data result는 `memory_subsystem.md`에서 정의한다.

## 14. Alignment와 Exception Boundary

CPU는 effective byte address를 계산한 뒤 bus로 내보낸다. Misaligned halfword/word access는 CPU exception path에서 검출된다.

Baseline alignment requirement:

- byte load/store: 모든 byte address 허용
- halfword load/store: address bit `[0] == 0`
- word load/store: address bits `[1:0] == 00`

Bus interface는 misaligned access를 여러 transfer로 split하지 않으며 silent realignment도 하지 않는다.

Store의 경우 `StoreAligner`가 잘못 정렬된 SH/SW lane 조합에 zero mask를 생성하기도 하지만, 이는 defensive behavior이며 architectural exception mechanism 자체는 아니다.

## 15. Bus Response / Error Visibility

Cleanup 전에는 `AHB_Master_Interface`에 `HRESP` 입력이 없고 CPU에도 bus-error indication이 전달되지 않았다. Phase 4A-3A는 fabric의 선택된 `HRESP`를 CPU에 직접 연결해 최종 load/store ERROR를 처리한다. 조합 master 자체에는 계속 `HRESP` 입력이 없다.

Cleanup 전 CPU는 OKAY/ERROR를 구별하지 못했지만 현재 CPU는 data-bus load/store fault를 구별한다. Unmapped access 정책은 `memory_map.md`/`ahb_fabric.md`의 계약과 Phase 4A-3A directed bus 근거가 소유한다.

그 밖의 precise-trap case(`TRAP-002/003`)는 `baseline_cleanup.md`의 기존 상태를 유지한다. C1a 설명은 기존에 검토된 범위를 다시 열거나 무관한 의무를 종결하지 않는다.

## 16. Reset Behavior

CPU와 pipeline은 SoC system reset으로 reset된다. Interface 관점에서는 reset 상태에서 normal execution이 재개되기 전까지 architecturally valid한 load/store request가 존재하지 않아야 한다.

Active master 자체는 대부분 combinational이며 reset해야 할 active transaction state를 별도로 가지고 있지 않다. Wait-state 중 transaction preservation은 master-local state가 아니라 pipeline stall이 담당한다.

Memory contents와 firmware image reset semantics는 `memory_subsystem.md`에서 정의한다.

## 17. Baseline Interface Invariant

다음 항목은 baseline contract invariant이다.

1. CPU가 유일한 active data-bus master이다.
2. EX stage가 load/store address와 request control을 담당한다.
3. MEM stage가 store data와 load-result interpretation을 담당한다.
4. Load/store 하나는 single `NONSEQ` transfer를 생성하며 burst는 없다.
5. `HWDATA`는 CPU MEM-stage aligned store data이다.
6. `HRDATA`는 32-bit word로 반환되고 `LoadExtender`가 해석한다.
7. DMEM subword write는 4-bit custom write-mask sideband에 의존한다.
8. Same-word store-to-load BRAM collision 처리는 dedicated `oBRAM_HAZARD` sideband에 의존한다.
9. `HREADY=0`이면 모든 pipeline stage가 freeze되고 stall이 해제될 때까지 pipeline flush 진행도 억제된다.
10. CPU는 대응하는 MEM owner의 최종 ERROR `HRESP=01`, `HREADY=1`을 소비한다. 조합 master 자체에는 `HRESP` 입력이 없다.
11. Cleanup 전 `HSIZE`는 undriven이었으나 Phase 4A-3A에서 load/store 크기에 맞게 구동한다.
12. Active interface에는 master-local buffering이나 multiple-outstanding transaction 지원이 없다.

## 18. Known Implementation Quirks / Open Clarifications

### 18.1 과거 미구동 `HSIZE` — Phase 4A-3A load/store 범위 해결

Cleanup 전 master는 `HSIZE`를 선언만 했지만 Phase 4A-3A에서 byte/halfword/word 크기로 구동한다. 전체 AMBA compliance 주장과는 별개다.

### 18.2 과거 CPU `EX_funct3_AHB` Width Mismatch — 해결

Cleanup 전 32-bit output을 Phase 4A-3A에서 3-bit port로 정규화했다. P14는 §18.3의 store-data 명명 정리도 적용했다. Tracker acceptance는 별도다.

### 18.3 Store-Data Signal Name

`MEM_store_data_AHB`는 aligned MEM-stage store write data를 전달한다. P14는 과거의 잘못된 `data_memory_read_data_AHB` 이름을 교체했으며 `HWDATA` 의미와 load read 경로는 유지된다.

### 18.4 Non-Standard Byte-Mask Sideband

`CUSTOM_WRITE_MASK`는 standard bus transfer-size/strobe semantics를 우회한다. 현재 baseline DMEM integration에서는 유효하지만 portable interconnect contract가 아니며 계획된 AXI architecture로 그대로 확장하면 안 된다.

### 18.5 DMEM-Specific RAW Hazard Sideband

`oBRAM_HAZARD`는 CPU pipeline state와 physical DMEM collision workaround를 직접 결합한다. 향후 cache/external-memory/AXI 구조에서는 generic bus signal로 취급하지 말고 이 dependency를 제거하거나 local하게 캡슐화해야 한다.

### 18.6 CPU Bus-Error Input 부재

Cleanup 전에는 `HRESP`가 CPU에 전달되지 않았다. Phase 4A-3A에서 data-bus access-fault 부분은 구현했고 전체 trap/retirement cleanup은 열려 있다.

## 19. Verification Requirements

Independent CPU/bus verification은 최소 다음 항목을 검증해야 한다.

- isolated load/store transfer
- back-to-back load/load, store/store, load/store, store/load
- SB/SH/SW byte-mask behavior
- LB/LBU/LH/LHU/LW extraction/extension
- aligned vs misaligned memory operation
- same-word store-to-load byte-wise bypass
- one-cycle load-use interlock
- address/data phase에서 `HREADY` wait-state insertion
- `HREADY=0` 동안 full pipeline stability
- bus stall과 branch/trap/load-use가 동시에 발생하는 경우
- APB bridge wait-state 동안 transaction preservation
- 결정적인 `HSIZE`와 invalid-size 거부; standalone master와 CPU legality qualification 구분
- 최종 `HRESP` 소비, precise cause/PC, 실패 side-effect 억제

향후 `HSIZE`, bus-error handling, custom sideband replacement를 변경하려면 RTL 구현 전에 이 specification을 먼저 업데이트해야 한다.

## 20. Source Anchors

이 specification의 주요 active implementation source:

- `rtl/core/v/top/RV32I46F_5SP_MMIO.v`
- `rtl/core/v/hazard_forward/Hazard_Unit.v`
- `rtl/core/v/mem_stage/StoreAligner.v`
- `rtl/core/v/mem_stage/LoadExtender.v`
- `rtl/core/v/mem_stage/Exception_Detector.v`
- `rtl/bus/AHB_MASTER.v`
- `rtl/bus/AHB_MEMORY_SLAVE.v`
- `rtl/soc/AMBA_SoC_TOP.v`

관련 specification:

- `soc_architecture.md`
- `memory_map.md`
- `memory_subsystem.md`
- `ahb_fabric.md`
- `firmware_contract.md`

## Phase 4A-2 승인된 data-bus fault 계약 (Phase 4A-3A 버스 접근 부분 구현)

Project HRESP는 2비트 `00=OKAY`, `01=ERROR`이며 전체 AMBA response set을 뜻하지 않는다. A2 ERROR는 첫 cycle `HRESP=ERROR,HREADY=0`, 최종 cycle `HRESP=ERROR,HREADY=1`이다. 최종 load/store ERROR에서 `mcause=5/7`, `mepc=해당 명령 PC`; 실패 load는 GPR writeback 없음, 실패 store는 side effect 없음, 실패 명령은 성공 retire 없음. Misalignment cause 4/6은 구별되고 우선한다. Fetch는 이 AHB data path를 사용하지 않아 instruction-fetch AHB fault를 정의하지 않는다.

**구현 근거:** Phase 4A-3A CPU 단독·SoC 통합 테스트에서 cause/PC, 실패 load writeback 억제, younger flush, misalignment 우선순위를 확인했다. CPU master는 byte/halfword/word `HSIZE`를 구동한다. 기타 trap/retirement cleanup은 계속 열린 항목이다.
