# Baseline SoC APB 서브시스템 명세

> **P04 종결 주석(2026-09-15):** 공개 소스는 슬롯 8/9를 독립 SW/LED에 연결하고 10~15는 ERROR로 유지한다. 공개 지향 회귀와 사용자 실행 Quartus 피팅이 통과했으며 User/Chat이 `APB-001`을 `VERIFIED`로 승인했다. 기존 8슬롯·SW/LED 미구현·피팅 대기 설명은 P04 이전 이력이고 보드 승인은 별도 gate다.

> **상태:** DRAFT — 현재 active FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `apb_subsystem.md`가 충돌할 경우 영어 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `cpu_interface.md`, `ahb_fabric.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 `PSEL[7:0]`, `PSLVERR` 없음, zero/OKAY 설명은 cleanup 전 baseline 기록이다. 마지막 Phase 4A-3A 상태 문단은 당시 bridge/fault 상태이며 P04가 이후 SW/LED 슬롯 8/9를 활성화했다. A4 UART cleanup은 남아 있다.

## 현행 Legacy 계약과 보증 범위

현행 bridge는 IDLE/SETUP/ACCESS/ERROR_FINAL, `PSEL[15:0]`, `HSIZE`, global `HREADY_IN`, completing `PSLVERR`를 갖는다. Canonical 정렬 word 요청은 slot 0..9를 select하며 invalid 요청은 실제 peripheral을 select하지 않는다. SETUP은 HREADY-low, 정상 ACCESS는 PREADY에서 완료한다. Wait 동안 주소/제어를 보존하고 SETUP PWDATA는 해당 MEM HWDATA이며 ACCESS용으로 등록한다. UART DATA busy write는 PREADY를 내릴 수 있어 모든 slave가 항상 ready라는 설명은 역사적이다. Completing PSLVERR 또는 bridge validation 실패는 2-cycle ERROR이며 ERROR_FINAL은 다음 주소를 수용하지 않는다. PSTRB나 일괄 RO/WO 오류 정책을 추가하지 않는다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [AHB_APB_bridge.v](../../rtl/bus/AHB_APB_bridge.v); [AMBA_SoC_TOP.v](../../rtl/soc/AMBA_SoC_TOP.v); [tb_ahb_apb_bridge_fault.sv](../../verification/directed/bus/tb_ahb_apb_bridge_fault.sv); [tb_p07b_uart_ahb_wait.sv](../../verification/directed/uart/tb_p07b_uart_ahb_wait.sv).

## 1. 목적

이 문서는 active `AHB_APB_bridge` 뒤의 APB subsystem을 정의하고 구현된 16-slot 확장 및 과거 migration 요구를 함께 기록한다.

현재 구현은 APB-style baseline이며 완전한 AMBA APB compliance를 주장하지 않는다.

## 2. Active Baseline Topology

AHB→APB master 하나와 아래 full-production slot 배정이다. P14 selected fixture는 0,1,2,4,6만 노출한다.

| Slot | Base | Peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | 16-pin true GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM v2 |
| 5 | `0x4005_0000` | ADC v2 / Joystick Policy |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX |
| 8 | `0x4008_0000` | SW |
| 9 | `0x4009_0000` | LED |
| 10..15 | `0x400A_0000..0x400F_0000` | Reserved / ERROR |

## 3. Clock / Reset

```text
PCLK    = HCLK = 50 MHz
PRESETn = HRESETn
```

현재 AHB/APB boundary는 CDC가 아니라 protocol conversion이다.

## 4. Bridge Interface

현행 interface:

```text
AHB: HADDR[31:0], HWRITE, HTRANS[1:0], HSIZE[2:0], HWDATA[31:0],
     HSEL, HREADY_IN -> HRDATA[31:0], HREADY, HRESP[1:0]
APB: PCLK=HCLK, PRESETn=HRESETn, PADDR[31:0], PWRITE, PENABLE,
     PSEL[15:0], PWDATA[31:0] <- PRDATA[31:0], PREADY, PSLVERR
```
PSTRB/PPROT는 없으며 정렬 32-bit MMIO 계약을 유지한다.

## 5. State Machine

주소는 global HREADY_IN && HSEL && HTRANS[1]이며 IDLE 또는 정상 completing ACCESS일 때 수용한다. FSM은 IDLE→SETUP→ACCESS이고 PREADY-low이면 ACCESS를 유지한다. Invalid 요청 또는 completing PSLVERR는 ACCESS(first ERROR)→ERROR_FINAL(final ERROR)→IDLE이다. ERROR_FINAL은 다음 주소를 수용하지 않는다.

## 6. Active Slot Decode

전체 canonical `addr[31:20]==0x400`, `addr[19:16]` slot, 정렬 word와 offset allowlist를 함께 확인한다. Reserved slot 10..15, 상위 alias, invalid offset은 PSEL=0으로 ERROR다. Allocation은 위 현행 표를 따른다.

## 7. Active Response Mux

PRDATA/PREADY는 PSEL[0..9]에 따라 각 slave를 선택한다. Default PRDATA=0/PREADY=1은 reserved 요청을 수용하지 않는다. UART DATA busy write는 PREADY-low로 wait할 수 있다. G-sensor/ADC completing PSLVERR는 bridge에 전달되며 각 slave는 거부 접근 side effect를 억제한다.

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

## 9. 현행 PWDATA SETUP / ACCESS

SETUP에서 PWDATA는 해당 MEM HWDATA이며 SETUP 종료 edge에 wdata_reg로 저장되어 ACCESS와 wait 동안 유지된다. 주소/제어는 accepted request의 register다. 과거 SETUP data gap은 현행 결함이 아니다. 이 project timing 계약만으로 generic APB compliance를 주장하지 않는다.

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

Bridge는 비정규 주소를 PSEL 전에 거부한다. UART/Timer/GPIO는 전체 16-bit local offset을 비교하고 AES v2는 전체 canonical 32-bit 주소를 비교한다. Direct-APB 예약값 정책과 상위 slot 소유권은 별도다. Global APB-005는 IN_PROGRESS이며 부분 완료로 전체를 승격하지 않는다.

## 14. 과거 승인 확장 — P04에서 구현

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
| 5 | `0x4005_0000` | ADC / Joystick Policy |
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

## 15. Historical Cleanup Requirements

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

Historical pre-cleanup baseline:

```text
PSEL[7:0]
slot 0~7 only
slot1 = legacy pseudo-GPIO
SW/LED dedicated peripheral 없음
```

Current implemented topology:

```text
PSEL[15:0]
slot 0~7 address 유지
slot1 = true GPIO
slot8 = SW
slot9 = LED
slot10~15 = Reserved
```

위 migration은 구현됐으며 별도 board/physical 및 global cleanup 요구는 tracker 상태를 유지한다.

## Phase 4A-2 승인된 APB/UART 목표 (APB fault 부분 Phase 4A-3A 구현)

A2는 canonical APB aperture, slot 및 전체 register offset/size를 side effect 전에 검증한다. Reserved slot, alias, 비정규 offset/size는 internal/default error responder를 선택하며 실제 peripheral side effect가 없어야 한다. `PSLVERR`는 완료되는 ACCESS에서만 의미가 있고 bridge가 project 2-cycle AHB ERROR(`HRESP=01`, HREADY 0→1)로 변환한다. Cleanup 전 zero/OKAY 구현 gap은 이 버스 fault 범위에서 해소됐다. A4에서 busy UART_DATA write는 한 바이트를 정확히 한 번 수락할 때까지 `PREADY=0`; TX busy만으로 다른 register를 stall하지 않고 UART 전용 hardware timeout도 추가하지 않는다. 안전하지 않은 divisor는 active 설정이 될 수 없다.

**Phase 4A-3A 구현(과거 checkpoint):** bridge/top의 `PSEL[15:0]`, 전체 slot/offset·정렬 word 검증, side-effect gate, `PSLVERR`→AHB ERROR 및 SETUP/ACCESS 안정성을 검증했다. 당시 slot 8/9는 미구현 ERROR였으나 P04가 SW/LED를 활성화하고 전체 16-slot selection을 검증했다. 10–15는 예약 ERROR이고 그 과거 checkpoint에서 A4는 pending이었으며 현행 P07B digital UART busy-write 계약은 [09_uart.ko.md](09_uart.ko.md)다. Physical UART-005는 별도다.

## P09B slot-3 계약 — source/documentation 동시 게시 갱신

> **현행 Public 통합:** 이 구현은 P09B source/documentation 동시 commit과 함께 현행 상태가 된다. 이 절의 이전 후보 표현은 게시 전 provenance 기록일 뿐이다.

> **게시 정합성:** 구현된 slot-3 계약은 대응 P09B source commit과 함께만 적용하며, read-back 전 최종 Public commit SHA를 주장하지 않는다.

P09B Public 구현은 canonical slot 3만 정렬 word offset `+0x00/+0x04/+0x08/+0x0C/+0x10`으로 확장한다. Bridge는 wrapper select **전에** 전체 주소·size·정렬·허용 offset을 검증하며 mirror와 나머지 offset은 side effect 없이 ERROR다. Wrapper는 read/write 방향과 SNAP_CTRL 명령어의 정확한 encoding을 검증하고 invalid 요청의 완료 ACCESS에서만 PSLVERR를 내며, 나머지는 zero-wait를 유지한다. Top의 G-sensor PSLVERR는 기존 bridge의 2-cycle AHB ERROR 경로로 전달된다. 유효 CAPTURE는 완료 ACCESS마다 한 번 수행되고, 자격 없는 정상 encoding CAPTURE는 OKAY/no-op이다. STATUS는 read-only·side-effect-free이며 sample publish와 같은 edge의 readback은 pre-edge 등록 상태다. 정확한 ABI·우선순위는 [12_gsensor.ko.md](12_gsensor.ko.md)를 따른다. 새 bus slot, PLIC 경로, generic SPI aperture는 배정하지 않는다.

P09B Public 구현은 공통 reset 하나를 사용한다. G-sensor controller `iRSTN`, snapshot bank, scheduler는 추가 local delay 없이 bridge의 `PRESETn=HRESETn`을 직접 사용한다. 정상 ACCESS/pre-edge read 규칙은 reset deassert 중에만 적용된다. 비동기 assertion은 SETUP/ACCESS와 겹쳐 미완료 transfer를 중단할 수 있으며 accepted CAPTURE나 유효 read response를 만들면 안 된다. Assertion 전에 완료된 read는 과거 완료다. Reset 중단 traffic에 특정 response code를 약속하지 않는다.

## P10-HEX slot-7 계약 — 구현 갱신

P10-HEX 구현은 canonical slot 7 (`0x4007_0000..0x4007_000C`)의 동작을 확정한다:
- AHB/APB bridge의 slot-7 allowlist는 정규 4개 오프셋(`+0x00`, `+0x04`, `+0x08`, `+0x0C`)만 aligned 32-bit 전송으로 전달한다.
- Slot 7로 향하는 비정규 CPU 요청은 `PSEL[7]` 인가 없이 bridge에서 차단되며 2-cycle AHB ERROR(`HRESP=01`)로 종료된다.
- 주변장치 슬레이브 자체(`APB_HEX_display.v`)는 `PADDR[15:0]` 완전 일치 디코드를 구현한다. 미매핑 또는 비정규 로컬 오프셋은 읽기 시 0을 반환하고 쓰기 시 side effect 없이 무시된다 (`PREADY=1`, `PSLVERR` 없음).
- 드라이버 및 검증 세부사항은 [16_hex_display.ko.md](16_hex_display.ko.md) 및 [19_firmware_contract.ko.md](19_firmware_contract.ko.md)를 따른다.

## P11 ADC Slot-5 Contract — Implemented / Bounded Acceptance

Slot 5 (`0x4005_0000`)는 구현된 generic `APB_ADC_Controller`다. CPU address/offset/size/alignment 오류는 ADC PSEL 전에 bridge가 거부한다. Local interface에는 HSIZE/PSTRB가 없으며 reserved offset, wrong direction, malformed CTRL은 side effect 없는 completing `PSLVERR`이고 기존 2-cycle AHB ERROR로 전파된다. Valid access의 `PREADY=1`, exact offset, CH3..CH6 RO zero, no-new CAPTURE의 HOLD 보존 OKAY/no-op은 그대로다.

Bridge v2 allowlist와 ADC completing PSLVERR mux는 구현됐다. 기존 `PRDATA_JOYSTICK` / `JOYSTICK_READY` 이름은 slot 소유권을 바꾸지 않는다. P11 수용 및 source에서 관찰한 upper-zero local decode 경계는 [15_adc_joystick.ko.md](15_adc_joystick.ko.md)를 따른다. CPU alias, generic rebase 허가 또는 global APB-005 closure를 추가하지 않는다.
