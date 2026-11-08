# RV32I CPU Core Microarchitecture Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline RTL에서 재구성한 CPU 상세 microarchitecture 문서이며, 승인된 cleanup policy 결정을 반영한다.
>
> **정본 언어:** 영어. 이 파일과 `spec/21_cpu_core.md`가 충돌하면 영문 canonical spec이 authoritative source이다.
>
> **논리적 위치:** 번호는 기존 spec renumbering을 피하기 위해 `21`을 사용하지만, 내용상 `cpu_interface.md`와 `interrupt_architecture.md`의 CPU 내부 동작을 선행/보강하는 상세 문서이다.


> **현재 C1a 읽기 규칙:** §20.1과 §20.3은 통합된 CPU/bus 구조와 한정된 검증 상태를 설명한다. 앞의 cleanup 전 decode/ISA/CSR/trap 설명과 §27의 역사적 목록은 이후 동결 계약이나 `baseline_cleanup.md`의 실제 requirement 상태를 대체하지 않는다. C1a는 조합 회로 topology를 바꾸며 논리 기능이나 architectural contract를 바꾸지 않는다.
>
> **Store payload/mask 계약 상태:** 통합 구현에는 §20.1이 요구하는 응답 독립적인 MEM payload/mask 경로가 존재한다. 소스에 결부된 simulation과 구조 검사가 해당 부분 범위를 뒷받침하며 공개 derivative evidence 정합화와 전체 acceptance는 별도이다. Whole-SoC timing, vendor BRAM, CDC 또는 board 종결을 뜻하지 않는다.

## 현행 Legacy 계약과 보증 범위

현행 RV32I 5단계 동작은 deterministic legality, rs2[4:0] register shift, JALR bit-0 clear 후 IALIGN32 검사, taken-branch misalignment, precise cause/PC 소유권, legal-no-op FENCE/FENCE.I, mtvec로 가는 EBREAK, canonical mepc로의 정확한 MRET를 포함한다. mcycle은 bus stall을 포함한 enabled cycle마다 증가하고 minstret은 real NOP·accepted MRET를 포함한 성공 commit마다 한 번 증가하며 bubble/held token/fault instruction은 세지 않는다. Recognized counter write는 정상 counting을 유지하는 legal write-ignore다. Machine ID는 0/0/0x0001_0000/0이고 unsupported CSR 주소는 illegal이다.

CPU-001 VERIFIED는 폭/명칭뿐이며 CPU-003..009와 TRAP-001..004는 기존 한정 수용 범위를 유지한다. P14 LoadExtender 조합 cleanup은 262144 binary oracle case로 두 inferred latch를 제거했으며 universal X/Z equivalence나 clean lint를 증명하지 않는다. System reset 후 x1..x31은 unspecified(CPU-010 OPEN)다. Reset mtvec 창, vendor memory 가정, external IRQ 부재는 유지한다. DMA/AXI/coherency와 PLIC/ACLINT/dual-hart는 새 owning contract가 필요하다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [RV32I46F_5SP_MMIO.v](../../rtl/core/v/top/RV32I46F_5SP_MMIO.v); [ALU.v](../../rtl/core/v/ex_stage/ALU.v); [CSR_File.v](../../rtl/core/v/id_stage/CSR_File.v); [LoadExtender.v](../../rtl/core/v/mem_stage/LoadExtender.v); [tb_load_extender.sv](../../verification/selected_ip/tb_load_extender.sv).

## 1. 목적과 범위

이 문서는 현재 FPGA baseline의 `RV32I46F5SPMMIO` CPU 내부 동작과 cleanup target을 구분하여 정의한다.

주요 소유 범위:

- IF/ID/EX/MEM/WB 5-stage pipeline,
- instruction decode / immediate generation,
- ALU와 branch/jump,
- register file,
- forwarding / hazard,
- 1-cycle load-use interlock,
- pipeline stall/flush priority,
- CSR datapath,
- synchronous exception detector,
- trap-controller FSM,
- retirement/counter semantics,
- CPU reset-visible state,
- CPU-local cleanup requirements.

AHB 외부 interface는 `03_cpu_interface.md`, memory BRAM 세부는 `02_memory_subsystem.md`, future PLIC/interrupt는 `07_interrupt_architecture.md` 및 향후 PLIC spec이 소유한다.

---

## 2. Provenance

CPU는 MIT license의 `RISC-KC/basic_rv32s` `RV32I46F_5SP`를 source basis로 한다.

프로젝트 local work에는 다음이 포함된다.

- SoC/MMIO integration,
- AHB load/store interface adaptation,
- pipeline/hazard tuning,
- FPGA synchronous BRAM timing integration,
- custom store mask / BRAM RAW handling,
- SoC-specific architecture cleanup.

정확한 historical upstream import commit은 복원되지 않았다. 따라서 문서/포트폴리오에서는 **upstream-derived CPU basis + project-local modification/integration**으로 표현한다.

---

## 3. CPU 구조 요약

```text
XLEN                  32
Pipeline              IF -> ID -> EX -> MEM -> WB
Issue                 single issue
Branch prediction     active baseline에서는 사용하지 않음
Instruction memory    CPU-local synchronous IMEM
Data/MMIO             AHB-style interface
Cache/MMU             없음
External IRQ          active baseline에는 없음
Privilege             partial machine-mode CSR/trap
```

통합 pipeline은 `ID_valid`, `EX_valid`, `MEM_valid`, `WB_valid`와 별도 exception/serialization metadata를 전달한다. Reset과 flush는 validity를 clear한다. NOP encoding과 zero control만으로 architectural NOP과 invalid bubble을 구별할 수 없다. 이 validity 구조는 C1a 이전부터 존재했다.

---

## 4. Stage Ownership

| Stage | 주요 역할 |
|---|---|
| IF | PC, next-PC, IMEM address |
| ID | decode, register read, immediate, control, CSR read request |
| EX | ALU, branch/JAL/JALR, forwarding, effective address |
| MEM | load extraction, store alignment/write mask |
| WB | register writeback, CSR write commit, retirement observation |

대표 흐름:

```text
ALU:    IF -> ID -> EX(result) -> MEM -> WB
LOAD:   IF -> ID -> EX(address) -> MEM(load/extend) -> WB
STORE:  IF -> ID -> EX(address) -> MEM(store data)
BRANCH: IF -> ID -> EX(compare/target)
CSR:    IF -> ID(read) -> EX(new CSR) -> MEM -> WB(write)
```

---

## 5. IF / PC

`ProgramCounter`는 reset 시 `0x0000_0000`으로 초기화된다.

Active SoC에서는 CPU `clk_enable=1'b1`로 고정되어 있으므로 stall은 clock gating이 아니라 `pc_stall`과 pipeline stall로 수행한다.

현재 next-PC priority:

```text
pc_stall이면 hold

그 외:
1. trapped      -> trap_target
2. EX_jump      -> EX ALU result
3. branch_taken -> branch target
4. default      -> PC + 4
```

Branch predictor RTL은 존재하지만 top-level instantiation이 comment 처리되어 있어 active baseline에는 사용되지 않는다.

---

## 6. IMEM / IF-ID Stall Preservation

Active IMEM은 `IF_ID_Register` 내부에서:

```text
IMEM.address = IF_pc[13:2]
```

로 사용되며 4096 words = 16 KiB이다.

Synchronous ROM 특성 때문에 IF/ID stall 진입 시 `irom_q`를 hold register에 저장하고, stall 동안 ID PC와 instruction pair가 어긋나지 않도록 유지한다.

Flush 시 pipeline에는:

```text
0x0000_0013 = ADDI x0,x0,0
```

NOP을 주입한다.

---

## 7. Decode / Immediate / Legality

현행 decoder는 opcode/funct3/funct7/shift/SYSTEM/CSR encoding을 검증하며 거부 encoding/unsupported CSR 주소에 cause 2를 내고 architectural/bus effect를 억제한다. Recognized machine-counter write-ignore 예외는 legal이다. CPU-009는 기존 directed 범위에서 수용됐으며 exhaustive ISA compliance가 아니다.

## 8. Register File

```text
32 x 32-bit GPR
2 combinational read
1 synchronous write
```

x0는 read-zero/write-ignore로 구현된다.

WB와 ID가 같은 register를 같은 cycle에 접근하면 read port에서 incoming WB data를 바로 반환하는 WB->ID bypass가 있다.

### 8.1 GPR reset — 승인된 cleanup policy

GPR array에는 CPU system reset이 직접 연결되어 있지 않다. `initial` loop로 FPGA configuration/simulation 초기값은 0이지만, 이후 system reset이 GPR 전체를 clear한다고 보장하면 안 된다.

**승인된 cleanup target:** system reset 후 x1..x31 contents는 architectural software contract에서 unspecified로 유지한다. Debug 편의를 위한 전체 GPR reset fanout은 추가하지 않는다.

Startup software가 필요한 register/software state를 설정해야 하며 firmware는 system reset 후 모든 GPR이 0이라고 가정하면 안 된다.

---

## 9. ALU

Register SLL/SRL/SRA는 rs2[4:0], immediate shift는 encoding의 5-bit shift amount를 사용한다. CPU-003의 수용 directed case는 0/31/32/33/63/0xFFFF_FFFF를 포함한다. 과거 full-width-shift 결함은 역사적이다.

## 10. Branch / Jump

> **HISTORICAL — cleanup 전 기록:** 이 절의 미구현/결함/목표 시제는 당시 상태다. 현행 동작은 위 현행 계약 및 후속 수용 절을 따른다. 기존 ID의 의무는 삭제하거나 약화하지 않는다.

Branch는 EX에서 forwarded operand를 비교하며 BEQ/BNE/BLT/BGE/BLTU/BGEU를 지원한다.

Taken target:

```text
EX_pc + EX_imm
```

JAL은 EX에서 target을 계산하고 WB에서 PC+4를 rd에 쓴다.

### 10.1 JALR deviation / target

현행 JALR redirect는 `(rs1 + immediate) & ~1`이다. Bit 0을 지운 뒤 IALIGN=32를 검사하므로 raw low bits 01은 정렬될 수 있지만 canonical bit1은 target misalignment다. CPU-004의 수용 범위가 이 정책을 유지한다.

### 10.2 Branch alignment

IALIGN=32 위반 taken branch target은 해당 instruction PC와 cause 0을 만들고 잘못된 redirect/retirement를 억제한다. 이는 구현됐으며 수용된 TRAP-003 범위다. Not-taken branch는 target-alignment exception을 만들지 않는다.

## 11. Forwarding

Forwarding은 세 종류다.

```text
1. EX ALU operand
2. Store data
3. CSR data
```

ALU forwarding priority:

```text
MEM > WB
```

단 MEM-stage LOAD는 direct-forward 대상에서 제외된다.

Store는 address ALU operand와 stored rs2 data가 다르므로 별도 store-forward path를 사용한다.

CSR forwarding은:

```text
MEM pending CSR write
 > WB pending CSR write
 > current CSR read
```

이다.

---

## 12. 1-Cycle Load-Use Interlock

조건:

```text
EX = LOAD
EX.rd != x0
ID가 실제로 그 rd를 rs1/rs2로 사용
```

이면:

```text
IF/ID stall
ID/EX flush
EX/MEM advance
MEM/WB advance
```

를 수행한다.

즉 load를 WB까지 진행시키고 consumer를 한 cycle 늦춰 WB forwarding으로 받는다.

이 정책은 memory read -> forwarding -> ALU/branch 긴 combinational path를 제거하기 위한 project-local timing optimization이다.

---

## 13. BRAM RAW Hazard

CPU는:

```text
oBRAM_HAZARD =
  EX_memory_read_AHB && MEM_valid &&
  MEM_memory_write && !MEM_exc_valid &&
  (EX effective address[31:2] == MEM effective address[31:2])
```

를 생성한다.

이는 generic bus protocol이 아니라 mixed-port BRAM read-during-write 불확정성을 우회하기 위한 DMEM-specific sideband이다.

---

## 14. Stall / Flush Priority

Pipeline register 내부 기본 우선순위:

```text
reset > flush > capture-if-not-stalled
```

CPU는 `WBServiceController`, stage 소유 exception metadata, 직렬화된 CSR/MRET owner를 사용한다. HazardUnit의 legacy `pth_done_flush`, `standby_mode`, `trap_done`, `csr_ready` 입력은 inactive/ready 상수에 연결되어 통합 pipeline을 제어하지 않는다. 수락된 trap redirect는 IF/ID와 MEM/WB를 flush하며 service hold는 전체 stage를 정지시킨다. 이 구조는 C1a 이전부터 존재했다.

최종 MEM fault는 IF/ID, ID/EX, EX/MEM을 flush하며 WB로 들어가는 fault token과 더 오래된 WB 완료를 보존한다. EX fault는 IF/ID와 ID/EX를 flush한다. Exception metadata는 자신의 instruction token과 같은 hold/flush 결정을 따른다.

`bus_stall_req && !bus_fault_final`이면 모든 stage를 정지시키고 모든 flush를 억제한다. Bus wait는 branch/trap/load-use 진행을 보류한다. Effective priority:

```text
BUS WAIT (bus_stall_req && !bus_fault_final)
  -> full freeze, flush suppression
그 외:
  trap redirect > trap service hold > MEM fault > EX fault
  EX branch/jump > ID fault > CSR front advance/hold
  serialized-owner/pending-fault front hold
  load-use bubble > normal pipeline advance
```

---

## 15. WB

| 종류 | writeback data |
|---|---|
| LOAD | extended load result |
| ALU | ALU result |
| LUI | immediate |
| JAL/JALR | PC+4 |
| CSR | old CSR value |

x0 write는 register file에서 차단한다. 3B2B 이후 정상 GPR write는 내부 `gpr_commit = commit_valid && WB_register_write_enable && (WB_rd != 0)`로 gate된다. PC/rd/value/valid/exception을 모두 담는 외부 architectural commit interface는 아직 없다.

---

## 16. Retirement / Counter 문제

`retire_instruction`은 `WB_instruction`을 그대로 출력하는 legacy debug 신호이며 외부 valid 출력은 없다. 내부의 정상 은퇴 이벤트는 아래 `commit_valid`이다.

3B2B 이전에는 `WB_instruction != 0x0000_0013` 패턴으로 bubble을 구분하여 실제 NOP도 `minstret`에 포함하지 못했다. 이 heuristic과 지연 `instruction_retired` pulse는 제거되었다. 현재 정상 WB consume은:

```text
commit_valid = clk_enable && !reset && WB_valid && !WB_exc_valid
               && !wb_is_mret && !MEM_WB_stall && !MEM_WB_flush
               && !trap_service_hold
```

성공한 정상 WB token이 enabled edge에서 실제 소비될 때에만 1이다. 유효한 NOP는 count되고 invalid bubble, WB hold, fault/flush/trap service는 제외된다. Younger MEM final ERROR는 older WB commit을 억제하지 않는다. 정상 GPR/CSR write도 이 이벤트로 gate되며 trap CSR write는 별도다.

`CSRFile`의 64-bit `minstret`은 같은 edge에서 `commit_valid`로 직접 증가한다. Younger CSR read는 older commit drain 이후에 수행된다. 3B2B 점수판 및 사용자 Quartus fit/STA 근거는 로컬 Phase 4A-3B2B 보고서에 있다. **과거 3B2B 시점:** 당시 전용 MRET service path는 아직 `commit_valid`를 발생시키지 않았다. 이후 3B3에서 MRET redirect 수락 edge의 일회 commit/`minstret` 증가를 구현해 `CPU-005`를 VERIFIED로 만들었고, 3B-CLOSE에서 남은 `TRAP-002` 정밀도 상호작용 검증을 완료했다.

`mcycle`은 enabled CPU cycle마다 증가하므로 bus stall cycle도 포함한다.

---

## 17. CSR Datapath

현행 readable CSR은 mcycle/mcycleh/minstret/minstreth(0xB00/0xB80/0xB02/0xB82), 아래 machine ID, mstatus=0x0000_1800, misa=0x4000_0100, 0x305/0x341/0x342의 mtvec/mepc/mcause다. 마지막 세 개만 writable state다. Recognized counter write는 counting을 유지하는 legal no-effect이며 unsupported CSR 주소와 거부 write/encoding은 CPU-009 trap이다. mepc[1:0]은 0으로 저장/read된다.

| CSR | Address | Current readback |
|---|---:|---:|
| mvendorid | `0xF11` | `0x0000_0000` |
| marchid | `0xF12` | `0x0000_0000` |
| mimpid | `0xF13` | `0x0001_0000` |
| mhartid | `0xF14` | `0x0000_0000` |

Counter의 writable semantics와 mie/mip, MIE/MPIE는 구현하지 않는다. mcycle은 enabled cycle마다, minstret은 성공 commit마다 증가하며 real NOP와 accepted MRET는 한 번 센다.

## 18. Exception Detector

> **HISTORICAL — cleanup 전 기록:** 이 절의 미구현/결함/목표 시제는 당시 상태다. 현행 동작은 위 현행 계약 및 후속 수용 절을 따른다. 기존 ID의 의무는 삭제하거나 약화하지 않는다.

ID/EX/MEM candidate priority:

```text
MEM > EX > ID
```

현재 처리되는 주요 event:

- ECALL,
- EBREAK,
- MRET control,
- JAL/JALR instruction misalignment,
- load/store misalignment.

누락/불완전:

- illegal instruction,
- illegal CSR,
- branch-target misalignment,
- bus access fault.

SYSTEM `funct3=000` decode에서 EBREAK를 exact canonical encoding이 아니라 immediate bit0 조건으로 분류하는 부분이 있어 cleanup에서 exact legality decode로 교체한다.

---

## 19. Trap Controller / 승인된 cleanup 방향

> **HISTORICAL — cleanup 전 기록:** 이 절의 미구현/결함/목표 시제는 당시 상태다. 현행 동작은 위 현행 계약 및 후속 수용 절을 따른다. 기존 ID의 의무는 삭제하거나 약화하지 않는다.

현재 multi-cycle FSM은 대략:

```text
mepc capture
 -> mcause write
 -> mtvec read
 -> target redirect + flush
```

를 수행한다.

ECALL은 별도의 standby drain sequence를 거친다.

현재 cause:

```text
instruction misaligned  0
EBREAK                  3
load misaligned         4
store misaligned        6
ECALL                   11
```

### 19.1 EBREAK — 승인된 cleanup target

Active baseline은 EBREAK 시 ordinary mtvec trap이 아니라 internal `debug_mode`를 set한다.

Cleanup target에서는 이 project-local special case를 제거한다.

```text
EBREAK
 -> precise mepc
 -> mcause = 3
 -> mtvec redirect
```

실제 RISC-V Debug Module을 추가한다면 별도 architecture/spec으로 구현한다.

### 19.2 MRET

현재:

```text
{mepc[31:2],2'b0} + 4
```

로 복귀한다.

Cleanup에서는 architectural `mepc` target으로 복귀하도록 수정한다. MIE/MPIE restoration은 future PLIC/interrupt stage 범위로 남긴다.

**Phase 4A-3B3R 동결 정책:** 이 RV32I core는 compressed extension을 지원하지 않고 IALIGN=32로 고정된다. Architectural `mepc[1:0]`은 항상 0이다. 일반 CSR 쓰기와 trap-service 쓰기는 `write_data & 32'hFFFF_FFFC`를 저장하고 CSR 읽기는 정규화된 값을 반환한다. MRET은 저장·정규화된 `mepc`의 정확한 값으로 복귀하며 `+4`나 MRET 출력의 추가 마스킹, 미정렬 저비트 쓰기만을 이유로 한 nested trap은 없다. `0x0000_0012`를 쓰면 `0x0000_0010`을 읽고 그 주소로 복귀한다. Branch/JAL/JALR의 cause 0 target 정렬 규칙은 별도로 그대로 유지한다.

**Phase 4A-3B3R 구현 근거:** 활성 CSR 저장점에서 위 정책을 강제하며 CPU/storage 지향 검증, 선행 회귀, 사용자 Quartus 내부 fit/STA가 통과했다. MRET은 redirect 수락 에지에 한 번 은퇴하고 `minstret`을 한 번 증가시킨다. 앞의 `mepc+4` 서술은 현재 동작이 아닌 과거 결함이다. **Phase 4A-3B-CLOSE**는 대표 bus/APB/load-use/CSR stall·경합 fault/redirect를 검증하여 `TRAP-002`를 종결했다. 전체 Cartesian 증명이거나 외부 I/O·펌웨어·보드 승인은 아니다.

### 19.3 FENCE / FENCE.I — 승인된 cleanup target

현재 cache도 없고 runtime IMEM write도 없으며 FENCE-family는 사실상 inert하다.

Cleanup target에서는:

```text
FENCE   = legal no-op
FENCE.I = legal no-op
```

으로 명시한다.

즉 정상 retire하며, cache-maintenance hardware가 없다는 이유로 illegal instruction을 발생시키지 않는다.

향후 cache, DMA coherency, writable instruction memory가 들어오면 이 contract를 재검토한다.

**Phase 4A-3B3R 활성 상태:** FENCE/FENCE.I가 모두 legal no-op으로 은퇴하는 것을 지향 검증했다. `TRAP_FENCEI`는 미사용 legacy macro이며 `Trap_Controller.v`와 `ic_clean` 출력은 활성 CPU에 인스턴스화되지 않아 architectural trap/cache-clean 동작을 만들지 않는다.

---

## 20. AHB Boundary

CPU external data interface 핵심:

```text
EX_memory_read_AHB
EX_memory_write_AHB
EX_alu_result_AHB
EX_funct3_AHB
CUSTOM_WRITE_MASK
MEM_store_data_AHB // HWDATA 의미
oBRAM_HAZARD
```

현재 bus 세부는 [CPU interface](03_cpu_interface.ko.md)가 소유한다. `EX_funct3_AHB`는 3 bits이며 과거 32-bit 선언은 역사적 기록이다. `HSIZE`는 분리된 load/store predecode로 구동한다. Fabric `HRESP`/`HREADY`는 조합 master를 거치지 않고 CPU에 직접 전달된다. Custom store mask와 full-pipeline bus backpressure 규칙은 유지한다.

### 20.1 승인된 A2 CPU/Slave 책임

CPU는 동일한 MEM-stage store의 `Q = MEM_valid && MEM_memory_write && !MEM_exc_valid`를 사용해 aligned store payload와 byte-lane 의도를 모두 생성해야 한다. StoreAligner HWDATA와 `CUSTOM_WRITE_MASK`는 최종 `HRESP`/`mem_fault_now`와 독립적이고 출력에 직접 연결되어야 하며 mask에 final-fault AND를 추가해서는 안 된다. EX는 주소·제어, MEM은 대응하는 데이터·lane을 소유하며 stall 동안 pairing과 안정성을 유지해야 한다. Lane 및 physical-edge 소유권의 세부 계약은 [memory subsystem](02_memory_subsystem.ko.md#73-응답-독립적인-payload와-lane-의도)과 [CPU interface](03_cpu_interface.ko.md#71-승인된-a2-payloadmask-계약)에 정의한다.

Payload와 lane 의도는 쓰기 권한이 아니다. 소유 slave/fabric은 자신의 트랜잭션을 검증·수락하고, 잘못된 store의 메모리·주변장치 부작용이 commit되기 전에 거부해야 한다. DMEM은 등록된 data-phase 쓰기 권한과 이에 대응하는 MEM 데이터·byte enable을 사용한다. APB/VRAM 부작용은 계속 로컬에서 qualify하며 DMEM custom mask를 소비하지 않는다. CPU는 faulting MEM 트랜잭션의 최종 ERROR(`HRESP=2'b01`, `HREADY=1`)를 정확한 해당 명령 PC의 `mepc`와 load/store access fault `mcause=5`/`mcause=7`로 처리해야 한다. 실패한 load는 GPR을 쓰지 않고 실패한 store는 부작용이 없어야 하며 둘 다 성공 은퇴해서는 안 된다. 더 오래된 성공 WB 소유권은 보존하고 더 어린 request·부작용은 취소해야 한다.

버스 요청 전 misalignment 검출·방지 및 cause 4/6의 access-fault 대비 우선순위를 유지한다. 기존 CPU final-fault writeback 억제, 예외·redirect 순서, request 취소는 계속 응답에 의해 qualify하며 StoreAligner payload/mask 생성만 응답 독립적으로 한다. 최종 ERROR에서 HWDATA나 byte-lane 의도를 0으로 만들 필요는 없다. 새로운 pipeline stage, slave latency, interrupt 동작 또는 retirement 정책은 도입하지 않는다.

통합 C1a 부분 범위는 소스에 결부된 한정적 구조·simulation 근거를 가진다. §20.3과 [interface 검증 상태](03_cpu_interface.ko.md#72-a2-acceptance와-한정된-검증-상태)에 요약한다. Acceptance 의무는 유지되며 실행된 case를 전부 미검증으로 서술하지 않는다. 과거 fault evidence만으로는 충분하지 않으며 다른 requirement 승격이나 fitted timing closure를 뜻하지 않는다.

### 20.2 향후 CPU/DMA Commit 소유권 (비규범적)

향후 shared-DMEM 설계에서는 CPU와 DMA request를 분리하고 arbitration과 commit 동안 master identity, 수락된 주소·데이터·strobe, 권한, 응답 소유권을 보존하는 방향을 검토한다. CPU `mem_fault_now`는 자신의 예외·request 취소에 사용할 수 있지만 global/shared BRAM WEN/byte strobe나 다른 master의 트랜잭션을 qualify해서는 안 된다. Shared controller는 되돌릴 수 없는 commit 전에 검증하고 transaction-local commit/visibility를 기준으로 completion을 정의하는 방향을 검토한다. 나중의 응답 error는 이미 commit된 쓰기를 rollback하지 못한다.

주소·데이터·WSTRB pairing, 부분/동일 주소 쓰기, collision/bypass, producer-consumer 권한, ordering/visibility, cache/coherency synchronization은 별도 architecture 계약이 필요하다. [향후 memory 고려사항](02_memory_subsystem.ko.md#18-향후-shared-dmem-buffer-고려사항-비규범적)을 참조한다. 이는 승인되지 않은 설계 제안이며 구현되었거나 동결된 target이 아니다. 주소 배정, AXI/DMA, cache, FENCE/FENCE.I, PLIC 변경은 승인하지 않는다. 현재 cacheless/no-DMA FENCE-family legal-no-op 계약은 유지하며 이 계약이 향후 DMA ordering을 증명한다고 가정해서는 안 된다.

---

### 20.3 통합 C1a 구조와 유지되는 소유권

이 구현 설명은 두 파일의 C1a delta와 기존 A2 구조를 구분한다. §20.1의 기능 요구사항은 변하지 않는다.

| Block / signal | C1a 이전 | 통합 C1a / 유지되는 invariant |
|---|---|---|
| Master size/alignment | Request-qualified `HSIZE` mux가 `ex_address_aligned`를 구동한 뒤 request/alignment로 `HTRANS` 생성 | `load_size`/`store_size`, `load_aligned`/`store_aligned`가 funct3/address를 독립적으로 predecode하고 마지막에 request를 선택한다. Read 우선순위와 모든 size/alignment 값을 보존한다. |
| CPU EX bus eligibility | `!ex_fault_now`, 여기서 `ex_fault_now = EX_valid && !EX_exc_valid && EX_fault_raw && !mem_fault_now` | `!EX_fault_raw`를 직접 사용하며 `EX_valid`, `!EX_exc_valid`, `!mem_fault_now`를 유지한다. 해당 cone의 중복된 응답-qualified 중간 항을 제거하며 request 취소의 응답 qualification은 유지한다. |
| MEM payload / lanes | 이미 `Q = MEM_valid && MEM_memory_write && !MEM_exc_valid` | StoreAligner와 직접 출력 연결은 불변이다. C1a가 A2 경로를 새로 도입하거나 store alignment를 EX로 옮기지 않았다. |
| Forwarding / load-use | MEM non-load가 WB보다 우선; EX/MEM 전 별도 store-data mux; one-cycle load-use interlock | 불변이다. 새 forwarding network, pipeline stage 또는 same-cycle MEM-load bypass는 없다. |
| Slave physical write / RAW | 등록된 DMEM 주소/쓰기 권한, 대응하는 live MEM data/mask, 등록된 byte merge | 불변이다. 현재 EX 주소는 다음 transaction에 속할 수 있다. |
| Fault / reset / retirement | Valid/exception token, 최종 ERROR, WB 소유 service, reset의 transport validity clear | 불변이다. ISA, CSR, latency, reset-memory-clear 또는 exception policy 변경이 없다. |

```text
EX forwarded operands -> ALU effective address ---------------------> HADDR
EX funct3 -----------> load/store size + alignment predecode --+
EX valid/op/exception + raw EX fault + MEM final fault --------+--> HSIZE/HTRANS
EX forwarded store rs2 -> EX/MEM [hold/flush, valid, address, funct3]
                                      |
MEM Q + address[1:0] + funct3 + rs2 -> StoreAligner -> HWDATA + custom mask
                                                        |
accepted DMEM address/write -> addr_reg/write_en_reg ----+--> BRAM write edge
fabric HRDATA -> LoadExtender -> MEM/WB -> WB forwarding / qualified commit
fabric HRESP/HREADY -> CPU final-fault logic; HREADY -> master stall -> HazardUnit
```

그림의 request 경로와 MEM payload 경로는 구별된다. `HRESP`는 `AHB_Master_Interface` 입력이 아니며 응답 종속 exception, 실패 load 억제, younger-request 취소는 CPU top에 남는다. ERROR에서 HWDATA/mask를 0으로 만들 필요는 없으며 이들은 쓰기 권한이 아니다. Wait 동안 기존 pipeline이 대응하는 payload/metadata를 hold한다. 최종 ERROR는 faulting owner를 완료하고 younger work를 취소한다.

Source mapping: [CPU top](../../rtl/core/v/top/RV32I46F_5SP_MMIO.v)의 `EX_memory_*_AHB`, `EX_fault_raw`, `mem_fault_now`, `store_aligner`, `ex_mem_register`; [master](../../rtl/bus/AHB_MASTER.v)의 `AHB_Master_Interface`; [StoreAligner](../../rtl/core/v/mem_stage/StoreAligner.v); [forwarding](../../rtl/core/v/hazard_forward/Forward_Unit.v); [hazard control](../../rtl/core/v/hazard_forward/Hazard_Unit.v); [EX/MEM transport](../../rtl/core/v/pipeline_regs/EX_MEM_Register.v); [DMEM edge/merge](../../rtl/bus/AHB_MEMORY_SLAVE.v). Master는 low-bit carry를 포함한 기존 forwarded ALU result를 사용하며 주소를 별도로 재계산하지 않는다.

**Evidence 경계:** 한정된 before/after directed trace는 22,000 cycles를 다루며 master 역할별 4096 vectors와 isolated alignment mutant의 512-case 거부를 포함한다. 저장된 unoptimized/optimized graph는 명시된 sequential/blackbox 경계 안에서 response-to-data/mask reachability와 SCC를 검사한다. 이는 universal equivalence, whole-SoC SCC 증명 또는 original-root fitter signoff가 아니다. 실제 AES core/fault 통합 근거는 실행된 통합 동작을 뒷받침하며 새 CPU 기능이 아니다. 공개 derivative packaging은 미완료이며 run별 provenance는 명세 밖에서 관리한다.

## 21. 역사적 ISA Support 설명

Datapath에는 일반적인 RV32I integer family와 CSR/system 일부가 구현되어 있다.

그러나 active baseline legality/trap/JALR/shift/CSR/FENCE/privileged semantics의 불완전점 때문에 **complete compliance-verified RV32I privileged core**라고 표현하면 안 된다.

적절한 표현은:

> locally modified RV32I-oriented five-stage CPU based on the MIT-licensed RISC-KC RV32I46F_5SP source.

이다.

---

## 22. Reset State

Reset 시 확인되는 CPU state:

```text
PC                0
pipeline           NOP / zero control
trap detector      none
trap FSM           IDLE
mtvec              0x00006D60
mepc/mcause        0
mcycle/minstret    0
CSR processing     idle
```

GPR array는 system reset clear contract가 아니며 cleanup target에서도 unspecified를 유지한다.

---

## 23. Timing / Performance

Current 1-cycle load-use policy는 synchronous BRAM에 맞추어 load result가 WB에 도착한 뒤 consumer가 forwarding받도록 설계된 것이다.

Historical timing evidence에서는 해당 long-path 제거 전후 Fmax가 대략:

```text
43.06 MHz -> 51.35 MHz
```

로 개선되었다.

핵심 architectural contract는 수치 자체보다 **MEM load direct forwarding을 포기하고 one-cycle interlock을 사용한다**는 점이다.

---

## 24. CPU Verification 최소 요구

Cleanup regression은 최소 다음을 포함해야 한다.

- 모든 integer ALU op,
- signed/unsigned compare,
- register shift rs2=0/31/32/33/63/large,
- all branch conditions,
- JAL/JALR target/link,
- MEM/WB forwarding priority,
- store forwarding,
- WB->ID bypass,
- load-use consumer 종류별 1-stall,
- bus stall + branch/trap collision,
- invalid opcode/funct3/funct7/shift encoding,
- invalid CSR,
- ECALL precise mepc/mcause,
- EBREAK precise mepc + mcause=3 + mtvec,
- MRET target,
- load/store/JAL/JALR/branch misalignment,
- future access fault,
- FENCE/FENCE.I legal no-op retirement,
- real NOP retirement/minstret,
- bubble non-retirement,
- mcycle/minstret family write 시 값 불변 + no-trap write-ignore,
- GPR reset-zero를 가정하지 않는 reset test,
- `mvendorid=0x0000_0000`,
- `marchid=0x0000_0000`,
- `mimpid=0x0001_0000`,
- `mhartid=0x0000_0000` readback.

---

## 25. Cleanup Targets

> **HISTORICAL — cleanup 전 기록:** 이 절의 미구현/결함/목표 시제는 당시 상태다. 현행 동작은 위 현행 계약 및 후속 수용 절을 따른다. 기존 ID의 의무는 삭제하거나 약화하지 않는다.

```text
High
- register shift amount -> rs2[4:0]
- complete instruction legality + illegal trap
- JALR bit0 clear
- branch target alignment
- explicit pipeline valid / retirement semantics
- precise mepc/trap entry
- MRET correction
- EBREAK -> breakpoint trap + mtvec
- bus access-fault integration

Medium/High
- CSR legality: unsupported CSR/invalid encoding은 illegal, 지원되는 project-RO CSR은 명시된 write-ignore 허용
- SYSTEM exact decode

Medium
- machine counter CSR read-only + legal no-effect/write-ignore
- machine ID CSR -> vendorid=0, marchid=0, mimpid=0x0001_0000, mhartid=0
- FENCE/FENCE.I legal no-op
- EX_funct3 width/naming

Low/policy
- GPR reset은 unspecified 유지
- unused hazard/debug/trap artifacts 정리
```

구현 status는 `baseline_cleanup.md`에서 중앙 관리한다.

---

## 26. Future PLIC Boundary

PLIC 단계 전용으로 남겨둘 항목:

- external IRQ acceptance point,
- interrupt pipeline precision,
- mstatus.MIE/MPIE,
- mie/mip,
- interrupt mcause,
- exception vs interrupt priority,
- bus stall 중 IRQ acceptance,
- MRET interrupt-state restore.

Legacy PLIC snapshot은 참고자료일 뿐 현재 core contract를 덮어쓰지 않는다.

---

## 27. 역사적 Pre-cleanup Baseline Invariants

아래 목록은 통합 C1a가 아닌 **역사적 pre-cleanup baseline** 기록이다. 특히 9–19번을 현재 결함이나 새로운 C1a 변경으로 해석해서는 안 된다. 이후 동결 계약, §20.3, 실제 tracker가 현재 상태를 규정한다.

1. Single-issue 5-stage pipeline이다.
2. Branch prediction은 inactive이다.
3. Branch/jump는 EX에서 resolve한다.
4. MEM non-load는 EX forwarding 가능하지만 MEM load는 불가하다.
5. Immediate load consumer는 1 cycle stall 후 WB forwarding을 사용한다.
6. Bus stall은 full pipeline freeze이고 flush를 억제한다.
7. x0 hard-zero, WB->ID bypass가 있다.
8. System reset은 GPR clear를 보장하지 않는다.
9. Explicit valid bit가 없고 bubble은 NOP encoding을 사용한다.
10. Real NOP은 현재 minstret에 count되지 않는다.
11. Register shift rs2 masking이 빠져 있다.
12. Illegal-instruction 처리가 불완전하다.
13. JALR bit0 clear가 없다.
14. Branch misalignment check가 inactive이다.
15. CSR는 partial machine-mode subset이다.
16. Active EBREAK는 아직 project-local debug behavior이다.
17. Active MRET은 아직 mepc+4 형태이다.
18. Active FENCE-family는 inert하지만 아직 approved legal-no-op contract로 검증되지 않았다.
19. Active machine ID CSR는 아직 inherited ASCII-like value다.
20. Active external interrupt path가 없다.

---

## 28. 승인된 Cleanup Policy 결정

기존 open clarification은 모두 종료되었다.

| 결정 | 승인된 target |
|---|---|
| `CPU-DECISION-01` GPR reset | System reset 후 x1..x31은 unspecified 유지. Startup software가 필요한 state를 설정한다. |
| `CPU-DECISION-02` machine identification | `mvendorid=0x0000_0000`, `marchid=0x0000_0000`, `mimpid=0x0001_0000`, `mhartid=0x0000_0000`. |
| `CPU-DECISION-03` FENCE / FENCE.I | 현재 cacheless/runtime-immutable IMEM 구조에서는 legal no-op. |
| `CPU-DECISION-04` EBREAK | precise `mepc`, `mcause=3`, `mtvec` redirect를 사용하는 ordinary breakpoint exception. Legacy `debug_mode`는 cleanup target이 아니다. |
| `CPU-DECISION-05` machine counters | 이번 cleanup에서는 `mcycle/mcycleh/minstret/minstreth` read-only 유지. 이 지원되는 counter CSR에 대한 write는 legal no-effect/write-ignore이며, read-only라는 이유만으로 trap을 발생시키지 않는다. Writable counter semantics는 deferred. |

### 28.1 Machine ID versioning rule

Cleanup 값은 이제 확정되었다. `mvendorid`와 `marchid`는 외부 allocation을 임의로 주장하지 않기 위해 0을 사용하고, 현재 single-hart는 `mhartid=0`을 사용한다. `mimpid=0x0001_0000`은 이번 cleanup CPU baseline의 project-owned implementation revision 1.0.0이다.

향후 CPU implementation이 의미 있게 변경되면 `mimpid`는 canonical spec과 regression expectation을 함께 갱신하면서 명시적으로 version-up한다.

## Phase 4A-2 승인된 load/store access-fault 계약 (Phase 4A-3A 버스 접근 부분 구현)

Project AHB 최종 ERROR(`HRESP=01`, `HREADY=1`)에서 load는 `mcause=5`, store/AMO는 `mcause=7`, `mepc`는 faulting instruction PC다. 실패 load는 GPR writeback 없음, 실패 store는 side effect 없음, 실패 명령은 성공 retire 없음. Misaligned load/store cause 4/6이 우선하고 구별된다. Fetch는 AHB data path 밖이므로 instruction-fetch AHB fault는 새로 정의하지 않는다. Phase 4A-3A는 load/store bus fault만 검증하며 AMO 및 기타 CPU 정확성까지 주장하지 않는다.

**Phase 4A-3A 상태:** load/store 버스 access-fault, 정확한 `mepc`, 실패 writeback/younger stage 억제, misalignment 우선순위를 CPU 단독·SoC 통합 테스트로 검증했다. AMO 지원, 일반 retirement(`CPU-005`), 불법 명령(`CPU-009`), 전체 `TRAP-003` 완료를 뜻하지 않는다.

## P08B reset-window 제한

검토 firmware는 stack/BSS/application 전에 in-range direct `mtvec`를
설치하며 User/Chat은 해당 CSR write commit 이후만 승인했다. CPU reset 값
`mtvec=0x00006d60`은 여전히 canonical 16 KiB IMEM 밖이므로 startup write
이전 exception은 보호되지 않고 검증되지 않은 reset window이다. P08B는
CPU/reset-vector 재설계를 허가하지 않으며 첫 reset fetch부터의 safe
trapping을 주장하지 않는다.
