# Baseline SoC APB 서브시스템 명세

> **P04 종결 주석(2026-09-15):** 공개 소스는 슬롯 8/9를 독립 SW/LED에 연결하고 10~15는 ERROR로 유지한다. 공개 지향 회귀와 사용자 실행 Quartus 피팅이 통과했으며 User/Chat이 `APB-001`을 `VERIFIED`로 승인했다. 기존 8슬롯·SW/LED 미구현·피팅 대기 설명은 P04 이전 이력이고 보드 승인은 별도 gate다.

> **상태:** DRAFT — 현재 active FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `apb_subsystem.md`가 충돌할 경우 영어 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `cpu_interface.md`, `ahb_fabric.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 `PSEL[7:0]`, `PSLVERR` 없음, zero/OKAY 설명은 cleanup 전 baseline 기록이다. 마지막 Phase 4A-3A 상태 문단은 당시 bridge/fault 상태이며 P04가 이후 SW/LED 슬롯 8/9를 활성화했다. A4 UART cleanup은 남아 있다.

## 1. 목적

이 문서는 active `AHB_APB_bridge` 뒤의 APB subsystem을 정의하고 baseline cleanup에서 적용할 승인된 16-slot target 확장을 함께 기록한다.

현재 구현은 APB-style baseline이며 완전한 AMBA APB compliance를 주장하지 않는다.

## 2. Active Baseline Topology

```text
CPU
 |
AHB fabric
 |
AHB_APB_bridge
 |
 | PSEL[7:0]
 v
PSEL[0] UART0 / LoRa
PSEL[1] legacy GPIO
PSEL[2] Timer
PSEL[3] G-sensor
PSEL[4] AES-GCM
PSEL[5] ADC Joystick
PSEL[6] UART1 / PC
PSEL[7] HEX
```

APB master는 AHB-to-APB bridge 하나뿐이다.

## 3. Clock / Reset

```text
PCLK    = HCLK = 50 MHz
PRESETn = HRESETn
```

현재 AHB/APB boundary는 CDC가 아니라 protocol conversion이다.

## 4. Bridge Interface

AHB side:

```text
HADDR[31:0]
HWRITE
HTRANS[1:0]
HWDATA[31:0]
HSEL
HRDATA[31:0]
HREADY
HRESP[1:0] = OKAY
```

APB side baseline:

```text
PADDR[31:0]
PWRITE
PENABLE
PSEL[7:0]
PWDATA[31:0]
PRDATA[31:0]
PREADY
```

`HSIZE`, `PSTRB`, `PSLVERR`, `PPROT`는 구현하지 않는다.

## 5. State Machine

Valid request:

```text
HSEL && (HTRANS == NONSEQ || HTRANS == SEQ)
```

FSM:

```text
IDLE -> SETUP -> ACCESS
```

SETUP에서는 `HREADY=0`, ACCESS에서는 `HREADY=PREADY`이다. 따라서 always-ready peripheral도 mandatory SETUP stall을 발생시킨다.

## 6. Active Slot Decode

현재 bridge는 `addr[31:28] == 4'h4`를 확인하고 `addr[19:16]`으로 slot을 고르지만 실제 select width는 `PSEL[7:0]`이다.

| Slot | Base | Peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | legacy GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM |
| 5 | `0x4005_0000` | ADC Joystick |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX |

`addr[27:20]`을 충분히 확인하지 않아서 `0x4xxx_xxxx` 내 alias가 생길 수 있다. 이는 non-canonical이다.

## 7. Active Response Mux

PRDATA와 PREADY는 `PSEL[0]`~`PSEL[7]`에 따라 각 peripheral response를 선택한다. Default는 baseline에서 `PRDATA=0`, `PREADY=1`이다.

모든 active baseline APB slave는 현재 `PREADY=1`이다.

## 8. Read / Write Flow

Read:

```text
AHB load
 -> SETUP
 -> ACCESS
 -> PRDATA/PREADY
 -> AHB completion
```

Write:

```text
AHB store
 -> SETUP
 -> SETUP 종료 edge에서 HWDATA를 PWDATA로 capture
 -> ACCESS에서 slave write commit
```

## 9. PWDATA Setup-Phase Gap

현재 bridge는 SETUP 전체 기간에 새 `PWDATA`를 보장하지 않는다. ACCESS에서는 정확한 값이 보장되므로 현재 slave들은 동작하지만 generic APB quality gap이다.

Cleanup에서 SETUP부터 address/control/data가 안정적으로 valid하도록 수정해야 한다.

## 10. Back-to-Back Transfer

Current ACCESS 완료와 동시에 다음 AHB request가 있으면:

```text
ACCESS(current) -> SETUP(next)
```

가 가능하다. Cross-slot read/write combination을 directed regression으로 검증해야 한다.

## 11. Access Width

Cleanup 전 bridge에는 `HSIZE`가 없었다. Phase 4A-3A에서는 `HSIZE`를 검증하지만 `PSTRB`는 없으므로 peripheral MMIO는 naturally aligned 32-bit read/write만 normative하다.

## 12. Error Handling

Cleanup 전에는 `PSLVERR` path가 없고 `HRESP`도 항상 OKAY였으며 CPU가 오류를 소비하지 않았다. Phase 4A-3A bridge는 완료되는 `PSLVERR` 및 내부 invalid request를 2-cycle AHB ERROR로 바꾼다. Invalid APB 접근은 실제 peripheral select/side effect 전에 오류 처리된다.

## 13. Register Mirroring

많은 peripheral이 low address bit 일부만 decode하므로 64-KiB slot 내부에서 register mirror가 생길 수 있다. Exact canonical offset만 사용한다.

## 14. 승인된 Target Expansion — 아직 Active 아님

> **과거 Phase 4A-3A 이관 주석:** 당시 bridge/top은 `PSEL[15:0]`이지만 slot 8/9는 SW/LED 이관 전 ERROR였다. P04에서 슬롯 8/9를 활성화했고 10–15는 예약 ERROR로 유지한다.

Target:

```text
PSEL[15:0]
```

| Slot | Base | Target peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | true bidirectional GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM |
| 5 | `0x4005_0000` | ADC Joystick |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX |
| 8 | `0x4008_0000` | SW |
| 9 | `0x4009_0000` | LED |
| 10–15 | `0x400A_0000` – `0x400F_0000` | Reserved |

기존 slot 0~7 주소는 이동하지 않는다.

### 14.1 Target decoder

4-bit slot field 전체를 깨끗하게 one-hot 16-bit select로 변환한다.

```text
slot = PADDR[19:16]
PSEL = 16-bit one-hot
```

동시에 higher-address alias도 제거한다.

### 14.2 Target response mux

```text
PRDATA mux -> PSEL[15:0]
PREADY mux -> PSEL[15:0]
```

로 확장한다. Slot 8/9는 SW/LED response를 연결하고 10~15는 승인된 A2 default-slave ERROR를 적용한다.

### 14.3 Board I/O ownership

```text
PSEL[1] -> APB_GPIO -> true bidirectional GPIO + gpio_irq
PSEL[8] -> APB_SW   -> SW[9:0] + sw_irq
PSEL[9] -> APB_LED  -> LEDR[9:0]
```

기존 GPIO slot은 제거하지 않고 유지한다. SW/LED 연결만 분리한다.

PLIC source ID는 여기서 정하지 않는다.

## 15. Cleanup Requirements

최소 작업:

1. `PSEL[7:0] -> PSEL[15:0]`
2. PRDATA/PREADY mux 확장
3. canonical APB decode tightening
4. PWDATA setup timing 수정
5. 승인된 A2 reserved/default-slot ERROR 구현
6. slot 0~7 유지
7. slot 8 SW / slot 9 LED 추가
8. slot 1 GPIO true GPIO redesign
9. firmware memory map/driver 갱신
10. cross-slot regression + FPGA acceptance

## 16. Baseline vs Target

Active baseline:

```text
PSEL[7:0]
slot 0~7 only
slot1 = legacy pseudo-GPIO
SW/LED dedicated peripheral 없음
```

Approved target:

```text
PSEL[15:0]
slot 0~7 address 유지
slot1 = true GPIO
slot8 = SW
slot9 = LED
slot10~15 = Reserved
```

Target section은 RTL/DV/FPGA 검증 완료 전까지 migration contract로 취급한다.

## Phase 4A-2 승인된 APB/UART 목표 (APB fault 부분 Phase 4A-3A 구현)

A2는 canonical APB aperture, slot 및 전체 register offset/size를 side effect 전에 검증한다. Reserved slot, alias, 비정규 offset/size는 internal/default error responder를 선택하며 실제 peripheral side effect가 없어야 한다. `PSLVERR`는 완료되는 ACCESS에서만 의미가 있고 bridge가 project 2-cycle AHB ERROR(`HRESP=01`, HREADY 0→1)로 변환한다. Cleanup 전 zero/OKAY 구현 gap은 이 버스 fault 범위에서 해소됐다. A4에서 busy UART_DATA write는 한 바이트를 정확히 한 번 수락할 때까지 `PREADY=0`; TX busy만으로 다른 register를 stall하지 않고 UART 전용 hardware timeout도 추가하지 않는다. 안전하지 않은 divisor는 active 설정이 될 수 없다.

**Phase 4A-3A 구현(과거 checkpoint):** bridge/top의 `PSEL[15:0]`, 전체 slot/offset·정렬 word 검증, side-effect gate, `PSLVERR`→AHB ERROR 및 SETUP/ACCESS 안정성을 검증했다. 당시 slot 8/9는 미구현 ERROR였으나 P04가 SW/LED를 활성화하고 전체 16-slot selection을 검증했다. 10–15는 예약 ERROR이고 A4 UART busy-write는 후속 작업이다.

## P09B slot-3 계약 — source/documentation 동시 게시 갱신

> **현행 Public 통합:** 이 구현은 P09B source/documentation 동시 commit과 함께 현행 상태가 된다. 이 절의 이전 후보 표현은 게시 전 provenance 기록일 뿐이다.

> **게시 정합성:** 구현된 slot-3 계약은 대응 P09B source commit과 함께만 적용하며, read-back 전 최종 Public commit SHA를 주장하지 않는다.

P09B Public 구현은 canonical slot 3만 정렬 word offset `+0x00/+0x04/+0x08/+0x0C/+0x10`으로 확장한다. Bridge는 wrapper select **전에** 전체 주소·size·정렬·허용 offset을 검증하며 mirror와 나머지 offset은 side effect 없이 ERROR다. Wrapper는 read/write 방향과 SNAP_CTRL 명령어의 정확한 encoding을 검증하고 invalid 요청의 완료 ACCESS에서만 PSLVERR를 내며, 나머지는 zero-wait를 유지한다. Top의 G-sensor PSLVERR는 기존 bridge의 2-cycle AHB ERROR 경로로 전달된다. 유효 CAPTURE는 완료 ACCESS마다 한 번 수행되고, 자격 없는 정상 encoding CAPTURE는 OKAY/no-op이다. STATUS는 read-only·side-effect-free이며 sample publish와 같은 edge의 readback은 pre-edge 등록 상태다. 정확한 ABI·우선순위는 [12_gsensor.ko.md](12_gsensor.ko.md)를 따른다. 새 bus slot, PLIC 경로, generic SPI aperture는 배정하지 않는다.

P09B Public 구현은 공통 reset 하나를 사용한다. G-sensor controller `iRSTN`, snapshot bank, scheduler는 추가 local delay 없이 bridge의 `PRESETn=HRESETn`을 직접 사용한다. 정상 ACCESS/pre-edge read 규칙은 reset deassert 중에만 적용된다. 비동기 assertion은 SETUP/ACCESS와 겹쳐 미완료 transfer를 중단할 수 있으며 accepted CAPTURE나 유효 read response를 만들면 안 된다. Assertion 전에 완료된 read는 과거 완료다. Reset 중단 traffic에 특정 response code를 약속하지 않는다.
