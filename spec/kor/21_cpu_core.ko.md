# RV32I CPU Core Microarchitecture Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline RTL에서 재구성한 CPU 상세 microarchitecture 문서이며, 승인된 cleanup policy 결정을 반영한다.
>
> **정본 언어:** 영어. 이 파일과 `spec/21_cpu_core.md`가 충돌하면 영문 canonical spec이 authoritative source이다.
>
> **논리적 위치:** 번호는 기존 spec renumbering을 피하기 위해 `21`을 사용하지만, 내용상 `cpu_interface.md`와 `interrupt_architecture.md`의 CPU 내부 동작을 선행/보강하는 상세 문서이다.

> **Phase 4A-3A 읽기 규칙:** 앞의 access-fault 미구현 설명은 cleanup 전 CPU 기록이다. 마지막 access-fault 문단은 검증된 load/store bus-fault 부분만 현행으로 승격하며 일반 retirement와 전체 `TRAP-003` 완료를 뜻하지 않는다.

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

Pipeline에는 별도 architectural `valid` bit가 없다. Bubble은 주로 `ADDI x0,x0,0` NOP과 zero control signal로 표현된다.

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

Active decoder는 LUI/AUIPC/JAL/JALR/BRANCH/LOAD/STORE/OP-IMM/OP/FENCE/SYSTEM opcode family를 다룬다.

Immediate는 I/S/U/B/J format으로 생성된다.

Instruction legality 검증은 불완전하다.

현재 예:

- unknown opcode가 illegal trap이 아니라 inert control로 처리될 수 있음,
- JALR `funct3=000` 검증 없음,
- R-type 전체 `funct7` legality 검증 없음,
- shift-immediate upper encoding 검증 불완전,
- invalid LOAD/STORE funct3도 bus transaction control이 올라갈 수 있음,
- illegal CSR access trap 없음.

Cleanup에서는 deterministic legality check + illegal-instruction exception을 추가한다.

---

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

지원 datapath operation:

```text
ADD SUB
AND OR XOR
SLT SLTU
SLL SRL SRA
CSR helper op
NOP
```

Immediate shift는 shamt `[4:0]`만 사용한다.

반면 register shift는 현재 전체 32-bit rs2가 shift operand로 들어간다.

```verilog
src_A << src_B
src_A >> src_B
$signed(src_A) >>> src_B
```

RV32 register shift는 `rs2[4:0]`만 사용해야 하므로 cleanup에서 반드시 수정한다.

---

## 10. Branch / Jump

Branch는 EX에서 forwarded operand를 비교하며 BEQ/BNE/BLT/BGE/BLTU/BGEU를 지원한다.

Taken target:

```text
EX_pc + EX_imm
```

JAL은 EX에서 target을 계산하고 WB에서 PC+4를 rd에 쓴다.

### 10.1 JALR deviation / target

현재:

```text
raw_target = rs1 + imm
```

를 그대로 redirect하고 raw low2를 검사한다.

Cleanup target:

```text
target = (rs1 + imm) & ~1
```

후 final alignment를 판단한다.

### 10.2 Branch alignment

JAL/JALR alignment 검사는 있지만 branch-target misalignment detector는 inactive이다. IALIGN=32 기준 taken branch misalignment 처리를 cleanup에서 추가한다.

---

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
  EX_memory_read &&
  MEM_memory_write &&
  (EX_addr[31:2] == MEM_addr[31:2])
```

를 생성한다.

이는 generic bus protocol이 아니라 mixed-port BRAM read-during-write 불확정성을 우회하기 위한 DMEM-specific sideband이다.

---

## 14. Stall / Flush Priority

Pipeline register 내부 기본 우선순위:

```text
reset > flush > capture-if-not-stalled
```

HazardUnit system-level behavior:

- taken branch/JAL/JALR: IF/ID + ID/EX flush,
- trap completion `pth_done_flush`: all pipeline flush,
- standby mode: IF/ID + ID/EX stall, older stage drain,
- `!trap_done || !csr_ready`: all-stage stall,
- load-use: IF/ID stall + ID/EX bubble,
- **bus stall: all-stage stall + 모든 flush 강제 0**.

Effective priority 핵심:

```text
BUS STALL  -> full freeze, flush suppression
그 외      -> trap/CSR control -> redirect/flush -> load-use -> normal
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

CSR instruction arithmetic:

```text
CSRRW / CSRRS / CSRRC
CSRRWI / CSRRSI / CSRRCI
```

현재 readable CSR:

```text
mcycle/mcycleh
minstret/minstreth
mvendorid/marchid/mimpid/mhartid
mstatus
misa
mtvec
mepc
mcause
```

현재 writable:

```text
mtvec
mepc
mcause
```

`mstatus`는 `0x00001800` constant이며 `mie/mip`은 active baseline에 없다.

Unsupported CSR는 read-zero / write-ignore 형태가 될 수 있고 illegal trap이 없다.

### 17.1 Machine ID CSR — 승인된 cleanup 값

Active baseline의 inherited ASCII-like value는 유지하지 않는다. Cleanup target은 다음으로 확정한다.

| CSR | Address | Cleanup value | 의미 |
|---|---:|---:|---|
| `mvendorid` | `0xF11` | `0x0000_0000` | 이 프로젝트가 별도 JEDEC vendor ID를 주장하지 않음 |
| `marchid` | `0xF12` | `0x0000_0000` | 별도 global nonzero architecture ID를 주장하지 않음 |
| `mimpid` | `0xF13` | `0x0001_0000` | cleanup CPU implementation revision 1.0.0 |
| `mhartid` | `0xF14` | `0x0000_0000` | 현재 single-hart SoC의 hart 0 |

이 값은 **cleanup target**이며 active baseline RTL이 이미 이 값을 반환한다는 뜻은 아니다.

향후 CPU implementation revision이 의미 있게 바뀌면 `mimpid` version을 canonical spec에서 명시적으로 갱신한다.

### 17.2 mcycle/minstret — 승인된 cleanup policy

이번 cleanup milestone에서는:

```text
mcycle/mcycleh/minstret/minstreth = read-only project subset
```

으로 유지한다.

Write 동작은 **write-ignore**로 확정한다.

```text
counter CSR read   -> 현재 counter 값 반환
counter CSR write  -> instruction은 정상 완료되지만 counter 값은 변경되지 않음
trap               -> 이 지원되는 counter CSR에 write했다는 이유만으로 trap 발생하지 않음
```

즉 writable machine-counter semantics는 이번 범위에서 제외하고, counter는 기존 hardware counting rule로만 증가한다. 이는 full privileged-architecture compliance를 주장하는 동작이 아니라 이번 cleanup baseline의 project policy다.

이 write-ignore 예외는 **지원되는 read-only project CSR**인 위 counter CSR들에만 적용한다. Arbitrary unsupported CSR address까지 legal하게 만드는 것이 아니며, unsupported CSR와 rejected CSR encoding은 cleanup legality contract에 따라 illegal-instruction 대상으로 남는다.

---

## 18. Exception Detector

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
data_memory_read_data_AHB // HWDATA 의미
oBRAM_HAZARD
```

외부 master의 undriven HSIZE, HRESP 미사용, EX_funct3 width mismatch, bus-stall semantics는 `03_cpu_interface.md`가 상세 소유한다.

---

## 21. ISA Support 표현 원칙

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

## 27. Baseline Invariants

Cleanup 구현이 검증되기 전까지 아래는 **active baseline** 설명이다.

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
