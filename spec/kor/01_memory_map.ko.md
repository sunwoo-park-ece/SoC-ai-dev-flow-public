# Baseline SoC 메모리 맵 명세

> **상태:** DRAFT — 현재 active FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `memory_map.md`가 충돌할 경우 영어 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`.

> **Phase 4A-3A 읽기 규칙:** 앞의 ‘현재 baseline’ 및 구현 결함 설명은 cleanup 전 FPGA 상태를 복원한 기록이다. 아래 Phase 4A-3A 상태 문단이 A2/A3 버스의 현행 구현 범위를 정한다. A1/A5와 SW/LED 이관은 여전히 목표다.

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

| Address range | 대상 | 비고 |
|---|---|---|
| `0x0000_0000` – `0x0000_3FFF` | IMEM | 16 KiB CPU-local |
| `0x1000_0000` – `0x1000_7FFF` | DMEM | 32 KiB AHB BRAM |
| `0x2000_0000` – `0x2000_95FF` | VGA back buffer | 38,400 B |
| `0x2001_0000` | VGA STATUS | AHB-side |
| `0x2001_0004` | VGA CONTROL | AHB-side |
| `0x4000_0000` – `0x4007_FFFF` | APB slot 0–7 | 현재 active baseline |
| 그 외 | Reserved | canonical mapping 없음 |

DMEM은 top-level이 `0x1000_xxxx` 64 KiB를 선택하지만 실제 BRAM은 32 KiB라 `0x1000_8000`–`0x1000_FFFF`가 alias될 수 있다. 이 영역은 non-canonical이다.

## 4. Active Baseline APB Slot

| Slot | Base | Peripheral |
|---:|---:|---|
| 0 | `0x4000_0000` | UART0 / LoRa |
| 1 | `0x4001_0000` | legacy GPIO |
| 2 | `0x4002_0000` | Timer |
| 3 | `0x4003_0000` | G-sensor |
| 4 | `0x4004_0000` | AES-GCM |
| 5 | `0x4005_0000` | ADC Joystick |
| 6 | `0x4006_0000` | UART1 / PC |
| 7 | `0x4007_0000` | HEX Display |

현재 bridge는 `PSEL[7:0]`을 사용한다. `addr[27:20]`을 충분히 확인하지 않아 `0x4xxx_xxxx` 안에서 alias가 생길 수 있으나 이는 architectural address가 아니다.

## 5. 주요 Register Offset

### UART0 / UART1

```text
+0x00 DATA
+0x04 STATUS
+0x08 CONTROL
+0x0C BAUD
```

### legacy GPIO

```text
0x4001_0000 +0x00 GPIO_DATA
0x4001_0000 +0x04 GPIO_DIR
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
0x4003_0000 +0x00 XY
0x4003_0000 +0x04 Z
```

### AES-GCM

Base `0x4004_0000`. 상세 register는 `aes_gcm.md`가 소유한다.

### ADC Joystick

Base `0x4005_0000`. 상세 register는 `adc_joystick.md`가 소유한다.

### HEX

```text
0x4007_0000 +0x00 VALUE
0x4007_0000 +0x04 CTRL
0x4007_0000 +0x08 RAW_LOW
0x4007_0000 +0x0C RAW_HIGH
```

## 6. Reserved / Unmapped Access

현재 baseline에는 완전한 bus-error architecture가 없다. Unmapped access가 zero/ready/OKAY로 끝날 수 있지만 software가 이에 의존하면 안 된다.

PLIC canonical address도 아직 없다. Legacy test의 `0x5000_0000`은 reference-only이다.

## 7. 승인된 Target APB / Board-I/O Allocation — 아직 Active 아님

> **TARGET MIGRATION NOTE — 전체 활성화 전:** `board_io_architecture.md`에서 아래 구조를 승인했다. Phase 4A-3A에서 버스 기반은 `PSEL[15:0]`으로 확장됐으나 SW/LED slot 8/9는 아직 미구현이며 이관 전까지 ERROR다.

Target APB:

```text
PSEL[15:0]
```

Target slot allocation:

| Slot | Target base | Peripheral | 상태 |
|---:|---:|---|---|
| 0 | `0x4000_0000` | UART0 / LoRa | 유지 |
| 1 | `0x4001_0000` | true bidirectional GPIO | slot 유지, redesign 예정 |
| 2 | `0x4002_0000` | Timer | 유지 |
| 3 | `0x4003_0000` | G-sensor | 유지 |
| 4 | `0x4004_0000` | AES-GCM | 유지 |
| 5 | `0x4005_0000` | ADC Joystick | 유지 |
| 6 | `0x4006_0000` | UART1 / PC | 유지 |
| 7 | `0x4007_0000` | HEX | 유지 |
| 8 | `0x4008_0000` | SW | 신규 target |
| 9 | `0x4009_0000` | LED | 신규 target |
| 10–15 | `0x400A_0000` – `0x400F_0000` | Reserved | future use |

Target board-I/O ownership:

```text
GPIO_BASE = 0x4001_0000  -> external true GPIO
SW_BASE   = 0x4008_0000  -> SW[9:0] + local IRQ
LED_BASE  = 0x4009_0000  -> LEDR[9:0]
```

이 target address는 승인된 future assignment지만 cleanup RTL, firmware, DV, FPGA acceptance가 완료되기 전까지 active canonical hardware로 간주하지 않는다.

## 8. Firmware Promotion Rule

현재 production firmware에는 slot 0~7 base만 존재한다. `SW_BASE`와 `LED_BASE`는 cleanup implementation 시점에 추가한다.

## 9. 관련 명세

- `apb_subsystem.md`
- `gpio.md`
- `sw.md`
- `led.md`
- `board_io_architecture.md`
- future PLIC specification

## Phase 4A-2 승인된 cleanup 목표 (Phase 4A-3A 일부 구현)

Canonical 주소는 변경하지 않는다. A2에 따라 unmapped AHB, DMEM 상단 alias, VGA gap/alias 및 미지원 접근, APB aperture 밖 alias, reserved slot, 비정규 offset/size는 project 2-cycle ERROR를 반환한다. Cleanup 전 zero/OKAY mirror는 architecture가 아니다. A3 framebuffer는 자연 정렬된 32-bit write-only이며 read/subword는 fault, STATUS/CONTROL은 별도 의미를 유지한다. A1 generic GPIO는 slot 1의 16비트 JP1 GPIO_0–15이고 UART/LoRa pin은 분리한다. A5 COMPARE=N은 START 후 정확히 N PCLK counting edge, N=0은 START edge 완료다. A1/A5는 구현 완료 주장이 아닌 승인 목표다.

**Phase 4A-3A 적용 범위:** 공개 RTL의 DMEM 32 KiB 및 canonical APB decode, A2 비정규 접근 2-cycle ERROR, A3 framebuffer 버스 접근 정책을 지향 테스트로 검증했다. A1 GPIO, A5 Timer, SW/LED slot 이관은 아직 목표 상태다.
