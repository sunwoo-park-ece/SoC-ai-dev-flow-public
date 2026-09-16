# Baseline SoC Interrupt 및 Trap Architecture Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline에서 재구성했으며 승인된 CPU cleanup policy를 함께 반영한다.
>
> **정본 언어:** 영어. 이 문서와 `spec/07_interrupt_architecture.md`가 충돌하면 영문 canonical spec이 authoritative하다.
>
> **상위 specification:** `soc_architecture.md`, `cpu_interface.md`, `ahb_fabric.md`, `apb_subsystem.md`, `reset_clock.md`.
>
> **CPU 상세 microarchitecture:** `cpu_core.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 bus-fault 미구현 설명은 cleanup 전 기록이다. 마지막 fault/IRQ 문단은 검증된 data-bus access-fault 부분만 현행으로 승격한다. Illegal-instruction, branch alignment, PLIC는 여전히 열린 상태다.

## 1. 목적

이 문서는 active FPGA baseline의 interrupt/trap architecture와 PLIC 통합 전에 수행할 synchronous-trap cleanup direction을 정의한다.

구분 대상:

- 현재 구현된 synchronous exception/trap-like event,
- 그 event들의 승인된 cleanup behavior,
- active baseline에는 없는 asynchronous interrupt,
- trap 관련 CSR baseline/cleanup policy,
- trap entry/return,
- polling 기반 peripheral service,
- legacy PLIC reference,
- baseline cleanup과 future PLIC stage의 경계.

Active baseline은 complete RISC-V privileged architecture compliance로 표현하지 않는다.

## 2. 용어

- **Exception**: 현재 instruction 또는 architectural effect에 의해 동기적으로 발생하는 event.
- **Interrupt**: peripheral/external source의 비동기 request.
- **Trap**: exception/interrupt 처리용 control transfer.

현재 baseline은 synchronous side만 구현한다.

## 3. Baseline 요약

```text
ExceptionDetector
      |
      v
TrapController
      |
      +--> mepc / mcause / mtvec
      +--> pipeline stall / flush
      +--> trap_target
```

현재 없는 기능:

- active CPU external IRQ input,
- active PLIC,
- `mie`, `mip`,
- functional `mstatus.MIE/MPIE`,
- peripheral IRQ routing,
- claim/complete,
- bus error -> CPU access-fault path.

따라서 active baseline은 **synchronous-trap capable, interrupt-incomplete**이다.

## 4. Exception Detector

ID/EX/MEM stage candidate의 combinational priority:

```text
MEM > EX > ID
```

선택 결과는 `trapped`, `trap_status[2:0]`로 register된 뒤 trap path로 전달된다.

Bus/CSR/load-use/control-flow stall과 동시에 발생했을 때 precise `mepc` ownership은 cleanup verification 대상이며 상세 내용은 `21_cpu_core.md`가 소유한다.

## 5. 현재 Trap/Event Code

| Code | 이름 | Active baseline 의미 |
|---|---|---|
| `000` | `TRAP_NONE` | 없음 |
| `001` | `TRAP_EBREAK` | EBREAK |
| `010` | `TRAP_ECALL` | ECALL |
| `011` | `TRAP_MISALIGNED_INSTRUCTION` | instruction-address misalignment |
| `100` | `TRAP_MRET` | MRET control event |
| `101` | `TRAP_FENCEI` | symbol만 존재, active detector path 없음 |
| `110` | `TRAP_MISALIGNED_STORE` | store misalignment |
| `111` | `TRAP_MISALIGNED_LOAD` | load misalignment |

`TRAP_MRET`은 exception cause가 아니다. `TRAP_FENCEI`도 symbol이 존재한다는 이유로 active architectural trap으로 취급하지 않는다.

## 6. 현재 Synchronous Exception

### ECALL

```text
mcause = 11
```

ECALL 전용 standby/drain 후 `mtvec`로 진입한다.

### EBREAK — active baseline

```text
mcause = 3
```

이지만 active controller는 일반 exception처럼 `mtvec`로 vectoring하지 않고 project-local `debug_mode`를 사용한다. 이는 baseline behavior일 뿐 complete RISC-V Debug implementation이 아니다.

### Misaligned load/store

```text
LH/LHU : address[0] == 0 필요
LW     : address[1:0] == 00 필요
SH     : address[0] == 0 필요
SW     : address[1:0] == 00 필요

load cause  = 4
store cause = 6
```

### Instruction-address misalignment

JAL/JALR target에 대해 IALIGN=32 검사를 수행하고 cause 0을 사용한다. Branch-target 검사 코드는 inactive이므로 active baseline에서 branch misalignment coverage는 불완전하다.

JALR은 cleanup에서 `(rs1 + imm) & ~1`을 적용한 뒤 alignment를 검사한다.

## 7. Active Baseline에 없는 Exception

현재 없거나 불완전:

- illegal instruction (`mcause=2`),
- instruction access fault,
- load access fault,
- store/AMO access fault,
- normal breakpoint -> `mtvec`,
- taken branch misalignment,
- bus error -> exception,
- deterministic illegal CSR handling.

이는 장기 target이 아니라 cleanup 대상이다.

## 8. CSR Baseline / Cleanup Policy

### 8.1 Trap 관련 baseline CSR

| CSR | Address | Baseline |
|---|---:|---|
| `mstatus` | `0x300` | RO constant `0x0000_1800` |
| `misa` | `0x301` | RO RV32I identity |
| `mtvec` | `0x305` | RW |
| `mepc` | `0x341` | RW |
| `mcause` | `0x342` | RW |

`mtvec` reset value:

```text
0x0000_6D60
```

`mie`, `mip`, functional MIE/MPIE는 active baseline에 없다.

### 8.2 승인된 Machine ID cleanup 값

| CSR | Address | Cleanup target |
|---|---:|---:|
| `mvendorid` | `0xF11` | `0x0000_0000` |
| `marchid` | `0xF12` | `0x0000_0000` |
| `mimpid` | `0xF13` | `0x0001_0000` |
| `mhartid` | `0xF14` | `0x0000_0000` |

의미:

- `mvendorid=0`: 별도 JEDEC vendor ID를 주장하지 않음.
- `marchid=0`: 임의의 globally allocated nonzero architecture ID를 주장하지 않음.
- `mimpid=0x0001_0000`: cleanup CPU implementation revision 1.0.0.
- `mhartid=0`: 현재 single-hart SoC의 hart 0.

Active RTL은 아직 inherited 값을 사용하므로 cleanup 구현/검증 후에만 이 값이 active contract가 된다.

### 8.3 Machine counter policy

이번 cleanup에서:

```text
mcycle/mcycleh/minstret/minstreth = read-only project subset
```

을 유지한다. Writable counter state 구현은 deferred한다.

지원되는 위 counter CSR에 대한 write는 **write-ignore**로 확정한다.

```text
read   -> 현재 counter 값 반환
write  -> instruction 정상 완료, counter 값 불변
trap   -> 이 project-RO counter CSR에 write했다는 이유만으로 trap 발생하지 않음
```

이 예외는 위 지원되는 project-RO counter에만 적용한다. Unsupported CSR address나 reject된 CSR encoding은 cleanup illegal-instruction policy를 따른다.

## 9. Trap Entry

일반 synchronous exception의 개념적 sequence:

```text
mepc capture
 -> mcause write
 -> mtvec read
 -> trap_target = mtvec
 -> pipeline flush
 -> handler execution
```

Cycle count 자체보다 precise PC/cause와 stall interaction이 architectural verification 대상이다.

## 10. ECALL Drain

```text
MEM_STANDBY
 -> WB_STANDBY
 -> RTRE_STANDBY
 -> ECALL_MEPC_WRITE
```

Cleanup에서는 APB wait, bus stall, CSR stall, load-use hazard, simultaneous redirect 상황에서도 precise `mepc`를 검증한다.

## 11. MRET

### Active baseline

```text
trap_target = {mepc[31:2],2'b00} + 4
```

### Approved cleanup target

```text
PC <- mepc
```

로 수정한다.

Functional `mstatus.MIE/MPIE` restore는 baseline cleanup이 아니라 future PLIC/CPU-interrupt stage에서 정의한다.

### Phase 4A-3B3R 동결 정책 — `mepc` / IALIGN32

현재 RV32I baseline은 compressed extension을 지원하지 않으므로 IALIGN은 32비트로 고정되고 architectural instruction PC는 4바이트 정렬이다. `mepc[1:0]`의 architectural 값은 항상 `2'b00`이다. 일반 CSR 쓰기와 trap-service 쓰기 모두 `write_data & 32'hFFFF_FFFC`를 `mepc`에 저장하며, CSR 읽기는 그 정규화된 저장값을 반환한다. 예를 들어 `0x0000_0012`를 쓰면 `0x0000_0010`을 저장하고 읽는다.

MRET은 **architecturally 저장·정규화된 `mepc`의 정확한 값**으로 이동한다. `+4` 또는 MRET 출력에서의 추가 마스킹은 없고, 소프트웨어가 `mepc` 저비트를 1로 쓰려 했다는 이유만으로 MRET cause 0/nested trap을 생성하지 않는다. IALIGN32에서 taken branch, JAL, bit 0을 제거한 JALR target의 misalignment cause 0은 그대로 유지한다. 이 저장 정책은 precise fault PC 소유권이나 향후 interrupt-state 복구 범위를 변경하지 않는다.

**Phase 4A-3B3R 구현 상태:** 정규화 저장/읽기, 정확한 MRET 이동 및 일회 은퇴가 CPU/storage 지향 테스트에서 통과했고 사용자 Quartus 내부 fit/다중 코너 STA도 통과했다. 앞의 `mepc+4`와 project-local EBREAK 설명은 현재 활성 동작이 아니라 과거 baseline 기록이다. 이후 Phase 4A-3B-CLOSE에서 대표 bus/APB/load-use/CSR stall·경합 fault/redirect 상호작용을 검증하여 `TRAP-002`를 VERIFIED로 전환했다. 전체 Cartesian 증명은 주장하지 않는다.

## 12. EBREAK / FENCE Cleanup

### 12.1 EBREAK

Legacy `debug_mode` shortcut은 cleanup architectural behavior로 유지하지 않는다.

```text
EBREAK
 -> precise mepc
 -> mcause = 3
 -> mtvec redirect
```

SYSTEM decode도 canonical legal encoding을 정확히 검사한다.

### 12.2 FENCE / FENCE.I

현재 cache가 없고 runtime IMEM이 writable하지 않으므로 cleanup contract는:

```text
FENCE   = legal no-op
FENCE.I = legal no-op
```

이다. 둘 다 정상 retire하며 `TRAP_FENCEI`로 보내지 않는다.

`TRAP_FENCEI`, `ic_clean` 등 dormant logic은 cleanup에서 제거하거나 legacy/inactive임을 명확히 한다.

**Phase 4A-3B3R 활성 상태:** EBREAK은 정확한 cause-3/`mtvec` trap을 사용하고 SYSTEM 인코딩을 엄밀히 검사한다. FENCE/FENCE.I는 no-op으로 은퇴한다. `TRAP_FENCEI`는 사용하지 않는 legacy macro이며 `debug_mode`/`ic_clean`을 포함한 구 `Trap_Controller.v`는 활성 CPU에 인스턴스화되어 있지 않다.

향후 cache/DMA coherency/writable IMEM/stronger ordering이 추가되면 재검토한다.

## 13. Peripheral Interrupt 상태

Active baseline peripheral은 CPU IRQ를 발생시키지 않는다.

Timer/UART/GPIO/G-sensor/AES-GCM/ADC/HEX는 polling/control MMIO 형태다.

Board-I/O cleanup에서 `gpio_irq`, `sw_irq` local wire가 생겨도 future PLIC stage 전에는 CPU에 연결하지 않는다.

## 14. Bus Error 관계

현재:

```text
unmapped / bus error
    X
CPU access-fault
```

이다.

Baseline cleanup에서는 승인된 A2 default/error response policy를 구현하고 CPU access-fault path를 연결한다. 이 작업은 PLIC과 독립적인 BC gate다.

## 15. Active PLIC 없음

Current SoC에는 PLIC instance/canonical MMIO base가 없다.

Legacy reference:

```text
verification/legacy/plic_snapshot/
docs/review/plic_handoff.md
```

Legacy TB의 `0x5000_0000` decode는 승인된 architectural address가 아니다.

## 16. Future PLIC Spec에서 정의할 항목

최소:

1. PLIC base/aperture,
2. source list/ID,
3. polarity 및 level/edge,
4. pending,
5. enable,
6. priority,
7. threshold,
8. claim/complete,
9. CPU external IRQ,
10. functional `mstatus.MIE/MPIE`, `mie`, `mip`,
11. interrupt mcause,
12. precise interrupt acceptance point,
13. exception-vs-interrupt priority,
14. bus stall 중 interrupt acceptance,
15. full MRET interrupt-state restore,
16. reset,
17. ISR contract,
18. DV/FPGA acceptance.

Legacy PLIC는 참고자료일 뿐 final contract가 아니다.

## 17. Baseline Cleanup / PLIC Boundary

### 17.1 BC gate에서 수행

1. MRET `mepc+4` 제거, `mepc` 복귀.
2. Precise synchronous `mepc` 검증/수정.
3. Illegal instruction + deterministic instruction legality.
4. JALR bit0 clear + taken branch alignment.
5. Bus access fault integration.
6. EBREAK -> precise breakpoint/mtvec.
7. FENCE/FENCE.I -> legal no-op, dormant FENCE trap logic 정리.
8. Explicit pipeline valid/commit retirement semantics.
9. Machine ID CSR 확정 값 구현.
10. Counter read-only policy + legal no-effect/write-ignore 구현/검증.
11. 모든 stall/control-flow collision trap regression.

### 17.2 PLIC stage로 defer

- functional MIE/MPIE,
- `mie`, `mip`,
- external IRQ acceptance,
- interrupt mcause,
- exception-vs-interrupt priority,
- PLIC MMIO/source/claim-complete,
- full MRET interrupt-state restoration.

Cleanup milestone을 PLIC 구현 단계로 확장하지 않는다.

## 18. Baseline Invariant

Cleanup verification 전 active RTL 기준:

1. asynchronous CPU IRQ 없음.
2. canonical PLIC address 없음.
3. `mie/mip` 없음.
4. `mstatus` functional interrupt-enable 아님.
5. timer polling.
6. synchronous trap은 mtvec/mepc/mcause 사용.
7. ECALL cause 11.
8. misaligned load/store cause 4/6.
9. instruction misaligned cause 0.
10. EBREAK는 아직 legacy debug_mode.
11. MRET은 아직 aligned mepc+4.
12. FENCE-family는 inert하지만 approved no-op behavior로 아직 검증되지 않음.
13. machine ID CSR는 아직 inherited value.
14. legacy PLIC는 reference-only.

## 19. 승인된 Cleanup Policy 요약

```text
GPR reset              : x1..x31 unspecified after system reset
mvendorid              : 0x0000_0000
marchid                : 0x0000_0000
mimpid                 : 0x0001_0000
mhartid                : 0x0000_0000
FENCE                   : legal no-op
FENCE.I                 : legal no-op
EBREAK                  : precise breakpoint -> mtvec
MRET cleanup target     : PC <- mepc
mcycle/minstret family  : read-only; write는 legal no-effect/write-ignore, RO라는 이유만으로 trap 없음
```

CPU-local 상세 contract는 `21_cpu_core.md`가 소유한다.

## 20. 관련 Specification

- `00_soc_architecture.md`
- `02_memory_subsystem.md`
- `03_cpu_interface.md`
- `04_ahb_fabric.md`
- `05_apb_subsystem.md`
- `06_reset_clock.md`
- `19_firmware_contract.md`
- `21_cpu_core.md`
- `baseline_cleanup.md`
- future PLIC specification

## Phase 4A-2 승인된 fault/IRQ 경계 (data-bus fault Phase 4A-3A 구현)

A2 data-bus ERROR는 external interrupt가 아닌 동기 exception이다. Load/store access fault는 `mcause=5/7`, faulting PC의 `mepc`, 실패 load writeback 없음, 실패 store side effect 없음, 성공 retire 없음이다. Misalignment cause 4/6이 구별되어 우선한다. A1 local `gpio_irq`는 SoC boundary까지 노출하지만 PLIC 전 CPU에 연결하지 않는다. 이 단계는 PLIC source ID나 CPU interrupt routing을 정의하지 않는다.

**Phase 4A-3A 상태:** data-bus access-fault 부분만 CPU/SoC 지향 테스트로 검증했다. `TRAP-003`의 illegal-instruction 및 taken-branch alignment는 열려 있고 PLIC/IRQ 배선은 변경하지 않았다.
