# Baseline SoC AHB Fabric 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `ahb_fabric.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 broad decode/zero-OKAY/미구동 `HSIZE` 설명은 cleanup 전 baseline 기록이다. 마지막 Phase 4A-3A 문단이 현행 버스 fault/decode/response 동작을 우선 규정하며 나머지 미래 기능은 그대로 열린 상태다.

## 1. 목적

이 문서는 CPU-side `AHB_Master_Interface`와 다음 세 개의 top-level AHB-side target 사이의 baseline SoC data interconnect를 정의한다.

1. DMEM
2. VGA / dual-VRAM subsystem
3. AHB-to-APB bridge

Top-level slave selection, address phase에서 data phase로의 select 유지, response multiplexing, back-pressure propagation, unmapped-access behavior, 그리고 future architecture에 그대로 승격해서는 안 되는 implementation gap을 규정한다.

이 문서는 **현재 구현된 AHB-style / AHB-Lite-derived baseline**을 설명하는 것이며 완전한 AMBA AHB-Lite compliance를 주장하지 않는다. CPU-side pipeline mapping은 `cpu_interface.md`, APB bridge 및 peripheral slot behavior는 `apb_subsystem.md`에서 세부화한다.

## 2. Fabric Topology

Baseline에는 system data-bus master가 정확히 하나만 존재한다.

```text
                       RV32I CPU
                           |
                           v
                 AHB_Master_Interface
                           |
              single-master AHB-style bus
                           |
          +----------------+----------------+
          |                |                |
          v                v                v
        DMEM          VGA / VRAM       AHB -> APB
   AHB_MEMORY_SLAVE  AHB_VRAM_DUAL_     bridge
                       BUFFER              |
                                           v
                                      APB subsystem
```

Baseline topology 특성:

- CPU가 유일한 AHB-side master이다.
- Baseline에서는 bus arbiter가 필요하지 않다.
- DMA master는 없다.
- Active FPGA baseline에는 PLIC slave가 없다.
- Burst-capable system master는 없다.
- 각 CPU load/store는 독립적인 `NONSEQ` transfer로 발행된다.

향후 AXI/DMA/PLIC integration을 legacy snapshot이나 roadmap 문구로부터 현재 baseline 기능으로 추론해서는 안 된다.

## 3. Top-Level AHB Signals

현재 top-level fabric의 주요 신호는 다음과 같다.

| Signal | Width | CPU master 기준 방향 | Baseline 역할 |
|---|---:|---|---|
| `HADDR` | 32 | master -> fabric/slaves | Byte address |
| `HWRITE` | 1 | master -> fabric/slaves | Read/write direction |
| `HTRANS` | 2 | master -> fabric/slaves | Active CPU master에서는 `IDLE` 또는 `NONSEQ` |
| `HSIZE` | 3 | master -> fabric/slaves | Wiring에는 존재하지만 active master에서 현재 정상 구동되지 않음 |
| `HBURST` | 3 | master -> fabric | Active master에서 single transfer 상수 |
| `HWDATA` | 32 | master -> slaves | Data phase에 정렬된 write data |
| `HRDATA` | 32 | fabric -> master | 선택된 slave의 read data |
| `HREADY` | 1 | fabric -> master | 선택된 data-phase transaction의 completion / back-pressure |
| `HRESP` | 2 | fabric -> CPU | Phase 4A-3A 최종 ERROR는 load/store access fault에 사용됨 |

`CUSTOM_WRITE_MASK_OUT`, `BRAM_HAZARD` 같은 project-specific DMEM sideband는 일반 fabric signal이 아니다. CPU/DMEM direct integration signal이며 `cpu_interface.md`, `memory_subsystem.md`에서 정의한다.

## 4. Address-Phase Slave Decode

현재 top-level decode는 `HADDR`만으로 조합적으로 생성된다.

```verilog
HSEL_MEM  = (HADDR[31:16] == 16'h1000);
HSEL_VRAM = (HADDR[31:28] == 4'h2);
HSEL_APB  = (HADDR[31:28] == 4'h4);
```

따라서 physical decode window는 다음과 같다.

| Select | RTL physical decode | Canonical architectural use |
|---|---|---|
| `HSEL_MEM` | `0x1000_0000 - 0x1000_FFFF` | DMEM은 `0x1000_0000 - 0x1000_7FFF`만 canonical |
| `HSEL_VRAM` | `0x2000_0000 - 0x2FFF_FFFF` | `memory_map.md`가 정의한 VGA/VRAM canonical window만 지원 |
| `HSEL_APB` | `0x4000_0000 - 0x4FFF_FFFF` | Canonical APB slot `0x4000_xxxx - 0x4007_xxxx`만 지원 |

Software-visible canonical address map의 authoritative source는 `memory_map.md`이다. 넓은 physical decode window 전체를 software allocation으로 해석해서는 안 된다.

### 4.1 Decode는 `HTRANS`로 Qualification하지 않음

`HSEL_MEM`, `HSEL_VRAM`, `HSEL_APB`는 address bit에만 의존하며 top level에서 `HTRANS`와 gate되지 않는다.

따라서:

- `HTRANS=IDLE`이어도 address region에 따라 top-level select가 high일 수 있다.
- 실제 transfer validity는 각 slave 또는 bridge 내부에서 판단한다.
- invalid/idle transfer 중의 response data는 architectural meaning이 없다.

향후 cleanup에서 valid-transfer predicate로 select를 qualification할 수 있지만 현재 baseline은 그렇지 않다.

## 5. Address Phase에서 Data Phase로의 Selection

AHB는 address/data가 pipeline된 구조이므로 top-level은 address-phase slave selection을 저장해 다음 data phase에서 사용한다.

```text
Address phase                    Data phase
-------------                    ----------
HADDR -> HSEL_MEM  -----------+-> HSEL_MEM_d
HADDR -> HSEL_VRAM -----------+-> HSEL_VRAM_d
HADDR -> HSEL_APB  -----------+-> HSEL_APB_d
```

현재 사용되는 register:

```verilog
HSEL_MEM_d
HSEL_VRAM_d
HSEL_APB_d
```

Reset 시 모두 0이며 현재 system `HREADY`가 high일 때만 갱신된다.

개념적으로:

```verilog
if (!HRESETn) begin
    HSEL_MEM_d  <= 0;
    HSEL_VRAM_d <= 0;
    HSEL_APB_d  <= 0;
end else if (HREADY) begin
    HSEL_MEM_d  <= HSEL_MEM;
    HSEL_VRAM_d <= HSEL_VRAM;
    HSEL_APB_d  <= HSEL_APB;
end
```

### 5.1 Wait-State Retention Requirement

`HREADY=0`이면 data-phase select register는 이전 값을 유지해야 한다.

이는 현재 완료 중인 slave가 transfer가 끝날 때까지 다음 response source로 유지되어야 하기 때문이다.

- `HRDATA`
- `HREADY`
- `HRESP`

Stall 중에 data-phase select가 새로운 address를 따라가면 response routing이 잘못된 slave로 바뀔 수 있다.

## 6. Data-Phase Response Multiplexing

Top-level response mux는 delayed data-phase select만 사용한다.

### 6.1 Read Data

```text
if HSEL_MEM_d       -> HRDATA_MEM
else if HSEL_VRAM_d -> HRDATA_VRAM
else if HSEL_APB_d  -> HRDATA_APB
else                -> 0x0000_0000
```

### 6.2 Ready / Back-Pressure

```text
if HSEL_MEM_d       -> HREADY_MEM
else if HSEL_VRAM_d -> HREADY_VRAM
else if HSEL_APB_d  -> HREADY_APB
else                -> 1
```

### 6.3 Response

```text
if HSEL_MEM_d       -> HRESP_MEM
else if HSEL_VRAM_d -> HRESP_VRAM
else if HSEL_APB_d  -> HRESP_APB
else                -> 2'b00
```

물리적인 mux priority는 `MEM > VRAM > APB`지만 현재 address decode상 세 region은 서로 배타적이므로 이 priority는 arbitration mechanism이 아니다.

## 7. Slave Response Characteristics

### 7.1 DMEM

`AHB_MEMORY_SLAVE`는 현재 다음을 제공한다.

```text
HREADY_MEM = 1
HRESP_MEM  = 2'b00
```

Synchronous BRAM을 AHB pipeline에 맞춰 통합했기 때문에 추가 AHB wait state는 없다.

### 7.2 VGA / VRAM

`AHB_VRAM_DUAL_BUFFER` 역시:

```text
HREADY_VRAM = 1
HRESP_VRAM  = 2'b00
```

을 제공한다.

따라서 내부에 별도의 VGA pixel-clock domain이 있어도 CPU bus 관점에서는 zero-wait AHB-side target이다.

### 7.3 AHB-to-APB Bridge

APB path는 `HREADY_APB`를 low로 만들 수 있다.

Bridge state:

```text
IDLE -> SETUP -> ACCESS
```

AHB-side behavior:

- `IDLE`: `HREADY_APB = 1`
- `SETUP`: `HREADY_APB = 0`
- `ACCESS`: `HREADY_APB = PREADY`

따라서 선택된 APB peripheral 자체가 `PREADY=1`을 계속 내더라도 APB transaction은 bridge의 SETUP phase 때문에 back-pressure를 만든다.

CPU는 top-level `HREADY=0`을 `bus_stall_req=1`로 받아 `cpu_interface.md`에 정의된 대로 전체 pipeline을 freeze한다.

APB timing의 상세 contract는 `apb_subsystem.md`가 소유한다.

## 8. Back-Pressure Propagation

Baseline back-pressure chain:

```text
selected slave / APB bridge
        |
        v
     HREADY_x
        |
        v
 top-level HREADY mux
        |
        v
 AHB_Master_Interface
        |
 bus_stall_req = ~HREADY
        |
        v
    HazardUnit
        |
        v
freeze IF/ID, ID/EX, EX/MEM, MEM/WB
```

Transaction retry buffer나 독립 bus queue는 없다. Wait state 중 correctness는 CPU pipeline을 freeze하고 `HREADY`가 다시 high가 될 때까지 data-phase slave selection을 보존하는 데 의존한다.

## 9. Unmapped Access Behavior

Delayed select가 하나도 active가 아니면 현재 top-level은:

```text
HRDATA = 0x0000_0000
HREADY = 1
HRESP  = 2'b00
```

을 반환한다.

즉 어떤 top-level slave에도 매핑되지 않은 access가 bus error 없이 조용히 완료된다.

Architectural consequence:

- unmapped read는 0을 반환한 것처럼 보일 수 있다.
- unmapped write는 사실상 버려진다.
- active CPU는 이를 정상 transaction과 구분할 수 없다.
- software는 이 동작에 의존해서는 안 된다.

승인된 A2는 strict access-fault semantics를 주장하기 전에 explicit default-slave/error behavior 구현을 요구한다. 현행 RTL은 미구현이다.

## 10. `HRESP` Limitation

현재 세 AHB-side target은 모두 `2'b00` (`OKAY`)을 반환하며, active `AHB_Master_Interface`는 `HRESP` 자체를 입력으로 받지 않는다.

따라서 baseline에는 **CPU-visible bus-error path가 없다.**

이는 승인된 cleanup target이 아닌 현행 implementation limitation이다. A2는 data-bus fault를 synchronous CPU load/store access-fault로 동결했고 이후 AXI error policy는 별도 단계다.

## 11. `HSIZE` Limitation

Top-level은 `HSIZE`를 DMEM slave에 연결하지만 active CPU master는 현재 `HSIZE`를 선언만 하고 실제 값을 구동하지 않는다.

현재 기능이 동작하는 이유:

- DMEM store byte lane은 `CUSTOM_WRITE_MASK_OUT`으로 제어된다.
- DMEM load extraction은 CPU 내부에서 수행된다.
- APB bridge는 `HSIZE`를 사용하지 않는다.
- VGA slave는 `HSIZE`를 사용하지 않는다.

따라서 baseline slave behavior는 `HSIZE`에 의존해서는 안 된다.

Interconnect를 clean standard AHB-Lite implementation으로 취급하기 전 byte/halfword/word access에 대해 정상 `HSIZE` generation을 복구하고 검증해야 한다.

## 12. Physical Decode Aliases

현재 fabric에는 canonical map보다 넓은 decode로 인한 physical alias가 존재한다.

### 12.1 DMEM Alias

Top-level은 `0x1000_xxxx` 64 KiB를 선택하지만 physical DMEM은 32 KiB이고 `HADDR[14:2]`만 index한다.

따라서 physical decode 상단 절반은 하단 32 KiB로 alias될 수 있다.

Architectural address는 `0x1000_0000 - 0x1000_7FFF`뿐이다.

### 12.2 VGA / VRAM Alias

Top-level은 전체 `0x2xxx_xxxx` region을 선택하지만 VGA subsystem은 framebuffer와 control/status window를 위해 lower address bit만 decode한다.

Canonical VGA window 밖의 repeated/mirrored behavior는 architectural feature가 아니다.

### 12.3 APB Alias

Top-level은 전체 `0x4xxx_xxxx` region을 선택한다. 이후 AHB-to-APB bridge는 주로 `addr[19:16]`으로 8개 peripheral 중 하나를 고르므로 ignored upper-middle bit가 다른 주소에서도 canonical APB slot pattern이 반복될 수 있다.

Software가 사용 가능한 주소는 canonical `0x4000_xxxx - 0x4007_xxxx` slot뿐이다.

## 13. Arbitration

Baseline에는 master가 하나뿐이므로 AHB arbitration logic이 없다.

```text
Number of system data masters = 1
Arbiter required               = no
```

DMA engine 또는 다른 bus master가 추가되면 이 조건은 바뀐다. 향후 AXI fabric에서는 arbitration을 별도의 specification으로 정의해야 하며, specification update 없이 baseline AHB fabric에 multi-master arbitration을 임의 추가해서는 안 된다.

## 14. Reset Behavior

`HRESETn=0`일 때:

- `HSEL_MEM_d` clear
- `HSEL_VRAM_d` clear
- `HSEL_APB_d` clear
- 각 slave/bridge도 integration에 따라 동일 active-low system reset을 받음

Reset release 직후 valid transfer의 address phase가 받아들여지기 전에는 default response path가 선택된다.

```text
HRDATA = 0
HREADY = 1
HRESP  = OKAY
```

Clock/reset generation과 CDC requirement는 `reset_clock.md`가 소유한다.

## 15. Baseline Protocol Scope

현재 구현된 subset:

```text
Master count       : 1
Address width       : 32 bits
Data width          : 32 bits
Transfer type       : active CPU master에서 IDLE / NONSEQ
Burst mode          : single transfer only
Back-pressure       : HREADY
Response routing    : delayed HSEL 기반 mux
Error propagation   : CPU-visible하지 않음
Byte write control  : project-specific DMEM sideband
```

Undriven `HSIZE`, ignored `HRESP`, custom DMEM sideband, broad non-canonical decode가 존재하므로 이 문서는 의도적으로 **AHB-style**, **AHB-Lite-derived**라는 표현을 사용하고 full protocol compliance를 주장하지 않는다.

## 16. Major Feature Integration 전 Baseline Cleanup Target

Specification reconstruction이 끝난 뒤 PLIC/AXI 구현을 시작하기 전에 별도의 baseline-cleanup pass에서 다음을 처리한다.

1. DMEM decode를 canonical 32 KiB range로 축소
2. VGA/VRAM decode를 canonical window로 축소
3. APB top-level/bridge decode를 canonical slot으로 축소
4. 정상 `HSIZE` generation 추가
5. explicit bus-error/default-slave response 정의 및 CPU-side consumption 추가
6. top-level `HSEL` decode를 valid transfer로 qualification할지 결정
7. `cpu_interface.md`에 기록된 legacy signal naming/width inconsistency 정리
8. unmapped/boundary/back-to-back/wait-state directed verification 추가

위 항목은 **이미 구현된 동작이 아니라 cleanup requirement**이다.

## 17. Required Verification Properties

Reconstructed baseline fabric 검증에서 최소한 다음을 확인해야 한다.

- 각 canonical region이 의도된 top-level slave를 선택하는지
- 하나의 canonical address에 두 개 이상의 top-level slave가 동시에 선택되지 않는지
- data-phase response routing이 이전에 accepted된 address-phase selection을 사용하는지
- `HREADY=0` 동안 `HSEL_*_d`가 유지되는지
- APB bridge stall이 full CPU pipeline stall로 전파되는지
- DMEM/VGA zero-wait response가 불필요한 bus stall을 만들지 않는지
- 서로 다른 slave로 연속 transfer할 때 각 data-phase response가 올바른 slave에서 오는지
- cleanup 전 unmapped zero/ready/OKAY는 과거 동작이며 Phase 4A-3A에서는 2-cycle ERROR를 확인하는지
- canonical firmware test가 physical alias에 의존하지 않는지
- cleanup 이후 undefined `HSIZE` 의존성이 남아 있지 않은지

## 18. Related Sources

Active implementation source:

- `rtl/soc/AMBA_SoC_TOP.v`
- `rtl/bus/AHB_MASTER.v`
- `rtl/bus/AHB_MEMORY_SLAVE.v`
- `rtl/bus/AHB_APB_bridge.v`
- `rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v`

Related specification:

- `soc_architecture.md`
- `memory_map.md`
- `memory_subsystem.md`
- `cpu_interface.md`
- `apb_subsystem.md`
- `reset_clock.md`

`verification/legacy/`의 PLIC snapshot은 active fabric의 authoritative source가 아니다.

## 19. Baseline Fabric Invariants

후속 승인된 specification이 명시적으로 변경하기 전까지 reconstructed baseline contract는 다음과 같다.

1. CPU가 유일한 active system data-bus master이다.
2. Active fabric에는 DMEM, VGA/VRAM, AHB-to-APB의 세 top-level target이 있다.
3. Address-phase slave selection은 `HADDR`에서 생성되고 data phase까지 보존된다.
4. Data-phase select state는 `HREADY=1`일 때만 전진한다.
5. `HRDATA`, `HREADY`, `HRESP`는 delayed slave select로 mux된다.
6. DMEM과 VGA/VRAM은 zero-wait AHB-side slave이다.
7. APB transaction은 bridge를 통해 CPU를 stall시킬 수 있다.
8. Unmapped access는 현재 zero data, ready high, OKAY response로 완료된다.
9. Baseline에는 CPU-visible bus-error mechanism이 없다.
10. 넓은 physical decode alias는 implementation artifact이지 architectural address allocation이 아니다.
11. `HSIZE`는 현재 reliable signal이 아니며 baseline slave behavior가 이를 요구해서는 안 된다.
12. Baseline fabric에는 AHB arbiter, DMA master, PLIC slave, cache, external memory master가 없다.

## Phase 4A-2 승인된 decode/error 계약 (Phase 4A-3A 버스 부분 구현)

A2는 unmapped/DMEM upper alias/VGA gap·alias·미지원 read·subword·misalignment/APB alias·reserved slot·비정규 offset·size를 명시적 ERROR로 처리한다. 2비트 HRESP `00=OKAY`, `01=ERROR`; ERROR 두 cycle 모두 HRESP=ERROR이고 HREADY는 0 다음 1이다. 실패 store는 slave side effect가 없다. A3 framebuffer는 정렬된 32-bit write만 허용하고 VRAM_STATUS/CONTROL은 별도 의미를 유지한다. 위의 broad decode/zero-OKAY 설명은 cleanup 전 기록이다.

**Phase 4A-3A 구현:** `HTRANS[1]` 유효 전송 qualify, 32 KiB DMEM decode, 기본 ERROR 및 다음 주소 phase 취소, APB wait 중 data-phase select 보존을 MEM/APB/VGA/invalid 전환 테스트로 검증했다. 위의 과거 baseline 동작 설명은 현행 cleaned bus가 아니다.
