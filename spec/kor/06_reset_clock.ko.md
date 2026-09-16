# Baseline SoC Reset / Clock 명세

> **상태:** DRAFT — 현재 활성 FPGA baseline으로부터 복원된 문서이며 Developer + ChatGPT Chat의 최종 검토 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `reset_clock.md`가 충돌할 경우 영어 문서가 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `ahb_fabric.md`, `apb_subsystem.md`.

## 1. 목적

이 문서는 현재 FPGA baseline의 clock/reset architecture를 정의한다. 주요 범위는 다음과 같다.

- board reference clock과 active system clock
- APB clock/reset derivation
- VGA 및 G-sensor generated clock
- ADC/Qsys-managed clock domain
- external reset conditioning 및 distribution
- local reset sequencing
- 알려진 clock-domain crossing(CDC)
- 현재 timing constraint coverage
- PLIC/AXI 전에 반드시 정리해야 할 cleanup item

이 문서는 **현재 구현된 baseline**을 설명한다. 현재 board에서 동작했다는 사실과 모든 CDC/timing path가 production-quality로 증명되었다는 의미는 동일하지 않다. 현재 specification에서 완전히 증명되지 않은 부분은 제한사항으로 명시한다.

## 2. Clock / Reset Overview

```text
DE10-Lite 50 MHz board clock: clk
              |
              +------------------------------+
              |                              |
              v                              v
        HCLK = clk                      adc_qsys
              |                              |
              |                              +--> adc_sys_clk
              |
              +--> PCLK = HCLK
              |      |
              |      +--> APB peripherals
              |      |
              |      +--> G-sensor reset delay
              |             |
              |             +--> spi_pll
              |                    +--> spi_clk     ~2 MHz
              |                    +--> spi_clk_out ~2 MHz, phase-shifted
              |
              +--> VGA PLL
                     |
                     +--> pclk_25 = 25 MHz

KEY[0] (active-low)
      |
      v
2-FF synchronization
      |
      v
~20 ms release qualification
      |
      v
HRESETn / PRESETn
```

현재 baseline은 하나의 main synchronous SoC domain과 여러 generated/local domain으로 구성된다.

## 3. Clock Domain Inventory

| Domain | Clock | Nominal frequency | Source | 주요 consumer | Architectural status |
|---|---|---:|---|---|---|
| System | `HCLK` | 50 MHz | board `clk` 직접 사용 | CPU, AHB fabric, DMEM, AHB-side VGA control/write path | Canonical baseline clock |
| APB | `PCLK` | 50 MHz | `HCLK` | APB peripherals | HCLK와 동일, AHB/APB 경계 자체는 CDC 아님 |
| VGA pixel | `pclk_25` | 25 MHz | `vga_pll`, 50 MHz / 2 | VGA timing, VRAM read port | Generated clock domain |
| G-sensor SPI | `spi_clk` | 2 MHz | `spi_pll` from PCLK | ADXL345/SPI control logic | Local peripheral clock domain |
| G-sensor SPI phase clock | `spi_clk_out` | 2 MHz | second `spi_pll` output | SPI timing engine | Local phase-shifted clock |
| ADC/Qsys | `adc_sys_clk` | vendor/Qsys-managed | `adc_qsys` from board `clk` | ADC command sequencer / ADC subsystem | Generated vendor-managed domain, exact rate는 software contract가 아님 |

현재 AHB와 APB는 서로 다른 clock을 사용하지 않는다. `PCLK`와 `HCLK`는 동일한 50 MHz source이다.

## 4. System Clock

현재 top-level은 다음과 같이 직접 연결한다.

```verilog
wire HCLK = clk;
```

따라서 board의 external `clk` 입력이 실제 CPU/AHB 50 MHz clock이다.

`system_pll` 인스턴스가 주석 처리된 형태로 source에 남아 있지만 현재 active FPGA baseline에는 사용되지 않는다. `system_pll` 관련 source/IP 파일이 존재한다고 해서 현재 CPU가 PLL clock으로 구동된다고 해석하면 안 된다.

### 4.1 Architectural Contract

향후 specification이 clock plan을 변경하기 전까지:

```text
board clk = HCLK = 50 MHz
```

가 baseline system-clock contract이다.

Fmax 측정값과 실제 board operating frequency는 서로 다른 개념으로 관리한다.

## 5. APB Clock

현재 AHB-to-APB bridge는:

```text
PCLK    = HCLK
PRESETn = HRESETn
```

로 정의된다.

따라서:

- CPU/AHB와 APB register logic은 동일한 50 MHz source에 동기된다.
- AHB-to-APB bridge는 protocol conversion을 수행하지만 clock conversion은 수행하지 않는다.
- 현재 HCLK/PCLK 경계만을 위해 async FIFO나 synchronizer가 필요한 구조는 아니다.

향후 APB frequency를 낮추거나 별도 clock source를 사용한다면, RTL 구현 전에 명시적인 CDC/clock-conversion architecture를 먼저 정의해야 한다.

## 6. VGA Pixel Clock

현재 `AHB_VRAM_DUAL_BUFFER`는 `vga_pll`을 사용한다.

```text
input  : CLOCK_50 = 50 MHz
output : pclk_25  = 25 MHz
```

PLL은 50 MHz reference를 divide-by-2 하여 25 MHz를 생성한다.

`pclk_25`의 주요 consumer:

- VGA horizontal/vertical timing
- visible pixel sequencing
- VRAM front-buffer read port
- VGA-side prefetch address generation

반면 AHB-side VRAM write/control logic은 계속 50 MHz HCLK domain에 남는다.

### 6.1 VGA PLL Reset / Lock Behavior

현재 VGA PLL wrapper는 `locked` 출력을 사용하지 않으며 PLL asynchronous reset도 사용하지 않는다.

따라서 baseline은 PLL lock 상태를 확인한 뒤 VGA logic reset을 푸는 구조가 아니다.

이 동작은 현재 구현 특성이지, 향후 권장 reset/clock policy는 아니다.

## 7. G-Sensor SPI Clock

`APB_GSENSOR_MB`는 50 MHz `PCLK`를 입력으로 받고, local reset delay 이후 `spi_pll`을 활성화한다.

`spi_pll`은 두 개의 nominal 2 MHz clock을 생성한다.

```text
spi_clk
spi_clk_out
```

두 번째 clock은 다른 phase로 구성되어 SPI engine에서 `spi_clk`과 함께 사용된다.

정확한 PLL phase 값은 imported G-sensor block의 implementation detail이며 일반 SoC clock contract로 승격하지 않는다. 향후 SPI engine을 재설계할 경우 launch/sample relationship을 별도 specification으로 명시해야 한다.

## 8. ADC / Qsys Clock Domain

현재 top은 `adc_qsys`를 다음과 같이 연결한다.

```text
clk_clk                      <- board clk
clock_bridge_sys_out_clk_clk -> adc_sys_clk
reset_reset_n                <- HRESETn
```

top-level의 작은 channel sequencer는 `adc_sys_clk`에서 동작하며 ADC command interface가 ready일 때 channel 1과 2를 번갈아 선택한다.

현재 `adc_sys_clk`의 정확한 frequency는 vendor/Qsys-managed implementation detail로 취급한다. 추후 ADC specification과 timing review에서 명시적으로 확정하기 전까지 software-visible behavior가 특정 `adc_sys_clk` rate에 의존해서는 안 된다.

## 9. External Reset Source

board reset source는:

```text
KEY[0]
```

이며 active-low이다.

Top-level에서는:

```text
RESETN_BTN = KEY[0]
```

로 사용한다.

현재 reset-conditioning path는 두 단계다.

1. external button level을 HCLK으로 2-FF synchronization
2. 약 20 ms 동안 high가 유지된 뒤 system reset release

## 10. Reset Synchronization / Release Qualification

### 10.1 Input Synchronizer

```text
RESETN_BTN
    |
    v
rstn_meta
    |
    v
rstn_sync
```

`RESETN_BTN=0`이면 두 synchronizer register는 asynchronous하게 0으로 clear된다. 버튼이 high로 release되면 high level이 두 HCLK flip-flop을 통해 전달된다.

### 10.2 Release Qualification

`rstn_sync`가 high가 된 이후 20-bit counter로 reset release를 qualification한다.

```text
1,000,000 cycles @ 50 MHz = 20 ms
```

counter가 `999_999`에 도달하기 전까지 `PRESETN_SYS=0`을 유지하며 이후 high로 release한다.

최종 system reset은:

```text
HRESETn = PRESETN_SYS
```

따라서 button release부터 실제 system release까지는 약 20 ms + synchronizer/clock alignment latency가 필요하다.

### 10.3 Assertion Semantics Quirk

Source comment는 reset low가 즉시 적용되는 것처럼 표현하지만, `PRESETN_SYS` 자체는 `posedge HCLK` block에서만 갱신된다.

즉 external button은 input synchronizer를 asynchronous하게 clear하지만 실제 distributed `HRESETn`은 이후 HCLK edge에서 low가 된다.

이 차이는 verification에서 그대로 고려해야 하며 baseline cleanup 시 intended reset semantics를 명확히 선택해야 한다.

## 11. System Reset Distribution

`HRESETn`이 active SoC의 primary active-low reset이다.

| Consumer | Reset form |
|---|---|
| CPU | `reset = !HRESETn` active-high |
| AHB fabric / slave | `HRESETn` active-low |
| AHB-to-APB bridge | `HRESETn` active-low |
| APB peripheral | `PRESETn`, bridge에서 `PRESETn = HRESETn` |
| VGA / VRAM control | `HRESETn` active-low |
| ADC Qsys | `reset_reset_n = HRESETn` |
| G-sensor wrapper | `PRESETn` 이후 local delayed reset |

현재 top에서 `LEDR[9] = ~HRESETn`으로 연결되어 reset 상태를 시각적으로 확인할 수 있다.

## 12. G-Sensor Local Reset Delay

G-sensor subsystem은 system/APB reset release 이후 별도의 local delay를 추가한다.

`reset_delay.v`는 21-bit counter를 사용하며 bit 20이 0인 동안 active-high `dly_rst`를 유지한다.

50 MHz 기준:

```text
2^20 / 50 MHz = 20.97152 ms
```

개념적인 sequence는:

```text
system PRESETn release
       |
       v
~20.97 ms local delay
       |
       +--> spi_pll areset deassert
       |
       +--> spi_ee_config iRSTN release
```

이 delay는 imported ADXL345 subsystem의 local requirement이며 일반 APB reset requirement가 아니다.

## 13. CDC Inventory

HCLK와 PCLK가 같더라도 현재 baseline에는 실제 서로 다른 clock domain이 존재한다.

### 13.1 VGA VSync: pclk25 -> HCLK

VGA vertical sync는 3-register synchronization chain을 통해 HCLK으로 전달된다.

```text
vga_vsync_sig (pclk_25)
        |
        v
      vsync_d1
        |
        v
      vsync_d2
        |
        v
      vsync_d3
        |
        v
HCLK edge detection
```

이 edge detection 결과가 software-visible VSync flag를 set한다.

현재 VGA subsystem에서 가장 명확하게 구현된 explicit CDC synchronizer이다.

### 13.2 VRAM Data Path: HCLK <-> pclk25

Framebuffer memory는 read/write clock을 분리한다.

```text
write port : HCLK
read port  : pclk_25
```

CPU write domain과 VGA read domain 사이의 framebuffer data crossing은 vendor dual-port memory primitive가 구조적으로 처리한다.

### 13.3 Front-Buffer Select: HCLK -> pclk25 — Cleanup Required

`front_buffer_idx`는 HCLK domain에서 software SWAP request에 의해 변경된다.

동일 signal이 pclk25 쪽에서 직접:

- 어느 VRAM에 VGA read address를 연결할지
- 어느 VRAM output을 `vga_rdata`로 선택할지

를 제어한다.

현재 explicit synchronizer나 pclk25 handshake가 없다.

따라서 현재 board 동작과 별개로 CDC-safe buffer ownership transfer는 formally established 상태가 아니다.

Cleanup 시 frame boundary에서 commit되는 handshake/toggle 구조 등으로 수정해야 한다.

### 13.4 G-Sensor Sample Data: spi_clk -> PCLK — Cleanup Required

ADXL345 controller의 `out_acc_x/y/z`는 SPI clock domain에서 갱신된다.

APB wrapper는 이 multi-bit 값을 별도의 snapshot/handshake 없이 PCLK combinational read logic에서 직접 읽는다.

이론적으로 multi-bit incoherent sample이 발생할 수 있다.

향후 shadow register, handshake, toggle protocol 등 atomic sample-transfer mechanism으로 변경해야 한다.

### 13.5 ADC Response: adc_sys_clk -> PCLK — Cleanup Required

Qsys ADC response signal:

```text
adc_response_valid
adc_response_channel
adc_response_data
adc_response_startofpacket
adc_response_endofpacket
```

이 PCLK-domain `APB_ADC_Joystick_Controller`로 직접 연결된다.

현재 PCLK `always` block이 이 신호들을 일반 register처럼 sampling하며, user RTL에는 explicit synchronizer/async FIFO가 없다.

Qsys exported response가 실제로 PCLK synchronous라고 보장된다는 사실이 현재 project spec에서 입증되지 않았으므로 unresolved CDC boundary로 관리해야 한다.

### 13.6 Generated Domain Reset Release

`HRESETn`은 HCLK에 맞춰 생성되지만 `pclk_25`, `adc_sys_clk`, local generated clock으로 동작하는 logic에도 직접 사용된다.

여러 generated-domain register는 async reset assertion을 사용하지만 destination clock별 synchronized deassertion path가 명시적으로 존재하지 않는다.

따라서 현재 baseline은 아직 formal한 **asynchronous assert / synchronous deassert per-domain reset architecture**를 갖춘 상태가 아니다.

## 14. Future Clock-Domain Design Rule

향후 RTL에서는 두 clock이 같은 50 MHz reference에서 유도되었다는 이유만으로 unsynchronized crossing을 허용하지 않는다.

| Crossing type | 권장 mechanism |
|---|---|
| Single-bit level | 2+ FF synchronizer |
| Single-bit pulse | pulse stretch, toggle synchronizer, handshake |
| Multi-bit control/data | handshake + stable data, async FIFO, atomic snapshot |
| High-throughput stream | async FIFO / clock-converting interface |
| Dual-clock memory | 검증된 dual-port memory primitive/wrapper |
| Reset release | destination domain별 synchronized deassertion |

CDC exception은 반드시 문서화해야 하며 암묵적으로 허용하지 않는다.

## 15. Timing Constraints

다음 한 줄 설명은 Phase 3 `public_binding_05`의 클록 제약 업데이트 **이전 초기 재구성 baseline**을 기록한다.

```tcl
create_clock -name {clk} -period {20.0} [get_ports {clk}]
```

**현재** 공개 SDC에는 `derive_pll_clocks`와 `derive_clock_uncertainty`도 있다. 승인된 3B3 fit의 활성 클록은 `clk`, VGA 25 MHz, ADC 25/10 MHz이며 G-sensor 내부 SPI PLL 클록은 없다. 그렇더라도 CDC와 외부 I/O가 모두 닫혔다는 뜻은 아니다. 규범적인 합격·예외·증거 규칙은 [timing_constraints.ko.md](timing_constraints.ko.md)에 있다. 아래 과거 경고는 초기 재구성 이력으로, 동일 형태로 현재도 남아 있다는 주장이 아니다.

기존/migration timing evidence에서는:

- 적어도 ADC/VGA PLL path에 missing generated clock warning
- clock-transfer uncertainty warning `332168`, `332169`
- `derive_clock_uncertainty` 또는 uncertainty assignment 필요

가 기록되어 있다.

따라서 primary `clk` timing이 PASS했다고 해서 모든 generated domain이 정확하게 constrained되었다고 판단하면 안 된다.

## 16. Timing / CDC Verification Policy

향후 clock/reset architecture를 freeze하려면 다음 조건을 만족해야 한다.

1. 모든 active clock이 timing clock inventory에 존재
2. 모든 generated clock에 valid timing relation 또는 explicit asynchronous relation 존재
3. 모든 cross-domain path에 CDC mechanism 문서화
4. clock uncertainty 적절히 derive/assign
5. hardware CDC mechanism을 먼저 구현한 후에만 false path / async clock group 적용
6. 각 domain의 reset recovery/removal review
7. Quartus CDC/timing warning을 board PASS만으로 무시하지 않고 triage

## 17. Baseline Cleanup Targets Before Major Feature Integration

이 항목들은 나중에 project-wide `baseline_cleanup.md`로 통합한다.

### 17.1 Reset Architecture

1. **System reset assertion semantics 명확화/수정**
   - comment와 실제 `HRESETn` assertion timing 차이를 제거하거나 명확히 문서화
   - async assert/sync deassert architecture 여부를 확정

2. **Generated domain별 reset synchronizer 추가**
   - 최소 VGA, ADC, G-sensor domain audit
   - destination clock 기준 deassertion 안전성 확보

3. **PLL lock handling 검토**
   - VGA/ADC domain의 PLL lock-qualified reset release를 검토한다. 승인된 A6 cleanup에서는 active SPI PLL domain을 제거한다.

### 17.2 CDC Architecture

4. **VGA front-buffer ownership transfer 동기화**
   - `front_buffer_idx` 직접 crossing 제거
   - frame-safe handshake/synchronization scheme 적용

5. **G-sensor multi-bit sample transfer atomic화**
   - spi_clk sample을 PCLK에서 직접 읽는 구조 제거

6. **ADC response crossing audit/fix**
   - Qsys clock contract 확인
   - 필요 시 CDC bridge/FIFO/handshake 추가

7. **Asynchronous external input audit**
   - UART RX, LoRa AUX, G-sensor interrupt, button/switch 등 input synchronization policy 확정

### 17.3 Timing Constraints

8. **Generated-clock constraint 완성**
   - VGA, SPI, ADC clock이 TimeQuest에 정확히 표현되도록 정리

9. **Clock uncertainty 추가/derive**
   - `332168/332169` warning 해결

10. **CDC cleanup 후 asynchronous relationship 정의**
    - unsafe path를 false-path constraint로 숨기지 않음

11. **Repeatable clock/reset/CDC review report 추가**
    - clock inventory, unconstrained path, CDC assumption, reset-domain review를 build evidence에 포함

## 18. Baseline Clock / Reset Invariants

현재 baseline invariant:

1. CPU/AHB active operating clock은 direct 50 MHz board clock이다.
2. APB는 AHB와 동일한 50 MHz synchronous clock을 사용한다.
3. VGA pixel clock은 50 MHz에서 생성한 25 MHz이다.
4. G-sensor 내부 state는 50 MHz PCLK에서만 동작하고 registered 외부 2 MHz-class SPI clock을 구동하며, 내부 SPI generated-clock domain은 없다.
5. ADC/Qsys는 fitted 25 MHz `adc_sys_clk`와 10 MHz hard-IP clock을 생성하며, 이는 software-visible timing contract가 아닌 vendor-managed implementation clock이다.
6. `KEY[0]`가 active-low board reset source이다.
7. System reset release는 synchronization 이후 약 20 ms qualification을 거친다.
8. G-sensor는 추가로 약 20.97 ms local reset delay를 사용한다.
9. VGA VSync에는 explicit multi-flop HCLK synchronizer가 있다.
10. VGA buffer selection, G-sensor sample data, ADC response의 CDC correctness는 아직 완전히 입증되지 않았다.
11. P05C checkpoint에서 의도한 내부 clock은 모두 표현·제약되었지만 최종 P14 stability/exception 검토와 별도 STA-002 외부 I/O closure는 미완료다.
12. 향후 feature는 현재 CDC/timing gap을 보존해야 하는 architectural requirement로 취급해서는 안 된다.

## 19. 관련 Specification

- `soc_architecture.md` — system topology
- `cpu_interface.md` — CPU pipeline/bus timing
- `ahb_fabric.md` — HCLK-side interconnect
- `apb_subsystem.md` — PCLK/APB behavior
- `vga.md` — VGA/VRAM clock-domain behavior
- `gsensor.md`, `spi.md` — G-sensor local clocking
- `adc_joystick.md` — ADC interface
- future `baseline_cleanup.md` — consolidated cleanup checklist

## Phase 4A-2 승인된 clock/external-I/O 목표 (현행 RTL 아님)

A1 GPIO_IO[15:0] 외부 입력은 PCLK 2FF sync, reset 시 DIR=input/Hi-Z다. A6 G-sensor SPI는 50 MHz PCLK만 FSM state clock으로 사용하고 clock-enable tick 및 registered 외부 SCLK를 사용한다. 기존 dual-phase `spi_pll`은 cleanup 경로에서 비활성이나 현재 RTL/비공개 역사 IP는 변경하지 않는다. 비동기 `GSENSOR_INT`는 PCLK 동기화가 필요하며 SPI domain 제거만으로 atomic XYZ/VALID/SEQ/GS-001/CDC-002는 종료되지 않는다. STA-001은 내부/generated clock·CDC clock 구조, STA-002는 외부 포트 분류·근거 있는 delay 또는 N/A·전압/standard/drive/load·unconstrained port·ADXL345 peer timing·ADC/VGA 배치 warning 및 VGA 동작 중 ADC 측정을 담당한다. 비동기/정적/아날로그 pin에 임의의 synchronous delay를 만들지 않는다.

## Phase 4A-P05A 승인 Reset Policy — 구현 목표

User/Chat은 project reset policy로 필요한 곳의 asynchronous assertion과 각 project-owned destination clock domain의 synchronous deassertion을 승인했다. 구현은 `KEY[0]`의 약 20 ms release qualification을 보존하고 cold start를 deterministic하게 만들며, destination clock이 정지하면 clock이 재개될 때까지 해당 domain을 reset에 유지한다. 단순한 스타일 통일만을 위한 reset logic은 추가하지 않는다.

VGA는 Option A를 승인했다. Private `vga_pll`은 generated HDL을 직접 수정하지 않고 vendor flow로 재생성해 `locked`를 노출한다. System reset active 또는 lock low일 때 pixel reset을 assert하고, system reset release 및 lock high 이후 `pclk_25` domain synchronizer를 통해서만 deassert하며, lock loss에는 pixel reset을 다시 assert한다. Public model/interface와 private binding evidence는 재생성된 IP와 일치시켜야 한다.

ADC/Qsys 내부 reset controller는 문서화된 vendor-managed exception으로 유지한다. Qsys 밖의 project-owned ADC sequencer는 local `adc_sys_clk` synchronized reset release를 사용하고 local release 전에는 command-valid를 inactive로 유지한다. PCLK-only G-sensor reset/clock 구조는 변경하지 않는다. 이는 승인된 P05B target이며 현재 RTL이 이미 구현했다는 의미는 아니다. 구현과 검증은 아직 남아 있다.

## Phase 4A-P05B Reset / Clock Infrastructure — 현재 구현

P05B는 승인된 policy를 현재 public candidate에 구현했다. `system_reset_controller`는 `KEY[0]` low를 asynchronous assertion으로 전달하고, 기존 1,000,000-cycle qualification 후 HCLK edge에서만 reset을 해제한다. Reset/synchronizer/counter state에는 Quartus가 지원하는 명시적 LOW power-up condition이 있으므로 configuration 완료 시 버튼이 이미 해제되어 있어도 반드시 reset 상태에서 시작한다. Production 값은 50 MHz에서 약 20 ms이며, test는 sequencing rule을 바꾸지 않고 parameter 값만 줄인다.

`reset_release_sync`는 project-owned asynchronous-assert/synchronous-deassert primitive다. VGA reset request는 `HRESETn AND vga_pll_locked`이며 두 단계 `pclk_25` synchronizer를 거쳐 해제된다. PLL lock loss는 VGA timing, pixel address, VRAM read-side state의 reset을 즉시 다시 assert한다. Private Quartus 19.1 `vga_pll`은 c0의 25 MHz, divide-by-2, 50% duty, 0° phase를 유지하면서 `locked`만 추가하도록 vendor flow로 재생성했다. Generated private collateral은 public repository 밖에 유지하며 public model과 manifest는 동일한 `inclk0/c0/locked` contract를 갖는다.

Project-owned ADC command sequencer는 이제 `adc_sys_clk` local synchronized reset을 사용하고 release 전 `command_valid=0`을 유지한다. Generated Qsys reset 구현은 변경하지 않았다. G-sensor는 active internal SPI PLL domain 없이 PCLK-only 구조를 유지한다. SDC도 변경하지 않았다.

P05C fitted evidence는 system reset controller, VGA/ADC local reset synchronizer와 VGA `locked` interface가 fit에 유지되고, 의도한 내부 clock이 모두 constrained이며, G-sensor 내부 generated clock이 없고, setup/hold/recovery/removal이 양수이고 TNS가 0임을 확인했다. 따라서 `RST-001`, `RST-002`, `CDC-004`는 VERIFIED다. `STA-001`은 최종 P14 multicorner/stability/exception 검토를 위해 IN_PROGRESS를 유지한다. ADC response CDC(`CDC-003`), VGA buffer-ownership CDC(`CDC-001`), 외부 I/O/electrical closure(`STA-002`)는 별도다.
