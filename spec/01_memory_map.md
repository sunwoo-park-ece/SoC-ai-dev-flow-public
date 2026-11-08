# Baseline SoC Memory Map Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `memory_map.ko.md` conflict, this file is authoritative.
>
> **Parent specification:** `soc_architecture.md`.


## Current Legacy contract and assurance boundary

Current allocation uses a 16-bit APB select vector with slots 0..9 populated and 10..15 reserved/error. Each slot is a routing aperture, not 64 KiB of valid registers. DMEM decode is exactly 32 KiB at `0x1000_0000..0x1000_7FFF`; the old upper-half alias is rejected. Full production allocation and selected-test omission must remain distinct. Aligned 32-bit peripheral accesses use the bridge canonical-offset allowlist; invalid slot/offset/size/alignment produces two-cycle ERROR before peripheral selection. Direction policy remains peripheral-owned.

Existing requirement/AC IDs and frozen intent are preserved. Pre-cleanup descriptions that conflict with this current contract are historical, not new implementation requirements. Status cites the existing accepted scope in the read-only tracker; this reconciliation does not promote it.

Traceability: [AMBA_SoC_TOP.v](../rtl/soc/AMBA_SoC_TOP.v); [AHB_APB_bridge.v](../rtl/bus/AHB_APB_bridge.v); [soc_memory_map.h](../firmware/include/soc_memory_map.h).

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

Current map; routing apertures do not make every byte a valid register.

| Range | Capacity / role |
|---|---|
| `0x0000_0000..0x0000_3FFF` | 16 KiB CPU-local IMEM |
| `0x1000_0000..0x1000_7FFF` | 32 KiB DMEM; upper alias rejected |
| `0x2000_0000..0x2000_95FF` | 38,400-byte write-only aligned-word framebuffer |
| `0x2001_0000`, `0x2001_0004` | VGA STATUS / CONTROL |
| `0x4000_0000..0x400F_FFFF` | 16-slot APB routing aperture; slots 0..9 populated |
| Other / gap / alias | Reserved; qualified invalid data accesses ERROR |


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

Current `PSEL[15:0]` allocation. Slots are 64 KiB apertures; only exact canonical word offsets are accessible.

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

## 6. Active Baseline Peripheral Register Offsets

### 6.1 UART0 / UART1

```text
+0x00 UART_DATA
+0x04 UART_STATUS
+0x08 UART_CONTROL
+0x0C UART_BAUD
```

UART0 base is `0x4000_0000`; UART1 base is `0x4006_0000`.

### 6.2 GPIO

Base `0x4001_0000`; current P04 registers, independent of SW/LED.

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

### 6.3 Timer

```text
0x4002_0000 +0x00 TIMER_CTRL
0x4002_0000 +0x04 TIMER_COUNT
0x4002_0000 +0x08 TIMER_COMPARE
0x4002_0000 +0x0C TIMER_STATUS
```

### 6.4 G-sensor

```text
+0x00 HOLD_XY    RO
+0x04 HOLD_Z     RO
+0x08 STATUS     RO
+0x0C HOLD_SEQ   RO
+0x10 SNAP_CTRL  WO
```

P09B uses the unchanged slot-3 base. Detailed coherent CAPTURE/read/RELEASE and direction/error semantics remain owned by [G-sensor](12_gsensor.md). No independent SPI MMIO is allocated.

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

### 6.6 ADC / Joystick Policy — P11 v2 implemented / bounded acceptance

Canonical base: `0x4005_0000` (`ADC_BASE`). A temporary firmware `JOYSTICK_BASE` alias may remain only during migration.

All accesses are naturally aligned 32-bit words. Exact local-offset decode is required; low-bit mirrors are non-architectural and shall return the system error response.

```text
+0x00 NAME0             RO  "apb-"
+0x04 NAME1             RO  "adc "
+0x08 VERSION           RO  0x0002_0000
+0x0C ADC_CTRL          RW/W1P: ENABLE[0], CAPTURE[1], CLEAR_ERROR[2]
+0x10 ADC_STATUS        RO
+0x14 FRAME_SEQ         RO  HOLD sequence
+0x18 VALID_MASK        RO  HOLD valid mask
+0x1C CH1_RAW           RO  HOLD[CH1][11:0]
+0x20 CH2_RAW           RO  HOLD[CH2][11:0]
+0x24 CH3_RAW           RO  reserved canonical channel address, baseline 0
+0x28 CH4_RAW           RO  reserved canonical channel address, baseline 0
+0x2C CH5_RAW           RO  reserved canonical channel address, baseline 0
+0x30 CH6_RAW           RO  reserved canonical channel address, baseline 0
+0x34 LIVE_SEQ          RO
+0x38 LIVE_VALID_MASK   RO
+0x3C ACTIVE_MASK       RO  baseline 0x03
+0x40 JOY_CENTER_X      RW  reset 2048
+0x44 JOY_CENTER_Y      RW  reset 2048
+0x48 JOY_DEADZONE      RW  reset 300
+0x4C JOY_STATUS        RO
+0x50..0x5C             reserved / ERROR
+0x60 FRAME_COUNT       RO
+0x64 ERROR_STATUS      RO sticky
+0x68..0xFC             reserved / ERROR
```

CH3..CH6 offsets are reserved now to permit future six-channel activation without relocating the raw-data ABI. They are valid read-only addresses but return zero in the P11 Clean Baseline and their valid-mask bits remain clear.

`ADC_CTRL.CAPTURE` with no newer LIVE frame is an accepted OKAY no-op and preserves HOLD. Writes to RO registers, reserved offsets, malformed control values, unsupported sizes, and noncanonical offsets are errors with no peripheral side effect.

This is the implemented P11 canonical CPU register map. Existing source-bound acceptance and limitations are in [15_adc_joystick.md](15_adc_joystick.md). The local ADC upper-zero decode observation does not allocate a CPU alias or authorize rebasing.

### 6.7 HEX Display

```text
0x4007_0000 +0x00 HEX_VALUE
0x4007_0000 +0x04 HEX_CTRL
0x4007_0000 +0x08 HEX_RAW_LOW
0x4007_0000 +0x0C HEX_RAW_HIGH
```

## 7. Register Mirroring

The bridge rejects noncanonical CPU addresses before peripheral selection. Timer/GPIO/UART compare the full 16-bit local offset; upper slot ownership is supplied by integration. AES v2 compares the full canonical 32-bit address, so zero-based/rebased APB is not interchangeable. Direct local reserved behavior remains peripheral-owned; it is not permission for CPU aliases.

## 8. Reserved / Unmapped Access Behavior

A valid unmapped or rejected data access returns project two-cycle ERROR: `HRESP=01,HREADY=0`, then `HRESP=01,HREADY=1`; it must have no rejected slave side effect. Final ERROR cancels the following address. Ownerless idle defaults `HRDATA=0,HREADY=1,HRESP=00` are not an unmapped acknowledgement. CPU final load/store ERROR maps to causes 5/7 with precise PC; pre-bus misalignment causes 4/6 remain separate. Bridge validation rejects unsupported size/alignment/slot/offset before real PSEL. Canonical RO/WO direction policy remains peripheral-specific.

## 9. PLIC Address Status

No PLIC address is currently canonical. The legacy test value `0x5000_0000` is reference-only and does not define the target architecture.

## 10. Current P04 Board-I/O Allocation

P04 implemented the allocation above, decoder/response mux, GPIO/SW/LED and firmware constants. SW uses +0x00 DATA, +0x04 IRQ_ENABLE, +0x08 IRQ_PENDING; LED uses +0x00 DATA. gpio_irq/sw_irq remain local wires without CPU routing. Accepted pin/OE scope and STA-002/board closure are separate.

## 11. Firmware Cross-Check

Current `firmware/include/soc_memory_map.h` defines the bases and GPIO offsets above, including SW_BASE=0x4008_0000 and LED_BASE=0x4009_0000. JOYSTICK_BASE is a deprecated alias for ADC_BASE, not a second peripheral allocation.

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

The canonical address map is unchanged. Under frozen A2, unmapped AHB addresses, DMEM addresses above its canonical extent, VGA gaps/aliases, APB aliases outside the canonical aperture, reserved APB slots, noncanonical register offsets, and unsupported sizes return the project two-cycle ERROR response; pre-cleanup zero/OKAY mirrors are not architectural allocations. A3 restricts the framebuffer to naturally aligned 32-bit writes; reads and subword writes fault, while VRAM_STATUS/CONTROL retain their own register semantics. A1 fixes the generic GPIO bank at slot 1 to 16 bits on JP1 GPIO_0–GPIO_15; existing UART/LoRa pins remain separate. A5 defines COMPARE=N as exactly N PCLK counting edges after START, including immediate completion for N=0. This paragraph records the historical Phase 4A-2 target; P04 GPIO/SW/LED and P06 Timer subsequently implemented A1/A5 within their separately accepted scopes.

**Historical Phase 4A-3A scope:** the public RTL now decodes only the 32 KiB DMEM range and canonical APB aperture, rejects noncanonical bus/APB accesses with two-cycle ERROR, and enforces the A3 framebuffer bus-access policy. Directed decode, error, and CPU-fault tests pass. A1 GPIO, A5 timer, and SW/LED slot integration remain target behavior; this paragraph does not promote them.

## P09B G-sensor allocation — paired publication update

> **Current Public integration:** This implementation is current with the paired P09B source/documentation commits. Earlier candidate wording in this section is pre-publication provenance only.

> **Publication synchronization:** This contract becomes the Public contract only when the matching P09B source and documentation commits are both published. Until then the pinned Public main remains historical.

The canonical G-sensor base remains `0x4003_0000` (APB slot 3). The P09B Public implementation provides exactly five naturally aligned 32-bit register offsets: `+0x00` HOLD_XY (read), `+0x04` HOLD_Z (read), `+0x08` STATUS (read), `+0x0C` HOLD_SEQ (read), and `+0x10` SNAP_CTRL (write). Their direction, validity, zero-gated HOLD readback and exact commands are specified in [12_gsensor.md](12_gsensor.md). All other offsets, aliases, unsupported sizes and wrong-direction accesses fault through the existing two-cycle AHB ERROR path before wrapper side effect. No APB aperture or neighboring slot changes.
