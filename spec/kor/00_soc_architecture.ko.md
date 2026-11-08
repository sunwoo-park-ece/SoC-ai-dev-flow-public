# Baseline SoC 아키텍처 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `soc_architecture.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **범위:** `rtl/`의 현재 FPGA 보드 검증 baseline. `verification/legacy/` 아래의 동결된 PLIC 개발 snapshot은 제외한다.

## 현행 Legacy 계약과 보증 범위

Production baseline은 전체 `AMBA_SoC_TOP`이다. RV32I 5단계 CPU 하나, CPU-local IMEM, DMEM, VGA와 `PSEL[15:0]`의 APB slot 0..9를 포함하며 slot 10..15는 오류다. GPIO는 P04 16-pin 양방향 bank이고 SW/LED는 slot 8/9로 분리된다. P07 UART DATA write는 TX busy 동안 대기할 수 있다. P06 Timer는 정확히 N edge인 one-shot이며 architectural machine timer가 아니다.

P14 `selected_soc`은 slot 0,1,2,4,6만 노출하고 나머지는 default ERROR인 test-only 구성이다. Production map을 대체하지 않는다. CPU smoke는 AES VERSION을 읽으며 별도 real-core KAT와 CPU/real-AES positive replay는 각각의 한정된 범위만 뒷받침한다. P14 selective cleanup은 완료됐지만 Clean Baseline v1은 `NOT_RELEASED`다. 이 Legacy 계약은 PLIC, ACLINT, AXI, DMA, dual hart, 새 IRQ 배정을 구현하지 않는다.

기존 requirement/AC ID와 동결 의도를 유지한다. 아래 현행 계약과 충돌하는 cleanup 전 설명은 역사적 기록이며 새 구현 요구가 아니다. 상태는 읽기 전용 tracker의 기존 수용 범위를 인용하며 이 정합화로 승격하지 않는다.

추적: [AMBA_SoC_TOP.v](../../rtl/soc/AMBA_SoC_TOP.v); [README.md](../../verification/selected_ip/README.md).

## 1. 목적

이 문서는 import된 FPGA SoC baseline의 최상위 아키텍처를 정의한다. 이후의 세부 specification, RTL 변경, firmware, verification, FPGA integration 작업이 공통으로 따라야 하는 상위 아키텍처 경계를 고정하는 것이 목적이다.

현재 구현은 authoritative `spec/` flow보다 먼저 만들어졌으므로, 이번 문서는 **baseline 복원(reconstruction)** 성격을 가진다. 즉 활성 FPGA RTL, firmware memory map, Quartus active source list, 보존된 validation evidence를 이용해 실제 구현된 아키텍처를 역으로 복원한다. 이 baseline specification이 승인된 이후의 변경은 RTL에서 다시 추론하는 방식이 아니라 `spec/`을 기준으로 진행해야 한다.

이 문서는 세부 register map이나 peripheral의 cycle-level 동작까지 중복해 적지 않는다. 해당 요구사항은 각 하위 specification 문서에서 정의한다.

## 2. 현재 Baseline 복원 시 Source-of-Truth 경계

현행 `spec/`가 계약 권위를 소유한다. Active top/source list, RTL/FW, test 및 수용 evidence는 구현/보증을 확인하는 근거이며 동결 계약을 덮어쓰지 않는다. 불일치는 Owner 결정 대상으로 남긴다. Historical/legacy snapshot은 현행 권위가 아니다.

## 3. Baseline 식별

Baseline은 Intel/Altera **DE10-Lite** 보드와 **MAX 10 10M50DAF484C7G** FPGA를 대상으로 한다.

Active SoC top-level module은 다음과 같다.

```text
AMBA_SoC_TOP
```

외부 system input clock은 **50 MHz**이다. 현재 baseline에서 CPU/AHB/APB domain은 이 clock으로 동작하며, display 및 sensor 관련 기능에는 별도의 local clock이 생성된다.

Baseline에는 다음이 포함된다.

- RV32I 5-stage pipelined CPU.
- Local instruction memory.
- Single-master AHB-style system data bus.
- AHB-connected data memory.
- AHB-connected VGA/VRAM subsystem.
- AHB-to-APB bridge.
- 8개의 APB peripheral slot.
- LoRa와 PC 통신용 dual UART.
- GPIO.
- Polling timer.
- Internal SPI engine을 포함한 ADXL345 accelerometer subsystem.
- AES-GCM accelerator.
- generic MAX 10 ADC acquisition peripheral + optional joystick policy child.
- 6-digit seven-segment display controller.
- Dual VRAM buffer를 사용하는 VGA 640x480 display path.

이 baseline에는 **integrated PLIC 또는 external interrupt path가 없다.**

## 4. Top-Level Architecture

### 4.1 Block Diagram

```text
                                      +----------------------------------+
                                      |        AMBA_SoC_TOP              |
                                      |                                  |
      clk 50 MHz -------------------->| HCLK / system clock              |
      KEY[0] ------------------------>| reset conditioning               |
                                      |                                  |
                                      |  +----------------------------+  |
                                      |  | RV32I 5-stage CPU          |  |
                                      |  | RV32I46F5SPMMIO            |  |
                                      |  |                            |  |
                                      |  | +------------------------+ |  |
                                      |  | | Local IMEM, 16 KiB     | |  |
                                      |  | +------------------------+ |  |
                                      |  +-------------+--------------+  |
                                      |                |                 |
                                      |      EX/MEM load/store          |
                                      |                |                 |
                                      |  +-------------v--------------+  |
                                      |  | AHB_Master_Interface       |  |
                                      |  | single-beat transfers      |  |
                                      |  +-------------+--------------+  |
                                      |                |                 |
                                      |      system data bus            |
                                      |                |                 |
                     +----------------+----------------+----------------+
                     |                |                |                |
                     v                v                v                |
              +-------------+  +----------------+  +----------------+  |
              | AHB DMEM    |  | AHB VRAM/VGA   |  | AHB->APB       |  |
              | 32 KiB BRAM |  | dual buffer    |  | bridge         |  |
              |             |  | 640x480 1 bpp  |  +-------+--------+  |
              +-------------+  +-------+--------+          |           |
                                      |                    | APB       |
                                      | VGA                |           |
                                      v                    v           |
                              VGA_R/G/B, HS, VS     +------+------+----+------+
                                                    |      |      |           |
                                                    v      v      v           v
                                                 UART0   GPIO   TIMER      GSENSOR
                                                 LoRa                    ADXL345
                                                    |      |      |           |
                                                    +------+------+-----------+
                                                           |
                                                    +------+------+-----------+
                                                    |      |      |           |
                                                    v      v      v           v
                                                 AES-GCM JOYSTICK UART1      HEX
                                                         ADC     PC          6-digit
                                      +----------------------------------+
```

### 4.2 Architectural Data Path

Baseline에는 CPU 관점에서 두 개의 서로 다른 memory path가 존재한다.

1. **Instruction fetch path**
   - CPU는 CPU-side implementation에 포함된 local instruction memory에서 instruction을 fetch한다.
   - Instruction fetch traffic은 AHB system data bus를 통과하지 않는다.

2. **Load/store path**
   - CPU load/store operation은 pipeline에서 `AHB_Master_Interface`로 전달된다.
   - Address phase는 EX-stage memory operation에서 생성된다.
   - Store data는 bus data phase와 timing을 맞추기 위해 다음 pipeline stage에서 전달된다.
   - Bus backpressure는 `HREADY`를 통해 CPU pipeline stall request로 변환된다.

이 baseline에는 instruction cache, data cache, DMA master, multi-master arbitration fabric이 없다.

## 5. CPU Architecture Boundary

Integrated CPU module은 `RV32I46F5SPMMIO`이다.

CPU baseline은 다음과 같다.

- 32-bit RISC-V integer core.
- RV32I software model.
- 5-stage pipeline: IF, ID, EX, MEM, WB.
- 32-bit address/data path.
- Pipeline forwarding 및 hazard handling.
- CPU/memory path 내부의 RISC-V byte/halfword/word load/store alignment support.
- Bus-induced full-pipeline stall support.
- 구현된 exception/trap case에 대한 synchronous trap handling.

CPU 하나만을 generic reusable AMBA master로 정의하지 않는다. SoC integration contract는 다음 두 블록의 조합이다.

```text
RV32I46F5SPMMIO
        +
AHB_Master_Interface
```

Pipeline-to-bus timing, transfer size encoding, store alignment, load extension, stall semantics는 `cpu_interface.md`에서 정의한다.

## 6. Interconnect Architecture

### 6.1 System Bus Topology

Baseline은 **single-master, non-arbitrated AHB-style data interconnect** 구조이다.

Active bus master는 하나뿐이다.

```text
CPU -> AHB_Master_Interface
```

두 번째 AHB master가 존재하지 않으므로 bus arbiter도 없다.

AHB master는 single transfer만 생성한다. Burst operation은 baseline architectural contract에 포함되지 않는다.

Top-level은 세 개의 logical AHB target에 대해 address decode와 data-phase response mux를 수행한다.

| Target | Canonical base | Architectural purpose |
|---|---:|---|
| DMEM | `0x1000_0000` | CPU data RAM |
| VRAM/VGA | `0x2000_0000` | Framebuffer 및 display control |
| APB bridge | `0x4000_0000` | Low-bandwidth peripheral subsystem |

세부 decode와 response timing은 `ahb_fabric.md`에서 정의한다.

### 6.2 AHB-to-APB Bridge

APB bridge는 CPU의 AHB data transfer를 APB SETUP/ACCESS transaction으로 변환한다.

현재 APB domain은 HCLK와 동일한 effective system clock을 사용한다.

```text
PCLK = HCLK = 50 MHz
```

Bridge는 다음 기능을 담당한다.

- APB address/control capture.
- SETUP/ACCESS sequencing.
- APB transfer 중 AHB backpressure 생성.
- 16-bit `PSEL` generation (slot 0..9 배정).
- APB read data를 AHB로 반환.

UART DATA busy write는 PREADY-low로 wait할 수 있으며 bridge는 이를 HREADY로 CPU에 전달한다.

세부 동작은 `apb_subsystem.md`에서 정의한다.

## 7. Memory Architecture

### 7.1 Instruction Memory

Canonical instruction-memory region은 다음과 같다.

```text
0x0000_0000 - 0x0000_3FFF   16 KiB
```

Instruction memory는 선택된 FPGA IMEM image로 초기화되며 CPU fetch path 내부에 존재한다.

### 7.2 Data Memory

Canonical data-memory region은 다음과 같다.

```text
0x1000_0000 - 0x1000_7FFF   32 KiB
```

DMEM subsystem은 FPGA block RAM을 사용하며 byte write enable을 지원한다. 또한 store-to-load BRAM hazard 상황에서 필요한 byte만 bypass store data와 BRAM read data를 merge하는 처리가 포함되어 있다.

위 32 KiB 영역만 software-visible architectural memory region이다. RTL의 coarse decode 때문에 이 범위 밖에서 발생할 수 있는 응답은 **implementation alias이며 supported architectural address로 취급하지 않는다.**

세부 BRAM timing과 hazard semantics는 `memory_subsystem.md`에서 정의한다.

### 7.3 VGA Framebuffer Memory

VGA subsystem은 두 개의 framebuffer memory를 소유하며, 현재 CPU-visible **back buffer**를 AHB VRAM window로 노출한다.

Framebuffer format은 다음과 같다.

- Visible resolution: 640 x 480.
- Pixel depth: 1 bit per pixel.
- CPU write granularity: 32-bit word.
- One frame: 307,200 bits = 38,400 bytes = 9,600 32-bit words.
- Front/back-buffer operation을 위해 두 개의 physical framebuffer 사용.

Display-control register도 framebuffer window와 동일한 AHB target 안에 존재한다.

세부 display behavior는 `vga.md`에서 정의한다.

## 8. APB Peripheral Architecture

현행 full-production APB 배정은 [메모리 맵](01_memory_map.ko.md)을 따른다. PSEL[15:0]에서 slot 0..9가 배정되고 slot 10..15는 ERROR다. GPIO는 JP1 true GPIO이며 SW/LED는 독립 slot 8/9다. Routing aperture 전체가 유효 register는 아니다.

## 9. Display Architecture

Active FPGA display path는 **APB VGA peripheral이 아니다.**

실제 active path는 다음과 같다.

```text
CPU
  |
  | AHB
  v
AHB_VRAM_DUAL_BUFFER
  |-- VRAM0
  |-- VRAM1
  |-- HW_Cleaner
  |-- VGA prefetch/read path
  |-- VGA timing generator
  +--> VGA_R / VGA_G / VGA_B / VGA_HS / VGA_VS
```

Display subsystem은 board 50 MHz clock으로부터 25 MHz pixel clock을 생성하고 640x480 VGA timing을 구현한다.

Front/back buffer 역할은 software-triggered swap command로 전환된다. Hardware clear engine은 CPU가 word 단위로 직접 지우지 않고도 current back buffer를 clear할 수 있다.

VSync event는 HCLK domain으로 synchronize되어 software synchronization용 status flag로 노출된다.

`rtl/video/vga/APB_VGA_Top.v`는 Quartus source set에 존재하지만 **`AMBA_SoC_TOP`의 실제 active display path에는 instantiate되지 않는다.** Project source list에 포함되어 있다는 이유만으로 active architectural block으로 간주하면 안 된다.

## 10. UART Architecture

두 UART peripheral은 공통 software-visible register structure를 공유한다.

- UART0 at `0x4000_0000`: LoRa communication.
- UART1 at `0x4006_0000`: PC/debug communication.

두 UART 모두 다음 기능을 제공한다.

- 8-bit transmit data.
- Receive path.
- 16-byte receive FIFO.
- Programmable baud divisor.
- TX-ready / RX-ready / RX-error status.

UART0는 추가로 synchronized LoRa AUX status를 제공한다.

현재 UART control register는 future control/interrupt 기능을 위한 storage 역할만 하며 baseline에는 architectural interrupt generation이 구현되어 있지 않다.

세부 동작은 `uart.md`에서 정의한다.

## 11. Timer Architecture

APB timer는 software-polled counter/compare peripheral이다.

다음 기능을 제공한다.

- Enable control.
- 32-bit counter.
- 32-bit compare value.
- Sticky READY/completion status.
- Software clear of READY.

Active FPGA baseline에서 timer는 **interrupt를 생성하지 않는다.**

세부 cycle behavior는 `timer.md`에서 정의한다.

## 12. GPIO Architecture

P04 APB_GPIO는 SW/LED와 분리된 16-pin true bidirectional bank다. DIR=0은 input/Hi-Z, DIR=1은 DATA_OUT drive이고 DATA_IN은 2FF synchronized pin 값이다. IRQ는 local-only다. 상세 reset/edge/W1C 계약은 GPIO owning spec을 따른다.

## 13. Accelerometer 및 SPI Architecture

ADXL345 accelerometer는 APB `GSENSOR` block을 통해 software에 노출된다.

Accelerometer에 사용되는 SPI controller는 **G-sensor subsystem 내부 블록**이다. Generic CPU-visible SPI controller가 아니며 독립적인 MMIO base address도 없다.

G-sensor subsystem은 다음을 소유한다.

- Sensor reset/startup sequencing.
- Local SPI clock generation.
- ADXL345 initialization.
- Periodic/multi-byte sensor read.
- Software-visible X/Y/Z sample register.

`gsensor.md`는 APB-visible accelerometer contract를 정의하고, `spi.md`는 내부 SPI engine과 accelerometer subsystem의 관계를 정의한다.

## 14. AES-GCM Architecture

AES-GCM peripheral은 integrated AES-GCM core를 감싸는 APB wrapper이다.

Wrapper는 key, nonce/direction, sequence, length, payload, authentication tag, control, status register를 software에 노출하고 software command를 내부 accelerator handshake sequence로 변환한다.

Current baseline은 APB wrapper boundary에서 128-bit payload block transaction 구조를 사용하며, 현재 firmware stack은 AES-128-GCM 사용을 전제로 한다.

Register ordering, IV/AAD construction, start/done behavior, encrypt/decrypt mode, tag validation은 `aes_gcm.md`에서 정의한다.

## 15. ADC / Joystick Architecture — P11 implemented / bounded acceptance

P11은 slot 5를 joystick-owned ADC wrapper에서 **generic ADC MMIO + optional joystick policy child** 구조로 변경한다.

```text
MAX 10 ADC / adc_qsys
  -> ADC Acquisition Engine (adc_sys_clk, sole command owner)
  -> stable scan-frame req/ack CDC
  -> APB_ADC_Controller (PCLK)
       -> LIVE / CAPTURE-only HOLD
       -> CH1..CH6 raw MMIO (CH3..CH6 baseline reserve)
       -> seq / valid mask / frame count / error
       -> combinational Joystick_Policy
```

Internal 구조는 6채널까지 표현하며 Clean Baseline은 CH1/CH2만 scan한다. 참조 DE10-Lite schematic에서 CH1/CH2는 ADC_IN0/ADC_IN1(JP8 A0/A1)이며 기본 policy는 CH1=X, CH2=Y다. 수용된 physical polarity/direction은 [15_adc_joystick.ko.md](15_adc_joystick.ko.md) §3.4 구성에 한정되며 다른 cable/sensor/board는 별도 qualification이 필요하다. 현재 generated ADC는 1 MSPS total rate, 10 MHz ADC input, 25 MHz `adc_sys_clk`으로 확인됐다. Scan frame은 동시 analog sample이 아니라 sequential sample을 하나의 coherent publication identity로 묶는 구조다.

Software snapshot은 LIVE + CAPTURE-only HOLD이며 ADC에는 RELEASE가 없다. 이는 P09 G-sensor CAPTURE/RELEASE ownership lifecycle과 의도적으로 다르다. Hardware joystick child와 independent firmware policy를 병행해 HW/FW equivalence 검증에 사용한다.

세부 contract는 `15_adc_joystick.md`, reset/CDC는 `06_reset_clock.md`가 정본이다. P11 ADC-001..006/CDC-003/FW-009의 기존 수용은 해당 문서의 과거 source/evidence 범위에 한정되며 새 verdict나 전반 physical/STA closure가 아니다. 수용된 2채널 관찰은 50 MHz에서 299 CPU cycles/frame(2,810,880 frame에 걸쳐 약 167.22 kframes/s)이며 보장 rate나 6채널 characterization이 아니다.

## 16. Seven-Segment Display Architecture

HEX peripheral은 DE10-Lite의 6개 seven-segment display를 제어한다.

다음 기능을 지원한다.

- Packed value register를 통한 6개의 hexadecimal nibble.
- Decode mode.
- Raw segment mode.
- Display enable.
- Active-low segment drive.

세부 동작은 `hex_display.md`에서 정의한다.

## 17. Reset Architecture

External board reset source는 `KEY[0]`이며 active-low reset request로 처리한다.

Top-level은 system release 전에 reset conditioning을 수행한다.

1. Push button에 의한 asynchronous assertion.
2. System clock domain으로 2-flop synchronization.
3. 50 MHz 기준 약 20 ms release qualification.
4. Internal active-low system reset (`HRESETn` / APB `PRESETn`) 생성.

각 sub-block은 내부적으로 reset polarity를 변환하거나 추가 local reset sequencing을 가질 수 있다.

세부 reset-domain/release behavior는 `reset_clock.md`에서 정의한다.

## 18. Clock Architecture

Baseline clock structure는 다음과 같다.

| Clock | Nominal frequency | Primary consumers |
|---|---:|---|
| Board `clk` / HCLK | 50 MHz | CPU, AHB, top-level system logic |
| PCLK | 50 MHz | APB bridge 및 APB peripherals |
| VGA pixel clock | 25 MHz | VGA timing 및 framebuffer read path |
| G-sensor SPI clocks | 2 MHz-class generated clocks | ADXL345 SPI engine |
| ADC/Qsys clocks | Vendor-IP generated/managed | MAX 10 ADC subsystem |

Current timing constraint set은 external 50 MHz input clock을 명시적으로 constrain한다. Migration baseline은 generated-clock/CDC constraint coverage가 완전하다고 주장하지 않으며 별도의 timing review가 필요하다.

Clock generation, reset interaction, CDC 요구사항은 `reset_clock.md`에서 정의한다.

## 19. Interrupt 및 Trap Architecture

### 19.1 External Interrupt

Active baseline에는 **architectural external interrupt support가 없다.**

구체적으로 다음이 적용된다.

- `AMBA_SoC_TOP`에 PLIC이 instantiate되어 있지 않다.
- Active CPU top에 external interrupt request input이 연결되어 있지 않다.
- UART peripheral은 CPU interrupt를 생성하지 않는다.
- Timer는 CPU interrupt를 생성하지 않는다.
- Baseline firmware는 해당 peripheral을 polling 방식으로 사용한다.

`verification/legacy/plic_snapshot/`에 보존된 PLIC implementation은 development/reference material일 뿐이다. Active FPGA synthesis path에서 제외되며 baseline functionality로 취급하지 않는다.

### 19.2 Synchronous Trap Support

CPU에는 synchronous trap/exception handling logic과 현재 trap path에 필요한 machine CSR support가 존재한다. Baseline은 ECALL, EBREAK, misaligned access/instruction case, trap-vector redirection, MRET-related return behavior와 관련된 처리를 포함한다.

이 synchronous trap mechanism은 아직 integrate되지 않은 external interrupt architecture와 별개의 기능이다.

현재 trap behavior 및 future PLIC integration boundary는 `interrupt_architecture.md`에서 정의한다.

## 20. Firmware Architecture Contract

Baseline firmware는 bare-metal RISC-V software이다.

Firmware contract는 다음을 포함한다.

- IMEM에서 code execution.
- Linker script에 따른 DMEM 내 data/constants/BSS/stack 배치.
- Volatile load/store를 통한 memory-mapped peripheral access.
- Polling-based UART 및 timer operation.
- AHB VRAM window를 통한 VGA framebuffer/display-control access.
- Current APB peripheral용 register-level driver.

Peripheral MMIO는 각 peripheral document에서 정의한다. 특정 peripheral specification이 narrower access를 명시적으로 허용하지 않는 한 control/status register에는 naturally aligned 32-bit access를 사용하는 것을 기본 contract로 한다.

전체 HW/SW boundary는 `firmware_contract.md`에서 정의한다.

## 21. Address-Space Policy

Architectural address map은 `memory_map.md`에서 정의하는 canonical region 집합이다.

Current RTL에는 coarse top-level decode expression이 존재하여 canonical region 밖에서 mirrored/aliased behavior가 나타날 수 있다. 이러한 동작은 **implementation quirk**이며 supported software contract가 아니다.

따라서 다음 정책을 적용한다.

- Firmware는 canonical address만 사용한다.
- Verification은 canonical region을 우선 검증하고 alias behavior는 별도의 implementation observation으로만 다룰 수 있다.
- Canonical region이 유지되는 한 future RTL cleanup에서 decode를 더 엄격하게 바꾸어도 architectural compatibility break로 간주하지 않는다.
- 신규 software는 undocumented alias에 의존해서는 안 된다.

## 22. Error-Response Policy

유효 unmapped/rejected data 접근은 project 2-cycle ERROR인 `HRESP=01,HREADY=0` 후 `HRESP=01,HREADY=1`이며 거부된 slave side effect가 없어야 한다. Final ERROR는 다음 주소를 취소한다. Owner 없는 idle 기본값 `HRDATA=0,HREADY=1,HRESP=00`은 unmapped 응답이 아니다. CPU final load/store ERROR는 precise PC와 cause 5/7이며 pre-bus misalignment cause 4/6은 별도다. Bridge는 size/alignment/slot/offset 오류를 실제 PSEL 전에 거부한다. Canonical RO/WO 방향 정책은 peripheral별이다.

## 23. Active, Dormant, Legacy Source 분류

Repository에 source file이 존재하거나 Quartus project source list에 포함되어 있다는 사실만으로 해당 block을 architectural active block으로 보지 않는다.

### 23.1 Active baseline

`AMBA_SoC_TOP`의 active synthesis hierarchy에서 실제로 도달 가능한 block이 architectural active block이다. 여기에는 CPU, bus interface, DMEM, AHB VRAM/VGA subsystem, APB bridge, 위에서 정의한 8개 APB slot이 포함된다.

### 23.2 Dormant/non-instantiated source

일부 synthesizable source는 Quartus source set에 남아 있지만 active SoC top에서 instantiate되지 않는다. 이들은 implementation collateral/reference source이며 추가 active peripheral이 아니다. `APB_VGA_Top.v`가 대표적인 예이다.

### 23.3 Legacy development snapshot

`verification/legacy/plic_snapshot/`에는 frozen PLIC development snapshot과 candidate CPU/timer integration change가 존재한다. Active FPGA source list에서 제외되어 있으며 baseline architecture에 포함되지 않는다.

## 24. Baseline Verification Status

Architecture 존재 여부와 verification evidence는 서로 다른 속성으로 취급한다.

Imported baseline은 Quartus full compile 성공이 재현되었고 historical FPGA result도 보존되어 있다. 현재 선택된 `display_smoke` firmware image는 VGA, HEX, LED diagnostic behavior에 대해 developer-confirmed physical-board operation 기록이 있다.

이 evidence가 모든 integrated peripheral이 `display_smoke`로 다시 검증되었다는 의미는 아니다. 특히 current diagnostic은 end-to-end LoRa, ADC behavior, VGA hardware-clear behavior, external interrupt/PLIC functionality, full timing-constraint completeness를 독립적으로 입증하지 않는다.

각 하위 specification은 필요 시 자신의 implementation/verification status를 별도로 기록한다.

## 25. Baseline Exclusion

다음 기능은 current baseline contract 범위 밖이다.

- PLIC integration.
- External CPU interrupt entry.
- Interrupt-driven timer/UART firmware.
- AXI interconnect.
- Multi-master bus arbitration.
- DMA.
- Data cache.
- Instruction cache.
- External SDRAM controller.
- Cache coherency.
- G-sensor subsystem과 별개의 generic CPU-visible SPI controller.

이 기능들은 future specification과 implementation milestone을 통해서만 도입한다.

## 26. Required Subordinate Specification

이 architecture document는 의도적으로 하위 contract로 분해된다.

```text
spec/
├─ soc_architecture.md          # this document
├─ memory_map.md
├─ memory_subsystem.md
├─ cpu_interface.md
├─ ahb_fabric.md
├─ apb_subsystem.md
├─ interrupt_architecture.md
├─ reset_clock.md
├─ vga.md
├─ uart.md
├─ timer.md
├─ gpio.md
├─ gsensor.md
├─ spi.md
├─ aes_gcm.md
├─ adc_joystick.md
├─ hex_display.md
└─ firmware_contract.md
```

하위 specification과 이 문서가 충돌하면 암묵적으로 해석하지 말고 conflict를 명시적으로 해결해야 한다. 어떤 문서를 갱신할지는 architecture owner가 결정한다.

## 27. 보존 또는 검토가 필요한 Known Baseline Implementation Quirk

향후 specification 작성 중 다음 observation을 숨기지 않고 계속 추적해야 한다.

1. **DMEM coarse decode:** top-level select 범위가 canonical 32 KiB DMEM보다 넓지만 physical BRAM addressing은 32 KiB memory를 구현한다. Non-canonical mirroring은 architectural behavior가 아니다.
2. **VRAM coarse decode:** top-level VRAM selection 범위가 canonical framebuffer/control window보다 넓다. Non-canonical mirroring은 architectural behavior가 아니다.
3. **APB coarse decode:** top/bridge decode로 canonical 8개 slot 밖에서 mirrored peripheral selection이 발생할 수 있다. 지원되는 주소는 canonical region뿐이다.
4. **Bus error architecture 없음:** unmapped access가 trap을 발생시킨다고 보장하지 않는다.
5. **Dormant VGA source:** `APB_VGA_Top.v`는 project source에 존재하지만 active display instance가 아니다.
6. **SPI visibility:** accelerometer SPI controller는 G-sensor subsystem private block이며 independent MMIO peripheral이 아니다.
7. **External interrupt 부재:** preserved PLIC snapshot은 integrated baseline functionality가 아니다.
8. **Timing constraint 완전성 미확립:** 보존된 50 MHz timing result만으로 generated-clock/CDC constraint completeness를 입증하지 않는다.

이 항목들은 documentation cleanup 과정에서 숨기지 않고 관련 subordinate specification에서 의도적으로 보존 또는 해결해야 한다.

## 28. Baseline Architecture Invariant

승인된 future specification이 명시적으로 변경하지 않는 한 다음은 baseline invariant이다.

- CPU software address width는 32 bit이다.
- CPU는 유일한 system data-bus master이다.
- IMEM은 CPU fetch path의 local memory이다.
- Canonical DMEM은 `0x1000_0000`의 32 KiB이다.
- VGA/VRAM은 APB slot이 아니라 AHB-side subsystem이다.
- APB는 `0x4000_0000`부터 `0x4007_FFFF`까지 8개의 canonical peripheral slot을 가진다.
- UART0는 LoRa-facing UART이고 UART1은 PC-facing UART이다.
- G-sensor SPI engine은 G-sensor subsystem 내부 block이다.
- VGA visible resolution은 640x480이며 framebuffer는 1 bit per pixel이다.
- Front/back framebuffer operation에는 두 개의 physical VRAM buffer를 사용한다.
- Baseline에는 integrated PLIC 또는 external CPU interrupt path가 없다.
- System HCLK/PCLK nominal frequency는 50 MHz이다.
- External reset은 active-low `KEY[0]`에서 시작하며 internal release 전에 conditioning된다.

---

**다음 단계의 contract:** `memory_map.md`, `memory_subsystem.md`, `cpu_interface.md`, `ahb_fabric.md`, `apb_subsystem.md` 및 위에서 나열한 peripheral specification.
