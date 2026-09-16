# Baseline SoC Memory Map Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `memory_map.ko.md` conflict, this file is authoritative.
>
> **Parent specification:** `soc_architecture.md`.

> **Phase 4A-3A reading rule:** Earlier “active baseline” tables and implementation-gap descriptions reconstruct the pre-cleanup FPGA state. The final Phase 4A-3A status paragraph identifies which A2/A3 bus behavior is now implemented. A1/A5 and SW/LED migration remain targets.

## 1. Purpose

This document defines the software-visible address map of the current FPGA baseline. It owns canonical address allocation, register offsets, access-width policy, and reserved/unmapped-space rules.

The current RTL contains several intentionally coarse decoders that create physical aliases. Those aliases are implementation artifacts, not architectural features. Firmware and verification shall use only the canonical addresses defined here.

Detailed register semantics are owned by the corresponding peripheral specifications.

## 2. Addressing Conventions

- Address width: 32 bits.
- Byte-addressed address space.
- Native CPU data width: 32 bits.
- RISC-V little-endian byte ordering.
- Peripheral MMIO is normatively accessed with naturally aligned 32-bit reads/writes unless a subordinate specification explicitly states otherwise.
- Reserved addresses shall not be used by software.
- Physical RTL aliases do not create additional canonical addresses.

## 3. Active Baseline Top-Level Map

| Address range | Size | Target | Interconnect | Architectural use |
|---|---:|---|---|---|
| `0x0000_0000` – `0x0000_3FFF` | 16 KiB | IMEM | CPU-local | executable image |
| `0x0000_4000` – `0x0FFF_FFFF` | — | Reserved | — | no canonical mapping |
| `0x1000_0000` – `0x1000_7FFF` | 32 KiB | DMEM | AHB-side | data / rodata / BSS / stack |
| `0x1000_8000` – `0x1FFF_FFFF` | — | Reserved | — | no canonical mapping |
| `0x2000_0000` – `0x2000_95FF` | 38,400 B | VGA back buffer | AHB-side | 640×480×1-bpp framebuffer |
| `0x2000_9600` – `0x2000_FFFF` | — | Reserved | AHB-side VGA subsystem | not software-visible framebuffer |
| `0x2001_0000` | 4 B | VGA STATUS | AHB-side | VSync / clear status |
| `0x2001_0004` | 4 B | VGA CONTROL | AHB-side | swap / HW clear |
| `0x2001_0008` – `0x3FFF_FFFF` | — | Reserved | — | no canonical mapping |
| `0x4000_0000` – `0x4007_FFFF` | 512 KiB | APB slots 0–7 | AHB→APB | active baseline APB subsystem |
| `0x4008_0000` – `0xFFFF_FFFF` | — | Reserved in active baseline | — | no currently implemented canonical mapping |

### 3.1 IMEM

```text
Base = 0x0000_0000
Size = 0x0000_4000
End  = 0x0000_3FFF
```

IMEM is CPU-local, 4096×32-bit words, and is populated from `IMEM.mif`.

### 3.2 DMEM

```text
Base = 0x1000_0000
Size = 0x0000_8000
End  = 0x1000_7FFF
```

The physical BRAM is 8192×32 bits. The active top-level selects `HADDR[31:16] == 16'h1000`, so `0x1000_8000`–`0x1000_FFFF` can alias the same physical memory because bit 15 is not used by the BRAM address. This upper-half alias is non-canonical.

## 4. VGA / VRAM Address Space

### 4.1 Framebuffer

```text
Base        = 0x2000_0000
Valid bytes = 0x0000 – 0x95FF
Words       = 9600
Pixels      = 640 × 480 × 1 bit
```

Only the first 38,400 bytes are canonical framebuffer storage. The active RTL can decode a larger low-64-KiB window, but the remainder is reserved.

### 4.2 VGA Registers

| Address | Register | Access |
|---:|---|---|
| `0x2001_0000` | `VRAM_STATUS` | R / W1C(bit 0) |
| `0x2001_0004` | `VRAM_CONTROL` | W |

Detailed behavior is defined in `vga.md`.

## 5. Active Baseline APB Slot Allocation

The currently implemented AHB-to-APB bridge exposes `PSEL[7:0]`. Each canonical APB slot is 64 KiB.

| Slot | PSEL | Canonical range | Base | Peripheral |
|---:|---:|---|---:|---|
| 0 | `PSEL[0]` | `0x4000_0000` – `0x4000_FFFF` | `0x4000_0000` | UART0 / LoRa |
| 1 | `PSEL[1]` | `0x4001_0000` – `0x4001_FFFF` | `0x4001_0000` | legacy GPIO |
| 2 | `PSEL[2]` | `0x4002_0000` – `0x4002_FFFF` | `0x4002_0000` | Timer |
| 3 | `PSEL[3]` | `0x4003_0000` – `0x4003_FFFF` | `0x4003_0000` | G-sensor |
| 4 | `PSEL[4]` | `0x4004_0000` – `0x4004_FFFF` | `0x4004_0000` | AES-GCM |
| 5 | `PSEL[5]` | `0x4005_0000` – `0x4005_FFFF` | `0x4005_0000` | ADC Joystick |
| 6 | `PSEL[6]` | `0x4006_0000` – `0x4006_FFFF` | `0x4006_0000` | UART1 / PC |
| 7 | `PSEL[7]` | `0x4007_0000` – `0x4007_FFFF` | `0x4007_0000` | HEX Display |

The active decoder ignores `HADDR[27:20]`, so these physical selections can repeat elsewhere in `0x4xxx_xxxx`. Such repeats are non-canonical aliases.

## 6. Active Baseline Peripheral Register Offsets

### 6.1 UART0 / UART1

```text
+0x00 UART_DATA
+0x04 UART_STATUS
+0x08 UART_CONTROL
+0x0C UART_BAUD
```

UART0 base is `0x4000_0000`; UART1 base is `0x4006_0000`.

### 6.2 Legacy GPIO

```text
0x4001_0000 +0x00 GPIO_DATA
0x4001_0000 +0x04 GPIO_DIR
```

The semantics of this active baseline block are documented in `gpio.md`. It is not a true bidirectional GPIO implementation.

### 6.3 Timer

```text
0x4002_0000 +0x00 TIMER_CTRL
0x4002_0000 +0x04 TIMER_COUNT
0x4002_0000 +0x08 TIMER_COMPARE
0x4002_0000 +0x0C TIMER_STATUS
```

### 6.4 G-sensor

```text
0x4003_0000 +0x00 GSENSOR_XY_DATA
0x4003_0000 +0x04 GSENSOR_Z_DATA
```

The private ADXL345 SPI engine has no separate software-visible MMIO base.

### 6.5 AES-GCM

Canonical base: `0x4004_0000`.

Important registers include:

```text
+0x0C AES_CTRL
+0x10 AES_STATUS
+0x20..0x2C KEY0..KEY3
+0x30 AES_NONCE_DIR
+0x34 AES_SEQ_HI
+0x38 AES_SEQ_LO
+0x3C AES_LEN
+0x40..0x4C PAYLOAD_IN0..3
+0x50..0x5C TAG_IN0..3
+0x60..0x6C PAYLOAD_OUT0..3
+0x70..0x7C TAG_OUT0..3
+0x80..0x8C HDR_DEBUG0..3
```

### 6.6 ADC Joystick

Canonical base: `0x4005_0000`.

```text
+0x00 NAME0
+0x04 NAME1
+0x08 VERSION
+0x0C JOY_CTRL
+0x10 JOY_STATUS
+0x14 JOY_X_CHANNEL
+0x18 JOY_Y_CHANNEL
+0x1C JOY_X_RAW
+0x20 JOY_Y_RAW
+0x24 JOY_CENTER_X
+0x28 JOY_CENTER_Y
+0x2C JOY_DEADZONE
+0x30 JOY_DIR_STATUS
+0x34 JOY_SAMPLE_COUNT
+0x38 JOY_RESP_INFO
```

### 6.7 HEX Display

```text
0x4007_0000 +0x00 HEX_VALUE
0x4007_0000 +0x04 HEX_CTRL
0x4007_0000 +0x08 HEX_RAW_LOW
0x4007_0000 +0x0C HEX_RAW_HIGH
```

## 7. Register Mirroring

Several active peripherals decode only a subset of low `PADDR` bits, so implemented registers can physically repeat inside a 64-KiB slot. These mirrors are not architectural addresses.

Firmware and verification shall use only the exact offsets listed here or in the corresponding peripheral specification.

## 8. Reserved / Unmapped Access Behavior

The active baseline does not provide a complete bus-error architecture.

Unmapped/default accesses can complete with:

```text
HRDATA = 0
HREADY = 1
HRESP  = OKAY
```

and invalid APB slots can similarly return zero/ready. Software shall not depend on this behavior.

## 9. PLIC Address Status

No PLIC address is currently canonical. The legacy test value `0x5000_0000` is reference-only and does not define the target architecture.

## 10. Approved Target APB / Board-I/O Allocation — Not Yet Active

> **TARGET MIGRATION NOTE — NOT FULLY ACTIVE:** The following allocation is approved by `board_io_architecture.md`. Phase 4A-3A widened the bus infrastructure to `PSEL[15:0]`, but SW/LED peripherals at slots 8/9 are not yet implemented; those slots error until board-I/O migration.

The target APB subsystem expands to:

```text
PSEL[15:0]
```

while preserving every existing slot 0 through 7.

Target allocation:

| Slot | Target base | Target peripheral | Migration status |
|---:|---:|---|---|
| 0 | `0x4000_0000` | UART0 / LoRa | unchanged |
| 1 | `0x4001_0000` | true bidirectional GPIO | same slot, legacy GPIO to be redesigned |
| 2 | `0x4002_0000` | Timer | unchanged |
| 3 | `0x4003_0000` | G-sensor | unchanged |
| 4 | `0x4004_0000` | AES-GCM | unchanged |
| 5 | `0x4005_0000` | ADC Joystick | unchanged |
| 6 | `0x4006_0000` | UART1 / PC | unchanged |
| 7 | `0x4007_0000` | HEX Display | unchanged |
| 8 | `0x4008_0000` | SW | new target peripheral |
| 9 | `0x4009_0000` | LED | new target peripheral |
| 10–15 | `0x400A_0000` – `0x400F_0000` | Reserved | future use |

Target board-I/O ownership becomes:

```text
GPIO_BASE = 0x4001_0000  -> reusable true GPIO on external bidirectional pins
SW_BASE   = 0x4008_0000  -> dedicated SW[9:0] input + local IRQ
LED_BASE  = 0x4009_0000  -> dedicated LEDR[9:0] output
```

The local SW and LED register contracts are defined in `sw.md` and `led.md`; cross-cutting ownership and migration rules are defined in `board_io_architecture.md`.

### 10.1 Promotion rule

The target addresses above are **approved future assignments** but shall not be treated as implemented hardware until the cleanup implementation updates:

- AHB-to-APB bridge select width,
- decoder and response muxes,
- top-level peripheral instances,
- firmware constants/drivers,
- RTL/DV regression,
- FPGA board acceptance.

After that migration is verified, this document may be revised so the 16-slot map becomes the active canonical map rather than a target note.

## 11. Firmware Cross-Check

The current active firmware map still contains:

```text
UART0_BASE       = 0x4000_0000
GPIO_BASE        = 0x4001_0000
TIMER_BASE       = 0x4002_0000
GSENSOR_BASE     = 0x4003_0000
AES_GCM_BASE     = 0x4004_0000
JOYSTICK_BASE    = 0x4005_0000
UART1_BASE       = 0x4006_0000
HEX_DISPLAY_BASE = 0x4007_0000
```

`SW_BASE = 0x4008_0000` and `LED_BASE = 0x4009_0000` shall be added to production firmware only as part of the corresponding cleanup implementation.

## 12. Related Specifications

This document shall remain consistent with:

- `soc_architecture.md`
- `memory_subsystem.md`
- `ahb_fabric.md`
- `apb_subsystem.md`
- peripheral-specific specifications
- `sw.md`
- `led.md`
- `board_io_architecture.md`
- future PLIC specification

## Phase 4A-2 Approved Cleanup Target (partly active in Phase 4A-3A)

The canonical address map is unchanged. Under frozen A2, unmapped AHB addresses, DMEM addresses above its canonical extent, VGA gaps/aliases, APB aliases outside the canonical aperture, reserved APB slots, noncanonical register offsets, and unsupported sizes return the project two-cycle ERROR response; pre-cleanup zero/OKAY mirrors are not architectural allocations. A3 restricts the framebuffer to naturally aligned 32-bit writes; reads and subword writes fault, while VRAM_STATUS/CONTROL retain their own register semantics. A1 fixes the generic GPIO bank at slot 1 to 16 bits on JP1 GPIO_0–GPIO_15; existing UART/LoRa pins remain separate. A5 defines COMPARE=N as exactly N PCLK counting edges after START, including immediate completion for N=0. A1/A5 are approved targets, not implementation claims.

**Phase 4A-3A active scope:** the public RTL now decodes only the 32 KiB DMEM range and canonical APB aperture, rejects noncanonical bus/APB accesses with two-cycle ERROR, and enforces the A3 framebuffer bus-access policy. Directed decode, error, and CPU-fault tests pass. A1 GPIO, A5 timer, and SW/LED slot integration remain target behavior; this paragraph does not promote them.
