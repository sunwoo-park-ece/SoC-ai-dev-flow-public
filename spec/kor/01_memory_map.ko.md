# Baseline SoC 메모리 맵 명세

> **상태:** DRAFT — 현재 active FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `memory_map.md`가 충돌할 경우 영어 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`.


## 현행 Legacy 계약과 보증 범위

현행 APB select는 16비트이며 slot 0..9가 배정되고 10..15는 reserved/error다. 각 slot은 routing aperture이며 64 KiB 전체가 유효 register는 아니다. DMEM은 `0x1000_0000..0x1000_7FFF`의 정확한 32 KiB이며 과거 상단 alias는 거부된다. Production 배정과 selected-test 제외 범위를 구분한다. Peripheral 접근은 정렬 32-bit 및 bridge canonical-offset allowlist를 사용하며 잘못된 slot/offset/size/alignment는 peripheral select 전에 2-cycle ERROR다. 접근 방향 정책은 각 peripheral이 소유한다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [AMBA_SoC_TOP.v](../../rtl/soc/AMBA_SoC_TOP.v); [AHB_APB_bridge.v](../../rtl/bus/AHB_APB_bridge.v); [soc_memory_map.h](../../firmware/include/soc_memory_map.h).

## 1. 목적

이 문서는 현재 FPGA baseline의 software-visible address map을 정의한다. Address allocation, register offset, access-width policy, reserved/unmapped-space rule을 소유한다.

현재 RTL의 coarse decoder가 만드는 physical alias는 implementation artifact이며 canonical address가 아니다.

## 2. 주소 규칙

- 32-bit byte-addressed address space
- RV32 little-endian
- peripheral MMIO는 기본적으로 naturally aligned 32-bit read/write
- reserved address는 software가 사용하지 않음
- physical alias는 canonical address로 승격되지 않음

## 3. Active Baseline Top-Level Map

현행 map이며 routing aperture와 유효 register를 구분한다.

| Range | Capacity / role |
|---|---|
| `0x0000_0000..0x0000_3FFF` | 16 KiB CPU-local IMEM |
| `0x1000_0000..0x1000_7FFF` | 32 KiB DMEM; upper alias rejected |
| `0x2000_0000..0x2000_95FF` | 38,400-byte write-only aligned-word framebuffer |
| `0x2001_0000`, `0x2001_0004` | VGA STATUS / CONTROL |
| `0x4000_0000..0x400F_FFFF` | 16-slot APB routing aperture; slots 0..9 populated |
| Other / gap / alias | Reserved; qualified invalid data accesses ERROR |


## 4. Active Baseline APB Slot

현행 `PSEL[15:0]` 배정이다. Slot 크기는 64 KiB이지만 정확한 canonical word offset만 접근 가능하다.

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

## 5. 주요 Register Offset

### UART0 / UART1

```text
+0x00 DATA
+0x04 STATUS
+0x08 CONTROL
+0x0C BAUD
```

### GPIO

Base `0x4001_0000`; 현행 P04 register이며 SW/LED와 분리된다.

```text
+0x00 GPIO_DATA_IN       RO, synchronized input
+0x04 GPIO_DATA_OUT      RW, output latch
+0x08 GPIO_DIR           RW, 0=input/Hi-Z, 1=output
+0x0C GPIO_IRQ_ENABLE    RW
+0x10 GPIO_IRQ_TYPE      RW, 0=level, 1=edge
+0x14 GPIO_IRQ_POLARITY  RW, 0=low/falling, 1=high/rising
+0x18 GPIO_IRQ_BOTH_EDGE RW
+0x1C GPIO_IRQ_PENDING   R / W1C(edge)
```

### Timer

```text
0x4002_0000 +0x00 CTRL
0x4002_0000 +0x04 COUNT
0x4002_0000 +0x08 COMPARE
0x4002_0000 +0x0C STATUS
```

### G-sensor

```text
+0x00 HOLD_XY    RO
+0x04 HOLD_Z     RO
+0x08 STATUS     RO
+0x0C HOLD_SEQ   RO
+0x10 SNAP_CTRL  WO
```

P09B는 slot-3 base를 유지한다. 상세 coherent CAPTURE/read/RELEASE와 방향/오류 계약은 [G-sensor](12_gsensor.ko.md)가 소유한다. 별도 SPI MMIO는 없다.

### AES-GCM

Base `0x4004_0000`. 상세 register는 `aes_gcm.md`가 소유한다.

### ADC / Joystick Policy — P11 v2 implemented / bounded acceptance

Base `0x4005_0000`, canonical name `ADC_BASE`.

```text
+0x00 NAME0
+0x04 NAME1
+0x08 VERSION = 0x0002_0000
+0x0C ADC_CTRL
+0x10 ADC_STATUS
+0x14 FRAME_SEQ
+0x18 VALID_MASK
+0x1C CH1_RAW
+0x20 CH2_RAW
+0x24 CH3_RAW (reserved canonical, baseline 0)
+0x28 CH4_RAW (reserved canonical, baseline 0)
+0x2C CH5_RAW (reserved canonical, baseline 0)
+0x30 CH6_RAW (reserved canonical, baseline 0)
+0x34 LIVE_SEQ
+0x38 LIVE_VALID_MASK
+0x3C ACTIVE_MASK = 0x03
+0x40 JOY_CENTER_X
+0x44 JOY_CENTER_Y
+0x48 JOY_DEADZONE
+0x4C JOY_STATUS
+0x50..0x5C reserved / ERROR
+0x60 FRAME_COUNT
+0x64 ERROR_STATUS
+0x68..0xFC reserved / ERROR
```

이는 구현된 P11 canonical CPU map이다. 기존 source-bound 수용과 제한은 [15_adc_joystick.ko.md](15_adc_joystick.ko.md)를 따른다. Local ADC의 upper-zero decode 관찰은 CPU alias 배정이나 rebase 허가가 아니다.

No-new CAPTURE는 OKAY/no-op이며 HOLD를 보존한다. RO write/reserved/misaligned/unsupported access는 ERROR이며 mirror address는 canonical이 아니다.

### HEX

```text
0x4007_0000 +0x00 VALUE
0x4007_0000 +0x04 CTRL
0x4007_0000 +0x08 RAW_LOW
0x4007_0000 +0x0C RAW_HIGH
```

## 6. Reserved / Unmapped Access

유효 unmapped/rejected data 접근은 project 2-cycle ERROR인 `HRESP=01,HREADY=0` 후 `HRESP=01,HREADY=1`이며 거부된 slave side effect가 없어야 한다. Final ERROR는 다음 주소를 취소한다. Owner 없는 idle 기본값 `HRDATA=0,HREADY=1,HRESP=00`은 unmapped 응답이 아니다. CPU final load/store ERROR는 precise PC와 cause 5/7이며 pre-bus misalignment cause 4/6은 별도다. Bridge는 size/alignment/slot/offset 오류를 실제 PSEL 전에 거부한다. Canonical RO/WO 방향 정책은 peripheral별이다.

## 7. 현행 P04 Board-I/O 배정

P04에서 위 slot 배정, decoder/response mux, GPIO/SW/LED, FW 상수가 구현됐다. SW는 +0x00 DATA, +0x04 IRQ_ENABLE, +0x08 IRQ_PENDING이며 LED는 +0x00 DATA다. gpio_irq/sw_irq는 CPU routing이 없는 local wire다. Pin/OE 수용과 STA-002/board 종결은 별도다.

## 8. Firmware Promotion Rule

현행 `firmware/include/soc_memory_map.h`는 위 base와 GPIO register, SW_BASE=0x4008_0000, LED_BASE=0x4009_0000을 정의한다. JOYSTICK_BASE는 ADC_BASE의 deprecated alias이며 새 peripheral 배정이 아니다.

## 9. 관련 명세

- `apb_subsystem.md`
- `gpio.md`
- `sw.md`
- `led.md`
- `board_io_architecture.md`
- future PLIC specification

## Phase 4A-2 승인된 cleanup 목표 (Phase 4A-3A 일부 구현)

Canonical 주소는 변경하지 않는다. A2에 따라 unmapped AHB, DMEM 상단 alias, VGA gap/alias 및 미지원 접근, APB aperture 밖 alias, reserved slot, 비정규 offset/size는 project 2-cycle ERROR를 반환한다. Cleanup 전 zero/OKAY mirror는 architecture가 아니다. A3 framebuffer는 자연 정렬된 32-bit write-only이며 read/subword는 fault, STATUS/CONTROL은 별도 의미를 유지한다. A1 generic GPIO는 slot 1의 16비트 JP1 GPIO_0–15이고 UART/LoRa pin은 분리한다. A5 COMPARE=N은 START 후 정확히 N PCLK counting edge, N=0은 START edge 완료다. 이 문단은 과거 Phase 4A-2 목표이며 후속 P04 GPIO/SW/LED와 P06 Timer가 별도 수용 범위에서 A1/A5를 구현했다.

**과거 Phase 4A-3A 적용 범위:** 공개 RTL의 DMEM 32 KiB 및 canonical APB decode, A2 비정규 접근 2-cycle ERROR, A3 framebuffer 버스 접근 정책을 지향 테스트로 검증했다. A1 GPIO, A5 Timer, SW/LED slot 이관은 아직 목표 상태다.

## P09B G-sensor 배정 — source/documentation 동시 게시 갱신

> **현행 Public 통합:** 이 구현은 P09B source/documentation 동시 commit과 함께 현행 상태가 된다. 이 절의 이전 후보 표현은 게시 전 provenance 기록일 뿐이다.

> **게시 정합성:** 이 계약은 P09B source와 documentation commit이 모두 게시될 때만 Public 계약이 된다. 그 전 pinned Public main은 역사 상태로 유지된다.

Canonical G-sensor base는 `0x4003_0000`(APB slot 3) 그대로다. P09B Public 구현은 자연 정렬 32-bit register offset 다섯 개만 제공한다: `+0x00` HOLD_XY(read), `+0x04` HOLD_Z(read), `+0x08` STATUS(read), `+0x0C` HOLD_SEQ(read), `+0x10` SNAP_CTRL(write). 방향·validity·HOLD invalid zero readback·정확한 command는 [12_gsensor.ko.md](12_gsensor.ko.md)를 따른다. 그 밖의 offset·alias·미지원 size·반대 방향 접근은 wrapper side effect 전에 기존 2-cycle AHB ERROR 경로로 fault 처리한다. APB aperture와 인접 slot은 바꾸지 않는다.
