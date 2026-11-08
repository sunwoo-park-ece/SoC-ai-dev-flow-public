# Baseline SoC AHB Fabric 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `ahb_fabric.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`.

> **현재/역사적 읽기 규칙:** 아래 현행 구조는 기존 동결 Phase 4A-3A decode/error 계약을 구현한다. 과거 broad decode, unmapped silent OKAY, 미구동 `HSIZE`는 cleanup 전 기록이다. C1a는 CPU/master 조합 구조만 변경하며 주소·latency·exception 정책을 변경하지 않는다.

## 현행 Legacy 계약과 보증 범위

전체 production fabric은 CPU master 하나, qualified decode, 등록된 data-phase owner를 유지한다. HREADY-low에서 owner를 유지하고 final ERROR는 다음 주소를 취소한다. ERROR는 HRESP=01/ready-low 후 HRESP=01/ready-high이며 owner 없는 idle OKAY와 다르다. P14 selected test는 이 패턴을 유지하지만 비선택 production slave는 제외한다. BUS-001..005 수용은 기존 증거 범위이며 arbitration, generic AMBA, 새 플랫폼 증명을 추가하지 않는다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [AMBA_SoC_TOP.v](../../rtl/soc/AMBA_SoC_TOP.v); [tb_soc_bus_transitions.sv](../../verification/directed/bus/tb_soc_bus_transitions.sv); [tb_soc_cpu_fault_e2e.sv](../../verification/directed/bus/tb_soc_cpu_fault_e2e.sv).

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

세 functional target 외에 invalid/unmapped transfer를 위한 top-level default ERROR responder가 존재한다. 새로운 software-addressable peripheral이 아니다.

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
| `HSIZE` | 3 | master -> fabric/slaves | Phase 4A-3A는 byte/halfword/word size를 구동하며 미구동 설명은 cleanup 전 기록 |
| `HBURST` | 3 | master -> fabric | Active master에서 single transfer 상수 |
| `HWDATA` | 32 | master -> slaves | Data phase에 정렬된 write data |
| `HRDATA` | 32 | fabric -> master | 선택된 slave의 read data |
| `HREADY` | 1 | fabric -> master | 선택된 data-phase transaction의 completion / back-pressure |
| `HRESP` | 2 | fabric -> CPU | Phase 4A-3A 최종 ERROR는 load/store access fault에 사용됨 |

`CUSTOM_WRITE_MASK_OUT`, `BRAM_HAZARD` 같은 project-specific DMEM sideband는 일반 fabric signal이 아니다. CPU/DMEM direct integration signal이며 `cpu_interface.md`, `memory_subsystem.md`에서 정의한다.

## 4. Address-Phase Slave Decode

통합 top-level의 계산은 다음과 같다.

```verilog
error_response_final = HREADY && (HRESP == 2'b01);
transfer_valid = HTRANS[1] && !error_response_final;
HSEL_MEM = transfer_valid && size_supported && size_aligned &&
           (HADDR[31:15] == 17'h02000);
HSEL_VRAM = transfer_valid && (HADDR[31:17] == 15'h1000);
HSEL_APB = transfer_valid && (HADDR[31:20] == 12'h400);
HSEL_ERROR = transfer_valid && !(HSEL_MEM || HSEL_VRAM || HSEL_APB);
```

`size_supported`는 `HSIZE=000/001/010`을 허용한다. `size_aligned`는 각각 모든 byte 주소, 짝수 halfword 주소, low2 bits가 0인 word 주소를 허용한다.

| Select | Routing window | Acceptance 경계 |
|---|---|---|
| `HSEL_MEM` | `0x1000_0000 - 0x1000_7FFF` | 지원 size/alignment; 상단 alias 없음 |
| `HSEL_VRAM` | `0x2000_0000 - 0x2001_FFFF` | VGA-local 전체 주소/size/direction/readiness 검사 |
| `HSEL_APB` | `0x4000_0000 - 0x400F_FFFF` | Bridge canonical offset/slot/aligned-word 검사; slot 10..15 reserved |
| `HSEL_ERROR` | 나머지 유효 address/size 조합 | Two-cycle ERROR, slave side effect 없음 |

Routing aperture 전체가 software에 배정되는 것은 아니다. 수락되는 window/register 의미는 기존 [memory map](01_memory_map.ko.md), [VGA](08_vga.ko.md), [APB](05_apb_subsystem.ko.md) 계약이 소유한다.

### 4.1 Transfer Qualification과 Cancellation

Top-level select는 `transfer_valid`를 포함한다. `HTRANS=IDLE`은 새 owner를 선택하지 않는다. 최종 ERROR는 모든 slave에서 다음 주소를 취소한다. CPU의 bus 전 misalignment cause 4/6은 fabric 거부와 별개이다. C1a predecode와 EX eligibility는 [CPU interface](03_cpu_interface.ko.md#64-통합-c1a-request와-alignment-구조)에 정의한다.

## 5. Address Phase에서 Data Phase로의 Selection

`HSEL_MEM_d`, `HSEL_VRAM_d`, `HSEL_APB_d`, `HSEL_ERROR_d`는 response routing을 위한 수락된 주소 phase owner를 보존한다. Reset은 네 register를 모두 clear한다. `HREADY=1`에서 다음 selection을 capture하되 최종 ERROR는 모두 clear하고 다음 주소를 취소한다. `HREADY=0`에서는 이 owner register들이 hold한다.

```text
qualified address selection -> HSEL_{MEM,VRAM,APB,ERROR}_d -> response mux
HSEL_ERROR_d + default_error_final -----------------------> ERROR phase
```

`default_error_final`은 별도 response-progress state이다. Reset은 이를 clear하며 `HSEL_ERROR_d && !default_error_final`이면 `HREADY=0`이어도 다음 edge에서 set한다. 그 외 `HREADY=1`이면 clear한다. 이 구조로 첫 ERROR가 최종 ERROR로 진행한다. HREADY-only owner-update 규칙을 전체 fabric state로 일반화해서는 안 된다.

### 5.1 Wait-State Retention Requirement

`HREADY=0` 동안 owner select는 이전 값을 유지하여 `HRDATA`, `HREADY`, `HRESP`가 완료 중인 transaction에서 계속 routing되게 해야 한다. Hold 동안 더 새로운 주소를 따라가서는 안 된다.

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
else if HSEL_ERROR_d -> default_error_final
else                -> 1
```

### 6.3 Response

```text
if HSEL_MEM_d       -> HRESP_MEM
else if HSEL_VRAM_d -> HRESP_VRAM
else if HSEL_APB_d  -> HRESP_APB
else if HSEL_ERROR_d -> 2'b01
else                -> 2'b00
```

물리적인 mux priority는 `MEM > VRAM > APB > ERROR`지만 현재 address decode상 세 region은 서로 배타적이므로 이 priority는 arbitration mechanism이 아니다.

## 7. Slave Response Characteristics

### 7.1 DMEM

`AHB_MEMORY_SLAVE`는 현재 다음을 제공한다.

```text
HREADY_MEM = 1
HRESP_MEM  = 2'b00
```

Synchronous BRAM을 AHB pipeline에 맞춰 통합했기 때문에 추가 AHB wait state는 없다.

### 7.2 VGA / VRAM

성공한 지원 VGA transfer는 추가 AHB wait가 없다(`HREADY_VRAM=1`, `HRESP_VRAM=00`). 거부된 access/domain/busy/commit-time 조건은 첫 ERROR(`HREADY_VRAM=0`, `HRESP_VRAM=01`)와 최종 ERROR(`HREADY_VRAM=1`, `HRESP_VRAM=01`)를 발생시킨다.

주소 수락만으로 framebuffer 쓰기를 허용하지 않는다. Slave는 commit에서 capture된 owner를 재검증하고 거부된 side effect를 억제하며 global completion으로 hold 중 중복 쓰기를 방지한다. Framebuffer/status/control 의미는 [VGA](08_vga.ko.md)가 소유한다. CDC 또는 board signoff가 아니다.

### 7.3 AHB-to-APB Bridge

Bridge에는 `IDLE`, `SETUP`, `ACCESS`, `ERROR_FINAL` state가 있다. SETUP은 peripheral이 항상 ready여도 ready를 low로 유지한다. 유효하고 성공한 ACCESS는 PREADY로 완료하며 그 외에는 wait를 계속한다. Invalid size/alignment/canonical offset은 실제 peripheral PSEL 전에 거부한다. 완료된 PSLVERR도 AHB ERROR로 전파한다.

첫 ERROR는 ACCESS에서 발생한다(`HRESP_APB=01`, `HREADY_APB=0`). ERROR_FINAL은 `HRESP_APB=01`, `HREADY_APB=1`을 반환하고 다음 주소를 수락하지 않는다. 성공한 완료는 다음 주소를 capture하고 SETUP으로 진행할 수 있다. 대응하는 MEM store data를 capture하며 APB control은 wait 동안 안정적으로 유지한다.

Aligned word access는 slot 0..9의 기존 canonical offset을 사용하고 slot 10..15는 reserved이다. APB byte strobe나 모든 RO/WO direction mismatch를 ERROR로 바꾸는 정책을 추가하지 않는다. 세부 timing/offset/side-effect 의미는 [APB](05_apb_subsystem.ko.md)가 소유한다.

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

최종 ERROR는 completion edge이다. CPU는 대응하는 MEM fault를 소비하고 younger request를 취소한다. HRESP/HREADY는 master 밖의 CPU fault logic에도 직접 연결된다. [CPU control](21_cpu_core.ko.md#14-stall--flush-priority)을 참조한다.

Transaction retry buffer나 독립 bus queue는 없다. Wait state 중 correctness는 CPU pipeline을 freeze하고 `HREADY`가 다시 high가 될 때까지 data-phase slave selection을 보존하는 데 의존한다.

## 9. Unmapped Access Behavior

`HSEL_ERROR_d`가 소유한 transfer는 두 response cycle 모두 `HRDATA=0`, `HRESP=01`이며 `HREADY=0` 다음 `HREADY=1`을 반환한다. 최종 ERROR는 다음 주소를 취소하며 functional slave는 거부된 transfer의 side effect를 commit해서는 안 된다.

Data-phase owner가 없을 때 idle mux 기본값은 `HRDATA=0`, `HREADY=1`, `HRESP=00`이다. 이 idle 값은 unmapped transaction의 수락이 아니다. 과거 cleanup 전 unmapped zero/OKAY 완료는 아래 동결 최종 계약으로 대체되었다.

## 10. `HRESP` Limitation

과거 CPU-visible error 부재는 기존 load/store fault 계약 범위에서 해결되었다. 조합 `AHB_Master_Interface` 자체에는 계속 `HRESP` 입력이 없으며 SoC가 fabric HRESP/HREADY를 CPU `HRESP_FROM_AHB`/`HREADY_FROM_AHB`에 직접 연결한다.

최종 ERROR는 대응하는 유효 MEM load/store owner에 속하며 cause 5/7과 정확한 faulting PC를 발생시킨다. 실패 side effect/retirement와 younger request는 억제하고 더 오래된 성공 WB owner는 보존한다. 기존 bus 전 cause 4/6의 우선순위는 유지한다. [CPU fault boundary](03_cpu_interface.ko.md#15-bus-response--error-visibility)를 참조한다. Instruction-fetch fault나 새 exception 정책은 정의하지 않는다.

## 11. `HSIZE` Limitation

HSIZE는 byte `000`, halfword `001`, word `010`으로 구동한다. Master는 invalid `111`과 inactive default `010`을 유지한다. C1a는 request 선택 전에 load/store size와 forwarded-effective-address alignment를 독립적으로 predecode하며 read 우선순위와 기존 truth table을 보존한다.

Fabric size/alignment는 DMEM 선택을 qualify하며 APB와 VGA는 aligned word access를 검증한다. DMEM byte enable은 여전히 CUSTOM_WRITE_MASK_OUT에서 오고 CPU LoadExtender가 반환 load를 해석한다. 정의된 HSIZE와 DMEM-local mask는 공존하며 범용 AHB/AXI strobe나 complete AMBA compliance를 뜻하지 않는다. 과거 미구동 size는 역사적 기록이다.

## 12. Physical Decode Aliases

과거 cleanup 전 decode는 64 KiB DMEM과 전체 `0x2xxx_xxxx`/`0x4xxx_xxxx` region에 걸쳐 alias를 노출했다. §4 routing과 local validation이 그 관찰을 대체한다.

### 12.1 DMEM Alias

`0x1000_8000..0x1000_FFFF`는 RAM의 두 번째 mapping이 아니라 default ERROR로 전달된다. Canonical DMEM은 `0x1000_0000..0x1000_7FFF`를 유지한다.

### 12.2 VGA / VRAM Alias

VGA aperture는 `0x2000_0000..0x2000_95FF`의 aligned word framebuffer write, `0x2001_0000`의 status, `0x2001_0004`의 write control을 기존 readiness/direction 의미로 local validate한다. 그 밖의 offset/size나 거부된 operation은 local ERROR를 발생시킨다. Aperture는 mirrored framebuffer 배정이 아니다.

### 12.3 APB Alias

`0x4000_0000..0x400F_FFFF`만 bridge로 routing되며 peripheral 선택 전에 full offset과 구현된 slot을 검증한다. Slot 0..9는 기존 register 계약을 유지하고 10..15는 reserved/error이다. 더 높은 alias는 bridge를 선택하지 않는다. 주소 배정이나 wrong-direction 정책 변경은 없다.

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
- `HSEL_APB_d`, `HSEL_ERROR_d`, `default_error_final` clear
- 각 slave/bridge도 integration에 따라 동일 active-low system reset을 받음

Reset release 직후 valid transfer의 address phase가 받아들여지기 전에는 idle top-level response path(no valid owner)가 선택된다.

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
Error propagation   : two-cycle ERROR, direct CPU load/store fault path
Byte write control  : project-specific DMEM sideband
```

정의된 HSIZE, 명시적 error, local validation은 custom DMEM sideband 및 pipeline 결합과 공존한다. **AHB-style**, **AHB-Lite-derived** 표현을 유지하며 full protocol compliance를 주장하지 않는다.

## 16. Major Feature Integration 전 Baseline Cleanup Target

아래 목록은 역사적 cleanup requirement이며 통합 구현에 모든 구조가 아직 없다는 주장이 아니다.

1. DMEM decode를 canonical 32 KiB range로 축소
2. VGA/VRAM decode를 canonical window로 축소
3. APB top-level/bridge decode를 canonical slot으로 축소
4. 정상 `HSIZE` generation 추가
5. explicit bus-error/default-slave response 정의 및 CPU-side consumption 추가
6. top-level `HSEL` decode를 valid transfer로 qualification할지 결정
7. `cpu_interface.md`에 기록된 legacy signal naming/width inconsistency 정리
8. unmapped/boundary/back-to-back/wait-state directed verification 추가

현행 구조는 앞 절에 설명하며 [baseline cleanup](baseline_cleanup.ko.md)이 requirement 상태를 소유한다. 이 목록은 tracker 상태를 승격하거나 naming/physical 등 무관한 의무를 종결하지 않는다.

## 17. Required Verification Properties

Reconstructed baseline fabric 검증에서 최소한 다음을 확인해야 한다.

- 각 canonical region이 의도된 top-level slave를 선택하는지
- 하나의 canonical address에 두 개 이상의 top-level slave가 동시에 선택되지 않는지
- data-phase response routing이 이전에 accepted된 address-phase selection을 사용하는지
- `HREADY=0` 동안 `HSEL_*_d`가 유지되는지
- APB bridge stall이 full CPU pipeline stall로 전파되는지
- DMEM과 성공한 지원 VGA transfer는 wait를 추가하지 않고 거부된 VGA transfer는 요구된 ERROR phase를 사용하는지
- 서로 다른 slave로 연속 transfer할 때 각 data-phase response가 올바른 slave에서 오는지
- cleanup 전 unmapped zero/ready/OKAY는 과거 동작이며 Phase 4A-3A에서는 2-cycle ERROR를 확인하는지
- canonical firmware test가 physical alias에 의존하지 않는지
- 정의된 HSIZE/invalid size, alignment, 첫/최종 ERROR, physical side-effect 억제, next-address 취소가 소유 계약과 일치하는지

소스에 결부된 composite review는 실행된 CPU/SoC/negative case와 유한한 master decode/alignment 검사를 뒷받침한다. Universal equivalence, whole-SoC SCC 부재, vendor BRAM collision, fitted timing, CDC 또는 board acceptance가 아니다. 별도의 targeted compiler-provenance 근거는 과거 record를 다시 쓰지 않고 보충한다. [CPU 한정 상태](03_cpu_interface.ko.md#72-a2-acceptance와-한정된-검증-상태)와 [memory 한계](02_memory_subsystem.ko.md#74-한정된-구현-관찰과-한계)를 참조한다. 공개 derivative packaging은 미완료이다.

## 18. Related Sources

Active implementation source:

- [Top-level decode/owner/mux](../../rtl/soc/AMBA_SoC_TOP.v), [master predecode](../../rtl/bus/AHB_MASTER.v), [DMEM edge](../../rtl/bus/AHB_MEMORY_SLAVE.v), [APB validation/error](../../rtl/bus/AHB_APB_bridge.v), [VGA acceptance/commit](../../rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v).

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

현행 invariant는 기존 동결 decode/error 계약을 보존한다.

1. CPU가 유일한 active system data-bus master이다.
2. 세 functional target은 DMEM, VGA/VRAM, AHB-to-APB이며 default ERROR responder가 추가로 있다.
3. Selection은 transfer validity/final-error 취소를 포함하며 routing aperture는 software 배정이 아니다.
4. Owner select는 HREADY=0에서 hold, HREADY=1에서 advance, 최종 ERROR에서 clear한다. 별도 default_error_final은 ready가 low인 첫 ERROR를 진행시킨다.
5. HRDATA/HREADY/HRESP는 default ERROR를 포함한 capture된 owner에서 routing한다.
6. DMEM과 성공한 지원 VGA transfer는 wait를 추가하지 않으며 거부된 VGA transfer는 two-cycle ERROR이다.
7. APB transaction은 bridge를 통해 CPU를 stall시킬 수 있다.
8. Invalid/unmapped transaction은 two-cycle ERROR이며 owner 없는 IDLE 기본값은 transaction success가 아니다.
9. 최종 load/store ERROR는 기존 precise cause/PC/failed-effect 규칙을 적용해 대응하는 MEM owner의 CPU에 전달된다.
10. 과거 broad alias는 지원되는 architectural 배정이 아니다.
11. 정의된 HSIZE는 validation에 참여하며 DMEM byte enable은 대응하는 MEM의 비표준 mask이고 쓰기 권한이 아니다.
12. AHB arbiter, DMA master, PLIC slave, cache, external memory master를 도입하지 않는다.

## Phase 4A-2 승인된 decode/error 계약 (Phase 4A-3A 버스 부분 구현)

A2는 unmapped/DMEM upper alias/VGA gap·alias·미지원 read·subword·misalignment/APB alias·reserved slot·비정규 offset·size를 명시적 ERROR로 처리한다. 2비트 HRESP `00=OKAY`, `01=ERROR`; ERROR 두 cycle 모두 HRESP=ERROR이고 HREADY는 0 다음 1이다. 실패 store는 slave side effect가 없다. A3 framebuffer는 정렬된 32-bit write만 허용하고 VRAM_STATUS/CONTROL은 별도 의미를 유지한다. 위의 broad decode/zero-OKAY 설명은 cleanup 전 기록이다.

**Phase 4A-3A 구현:** `HTRANS[1]` 유효 전송 qualify, 32 KiB DMEM decode, 기본 ERROR 및 다음 주소 phase 취소, APB wait 중 data-phase select 보존을 MEM/APB/VGA/invalid 전환 테스트로 검증했다. 위의 과거 baseline 동작 설명은 현행 cleaned bus가 아니다.
