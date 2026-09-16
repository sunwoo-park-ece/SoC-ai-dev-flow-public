# Baseline SoC CPU 인터페이스 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `cpu_interface.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 `HSIZE` 미구동·`HRESP` 미소비를 ‘현재 baseline’으로 서술한 부분은 cleanup 전 기록이다. 아래 Phase 4A-3A data-bus fault 계약이 현행 구현 범위다. 기타 CPU cleanup은 열린 상태다.

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
| `data_memory_read_data_AHB` | 32 | MEM | **이름이 잘못된 signal:** 실제로는 aligned store write data이며 master의 `MEM_read_data2`로 연결됨 |
| `CUSTOM_WRITE_MASK` | 4 | MEM | `StoreAligner`가 생성한 store byte-lane enable |
| `oBRAM_HAZARD` | 1 | EX/MEM 관계 | Same-word store-to-load BRAM RAW hazard indication |

### 4.1 Naming Quirk

`data_memory_read_data_AHB`는 현재 구현에서 load read data가 아니다. CPU가 이 signal을 `data_memory_write_data`로 assign하며, top에서 master의 `MEM_read_data2`로 연결되어 최종적으로 `HWDATA`가 된다.

이 이름은 imported baseline RTL에 존재하기 때문에 유지되어 있을 뿐이다. 신규 코드와 specification에서는 의미상 **store write data**로 취급한다.

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

SoC fabric에는 `HRESP` path가 있지만 active `AHB_Master_Interface`에는 **`HRESP` input이 없고**, CPU에도 bus-error indication이 전달되지 않는다.

따라서 baseline CPU는 이 interface를 통해 OKAY response와 bus error를 architectural하게 구분할 수 없다.

Unmapped access의 현재 동작은 `memory_map.md`/`ahb_fabric.md`에서 별도로 정의한다. SoC 내부에 `HRESP` net이 존재한다는 이유만으로 software가 robust access-fault behavior를 기대하면 안 된다.

Architectural bus-error exception을 추가하려면 향후 specification과 CPU interface 변경이 필요하다.

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
10. CPU는 baseline에서 `HRESP`를 소비하지 않는다.
11. Cleanup 전 `HSIZE`는 undriven이었으나 Phase 4A-3A에서 load/store 크기에 맞게 구동한다.
12. Active interface에는 master-local buffering이나 multiple-outstanding transaction 지원이 없다.

## 18. Known Implementation Quirks / Open Clarifications

### 18.1 과거 미구동 `HSIZE` — Phase 4A-3A load/store 범위 해결

Cleanup 전 master는 `HSIZE`를 선언만 했지만 Phase 4A-3A에서 byte/halfword/word 크기로 구동한다. 전체 AMBA compliance 주장과는 별개다.

### 18.2 과거 CPU `EX_funct3_AHB` Width Mismatch — 해결

Cleanup 전 32-bit output을 Phase 4A-3A에서 3-bit port로 정규화했다. §18.3의 store-data 명명 문제는 열린 상태다.

### 18.3 Misleading Store-Data Signal Name

`data_memory_read_data_AHB`는 실제로 store write data를 전달한다. 향후 `HWDATA` 의미가 드러나는 이름으로 정리하는 것이 좋다.

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
- 현재 baseline behavior가 `HSIZE`에 의존하지 않는지 확인
- `HRESP`가 현재 architectural하게 소비되지 않는지 확인

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
