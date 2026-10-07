# Baseline SoC Reset / Clock 명세

> **상태:** 현재 baseline reset/clock 계약. `RST-001`, `RST-002`는 accepted prerequisite이고 VGA ownership CDC `CDC-001`은 OPEN이며 상세 normative semantics는 `../08_vga.md`가 소유한다.
>
> **정본 언어:** 영어. 영문 `../06_reset_clock.md`가 정본이다.
>
> **상위 명세:** `soc_architecture.md`, `ahb_fabric.md`, `apb_subsystem.md`.

> **현행 G-sensor reset 계약:** 통합된 P09B 아키텍처는 단일 50 MHz PCLK와 직접 연결된 공통 PRESETn을 사용한다. 과거 로컬 reset_delay 인스턴스는 활성 wrapper 경로에서 제거되었으며 외부 SPI SCLK는 내부 클록 도메인이 아닌 registered 출력이다.

## 1. 목적

이 문서는 현재 FPGA baseline의 clock/reset architecture를 정의한다. 주요 범위는 다음과 같다.

- board reference clock과 active system clock
- APB clock/reset derivation
- VGA/ADC generated clock 및 G-sensor registered 외부 serial output
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
              |      +--> G-sensor controller (PCLK-only, 공통 PRESETn)
              |             +--> registered 외부 SCLK ~2 MHz
              |
              +--> VGA PLL
                     |
                     +--> pclk_25 = 25 MHz

KEY[0] (active-low)
      |
      v
system_reset_controller
  asynchronous assertion /
  2-FF HCLK release synchronization
      |
      v
~20 ms HCLK release qualification
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
| G-sensor controller | `PCLK` | 50 MHz | AHB-APB bridge | ADXL345/SPI control 및 XYZ register | APB와 동일 domain; registered 외부 SCLK는 내부 clock domain 아님 |
| ADC/Qsys | `adc_sys_clk` | 25 MHz | board `clk`에서 생성한 `adc_qsys`; 별도 10 MHz ADC hard-IP input | P11 ADC acquisition engine / vendor ADC subsystem | Generated domain; configured total ADC rate는 1 MSPS이며 effective project frame cadence는 별도 |

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

VGA PLL은 `CLOCK_50`에서 free-running으로 동작하며 이 계약은 새로운 PLL reset 입력이나 sequence를 요구하지 않는다. 현재 interface는 `vga_pll_locked`를 노출한다. Pixel-domain reset request는 다음 conjunction이다.

```text
HRESETn & vga_pll_locked
```

release는 `pclk_25` clock의 `reset_release_sync`를 통해서만 이루어진다. 따라서 system reset 또는 PLL lock loss는 VGA pixel reset을 assert하고, release는 system reset release + PLL lock high + destination-domain synchronous release를 요구한다. 이 P05 architecture는 **accepted prerequisite**(`RST-002`)이며 보존해야 한다.

PLL lock qualification 자체가 VGA ownership CDC closure를 의미하지 않는다. HCLK↔pixel request/commit/ACK/ownership protocol은 `CDC-001`로 계속 추적하며 normative transaction semantics는 `../08_vga.md`에서 정의한다.


## 7. G-Sensor SPI Clock

`APB_GSENSOR_MB`와 `spi_ee_config`는 50 MHz `PCLK`만 사용한다. Controller는 12/13-PCLK half-period의 registered 외부 mode-3 SCLK를 구동한다. 과거 2-output `spi_pll`은 현행 G-sensor instance나 Quartus binding에 없다. G-sensor controller는 공통 `PRESETn`에 직접 연결되며, 과거 로컬 `reset_delay`는 P09B에서 비활성이다.

## 8. ADC / Qsys Clock and Reset Domain — P11 Target (In-progress)

P11A에서 확인한 generated instance clock은 다음과 같다.

```text
board clk                     = 50 MHz
adc_sys_clk                   = 25 MHz
ADC hard-IP input clock       = 10 MHz
configured ADC total rate     = 1 MSPS
```

`adc_qsys`는 vendor-managed subsystem이며 다음 연결을 유지한다.

```text
clk_clk                      <- board clk
clock_bridge_sys_out_clk_clk -> adc_sys_clk
reset_reset_n                <- HRESETn
```

Generated Qsys implementation은 내부 PLL-lock/reset-controller infrastructure를 사용한다. 현재 generated interface는 PLL `locked`를 project-local top RTL로 export하지 않으며 generated HDL을 hand-edit해서 만들면 안 된다.

Project-owned P11 acquisition logic은 `adc_sys_clk`에서 동작하며 qualified `HRESETn`으로부터 `reset_release_sync(adc_sys_clk)`가 생성한 project-local `adc_reset_n`을 사용한다. Primitive의 reset assertion은 비동기이고 deassertion은 `adc_sys_clk`에 동기된다.

HCLK/PCLK는 추가 local release synchronizer가 필요 없다. `HRESETn`은 이미 HCLK에서 qualify/release되며 `PCLK=HCLK`다.

P11 command/response cadence, vendor lock-loss recovery, exact accepted-command-to-response timing의 verification은 **(In-progress)**이며 25/10 MHz clock이나 configured 1 MSPS rate만으로 추론하면 안 된다.

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

1. external button low의 asynchronous assertion / button level의 HCLK 2-FF release synchronization
2. 약 20 ms 동안 high가 유지된 뒤 HCLK에서 system reset release

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

### 10.3 System Reset Assertion Contract

`KEY[0]` low는 `system_reset_controller`를 통해 distributed `HRESETn`을 비동기적으로 assert하며 HCLK edge를 기다리지 않는다. Reset release는 HCLK에서 synchronize/qualify되고 기존 1,000,000-cycle(50 MHz에서 약 20 ms) high-level release qualification 및 synchronizer/edge-alignment latency 이후에만 이루어진다.

이는 accepted P05 `RST-001` / `RST-002` semantics를 보존한다. 과거 next-HCLK-edge assertion 설명은 대체되었으며 현재 계약이 아니다.

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
| G-sensor controller / banks | `PRESETn` 직접 연결 (APB bridge와 공유) |

현재 top에서 `LEDR[9] = ~HRESETn`으로 연결되어 reset 상태를 시각적으로 확인할 수 있다.

## 12. G-Sensor Reset Architecture

통합된 P09B 아키텍처에서 G-sensor controller(`spi_ee_config`), LIVE/HOLD bank, 획득 scheduler, IRQ synchronizer/history 및 30 ms watchdog은 공통 `PRESETn`에 직접 연결된다.

로컬 `reset_delay` 인스턴스와 wrapper `RESET_DELAY_BITS` 파라미터는 활성 P09B wrapper 경로에서 제거되었다.

Reset assertion은 미완료 APB 또는 SPI 작업을 비동기적으로 중단할 수 있다. Reset release는 기존 시스템 리셋 검증(HCLK 2단 동기화 및 1,000,000 PCLK 사이클, 약 20 ms)을 따른다. 동기 리셋 release 이후 controller는 즉시 12개의 순차 ADXL345 초기화 쓰기를 시작한다.

### 12.1 역사적 G-Sensor 로컬 Reset Delay

과거 A6 베이스라인은 system reset release 이후 `reset_delay.v`를 사용해 추가적인 로컬 지연을 가졌다. 20-bit counter를 통해 2^20 / 50 MHz ≈ 20.97152 ms 동안 G-sensor controller를 리셋 상태로 유지했다(버튼 release 후 총 약 41 ms 지연). `reset_delay.v` 소스 파일은 출처 보존을 위해 유지되지만, 그 인스턴스는 현재 P09B 베이스라인에서 비활성이다.

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

### 13.3 VGA Ownership Protocol: HCLK <-> pclk25 — `CDC-001` OPEN

현재 VGA ownership interface는 과거의 direct HCLK `front_buffer_idx` selector가 아니다. Logical protocol은 다음과 같다.

```text
HCLK                                  pclk_25
accepted SWAP-bearing operation
  -> swap-request epoch 1회 publish
        -- synchronized event ------> pending swap
                                      |
                                      +-- (799,524)->(0,0)에서만
                                      |   front ownership commit
                                      v
        <------ post-commit ACK ------+
synchronized ACK consume
  -> HCLK ownership view update
```

pixel-domain display owner와 HCLK writable-owner view는 pixel commit 이후 ACK synchronization 전까지 일시적으로 다를 수 있다. 이 구간에는 one-outstanding-operation rule이 framebuffer write를 차단한다. clear-only는 pixel ownership request가 필요 없고, combined SWAP+CLEAR는 swap commit/ACK를 먼저 수행한 뒤 결과 new back bank를 clear한다.

logical swap request는 event semantics다. request를 encode/qualify하는 구체적인 internal bit는 implementation detail이며 normative multi-bit payload contract를 만들지 않는다. 해당 signal의 stability와 synchronizer topology는 이후 structural/static CDC review 대상이다.

Reset 또는 PLL lock loss는 새 ownership epoch를 시작한다. Recovery는 ownership과 request/ACK observation state를 rebase하고 stale pre-recovery event를 억제하며 새 pixel epoch 확립 전까지 `DOMAIN_READY=0`을 유지하고 이후 next valid transaction의 progress를 보장해야 한다. Full system reset은 VGA status를 clear하며, system reset이 유지된 상태의 PLL lock loss는 `../08_vga.md`에 정의한 software-visible `OP_ABORT` semantics를 따른다.

이 section은 **behavioral architecture**를 freeze할 뿐이다. `CDC-001`은 independent async/reset behavioral verification과 별도 structural CDC review가 accepted되기 전까지 OPEN이다. Positive STA는 이 protocol correctness 증명이 아니다.


### 13.4 G-Sensor Sample Data: 단일 PCLK 도메인 및 코히어런트 스냅샷

과거 multi-bit `spi_clk -> PCLK` CDC는 A6의 PCLK 단일화로 제거되었다. P09B 아키텍처는 원자적 CAPTURE/RELEASE, VALID 게이팅 및 SEQ 추적을 갖춘 코히어런트 LIVE 및 HOLD 샘플 bank를 도입하여 분리된 APB 읽기 간 소프트웨어 가시 torn sample 읽기를 해소했다.

따라서 SPI controller와 CPU 인터페이스 사이에 활성 내부 CDC 위험은 존재하지 않는다. `CDC-002`가 `IN_PROGRESS`를 유지하는 것은 보수적인 엔지니어링 종결 기준(완전한 리셋-negative 커버리지 및 물리 검증 등)에 따른 것이며, RTL에 활성 비안전 클록 크로싱이 남아있기 때문이 아니다.

### 13.5 ADC Scan Frame: adc_sys_clk -> PCLK — P11 Target (In-progress)

과거 Qsys response를 PCLK로 직접 sampling하는 구조는 P11 target contract가 아니다.

완성된 ADC scan frame은 stable bundled-data request/acknowledge toggle mailbox를 통해 crossing해야 한다.

```text
adc_sys_clk source:
  complete frame -> stable payload -> REQ toggle -> hold until ACK

PCLK destination:
  synchronize REQ -> atomically capture whole frame into LIVE -> return ACK
```

Source는 ACK까지 complete-frame payload를 stable하게 유지하고 mailbox busy 동안 payload를 overwrite하거나 다음 completed frame을 publish하면 안 된다. Acquisition engine은 ACK까지 frame boundary에서 pause할 수 있다. 따라서 P11 baseline은 maximum-throughput stream이 아니라 coherent/lossless-at-publication latest-state channel이다.

Handshake round trip 동안 여러 frame을 누적해야 하거나, acquisition이 pause할 수 없거나, 모든 high-rate frame을 보존해야 하거나, acquisition 지속 중 destination stall이 길어질 수 있거나, future DMA/SDRAM streaming이 도입되면 async FIFO가 필요하다.

P11 이후 live Qsys response bus field를 APB에 직접 노출하면 안 된다. P11 frame CDC implementation/verification과 vendor lock-loss/protocol verification은 **(In-progress)**이며 이 target 설명은 완료나 closure 선언이 아니다.

### 13.6 Reset Release Into Generated Domains

Reset architecture는 **central reset policy**와 **destination-domain release synchronization**을 구분한다.

```text
KEY[0] -> system_reset_controller -> HRESETn
  +-> HCLK/PCLK logic directly
  +-> (HRESETn & vga_pll_locked)
  |      -> reset_release_sync(pclk_25) -> vga_reset_n
  +-> reset_release_sync(adc_sys_clk)
  |      -> adc_reset_n for project-owned ADC logic
  +-> adc_qsys reset port
         -> vendor-managed internal reset/lock behavior
```

HCLK/PCLK는 이미 HCLK에서 release-qualified이며 `PCLK=HCLK`이므로 불필요한 두 번째 synchronizer를 추가하지 않는다. 독립적으로 생성된 모든 project-owned domain은 destination clock에 맞춰 reset을 deassert해야 한다. VGA PLL은 `CLOCK_50`에서 free-running이며 새로운 PLL reset requirement를 추가하지 않는다.

ADC/Qsys 내부 reset/PLL-lock behavior는 문서화된 vendor boundary이고 project-local acquisition logic은 `adc_reset_n`을 사용한다. Full generated-domain closure 주장 전에 P11 verification은 partial assembly/mailbox activity 중 reset과 가능한 vendor lock/reset recovery를 exercise해야 한다.

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

## 17. VGA CDC 관련 Current Cleanup Coordination

Project-wide status owner는 `../baseline_cleanup.md`이며 이 명세는 전체 cleanup checklist를 중복하지 않는다. VGA CDC/reset boundary의 현재 상태는 다음과 같다.

| Item | Current status | Contract role |
|---|---|---|
| `RST-001` | VERIFIED | accepted system-reset prerequisite. async assertion / qualified HCLK release behavior 보존 |
| `RST-002` | VERIFIED | accepted generated-domain reset/PLL-lock prerequisite. `vga_pll_locked` qualification과 pclk_25 synchronized release 보존 |
| `CDC-001` | OPEN | Section 6/13 및 `../08_vga.md`의 VGA request/commit/ACK/ownership/recovery protocol을 freeze하고 later gate에서 증명 |
| `VER-003` | OPEN | 이후 independent async-clock/reset behavioral verification. 이번 SPEC stage에서는 수행하지 않음 |
| `STA-001` | IN_PROGRESS | 별도 timing/exception/recovery-removal review. timing PASS에서 CDC correctness를 추론하지 않음 |

과거 broad cleanup target list는 historical coordination material이며 current status와 required outcome은 `../baseline_cleanup.md`가 소유한다.


## 18. Baseline Clock / Reset Invariants

현재 baseline invariant:

1. CPU/AHB active operating clock은 direct 50 MHz board clock이다.
2. APB는 AHB와 동일한 50 MHz synchronous clock을 사용한다.
3. VGA pixel clock은 50 MHz에서 생성한 25 MHz이다.
4. G-sensor 내부 state는 50 MHz PCLK에서만 동작하고 registered 외부 2 MHz-class SPI clock을 구동하며, 내부 SPI generated-clock domain은 없다.
5. ADC/Qsys는 fitted 25 MHz `adc_sys_clk`와 10 MHz hard-IP clock을 생성하며, 이는 software-visible timing contract가 아닌 vendor-managed implementation clock이다.
6. `KEY[0]`가 active-low board reset source이다.
7. `KEY[0]` low는 `system_reset_controller`를 통해 system reset을 비동기 assert하며 release는 HCLK synchronization 및 약 20 ms qualification을 거친다.
8. G-sensor 초기화는 공통 PRESETn을 직접 사용하며, 과거 약 20.97 ms 로컬 리셋 지연은 P09B에서 비활성이다.
9. VGA VSync에는 explicit multi-flop HCLK synchronizer가 있다.
10. VGA ownership은 위 request/commit/ACK architecture를 사용하지만 `CDC-001`은 이후 independent behavioral/structural CDC acceptance 전까지 OPEN이다. 과거 direct-selector architecture는 current가 아니다. 과거 direct ADC response crossing은 frozen P11 scan-frame mailbox target architecture로 대체되며 그 implementation/verification은 **(In-progress)**다. G-sensor 내부 SPI-to-PCLK crossing은 제거되었고 cross-read XYZ/VALID/SEQ 코히어런시는 P09B LIVE/HOLD 스냅샷으로 해결되었다.
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

## Appendix A. Historical / Milestone Notes

아래 내용은 milestone history와 accepted prerequisite provenance를 보존한다. 과거 target 문장이 Section 1–19와 충돌하면 Section 1–19의 current active contract가 우선한다.

### A.1 Phase 4A-2 승인된 clock/external-I/O 목표 — Historical Status

A1 GPIO_IO[15:0] 외부 입력은 PCLK 2FF sync, reset 시 DIR=input/Hi-Z다. A6 G-sensor SPI는 50 MHz PCLK만 FSM state clock으로 사용하고 clock-enable tick 및 registered 외부 SCLK를 사용한다. 기존 dual-phase `spi_pll`은 cleanup 경로에서 비활성이나 현재 RTL/비공개 역사 IP는 변경하지 않는다. 비동기 `GSENSOR_INT`는 PCLK 동기화가 필요하며, P09B는 LIVE/HOLD 스냅샷을 통해 소프트웨어 가시 VALID/SEQ 및 원자적 접근을 해결한다; `GS-001`/`CDC-002`는 잔여 공학 종결 증거를 위해 IN_PROGRESS를 유지한다. STA-001은 내부/generated clock·CDC clock 구조, STA-002는 외부 포트 분류·근거 있는 delay 또는 N/A·전압/standard/drive/load·unconstrained port·ADXL345 peer timing·ADC/VGA 배치 warning 및 VGA 동작 중 ADC 측정을 담당한다. 비동기/정적/아날로그 pin에 임의의 synchronous delay를 만들지 않는다.

### A.2 Phase 4A-P05A 승인 Reset Policy — Historical Target

User/Chat은 project reset policy로 필요한 곳의 asynchronous assertion과 각 project-owned destination clock domain의 synchronous deassertion을 승인했다. 구현은 `KEY[0]`의 약 20 ms release qualification을 보존하고 cold start를 deterministic하게 만들며, destination clock이 정지하면 clock이 재개될 때까지 해당 domain을 reset에 유지한다. 단순한 스타일 통일만을 위한 reset logic은 추가하지 않는다.

VGA는 Option A를 승인했다. Private `vga_pll`은 generated HDL을 직접 수정하지 않고 vendor flow로 재생성해 `locked`를 노출한다. System reset active 또는 lock low일 때 pixel reset을 assert하고, system reset release 및 lock high 이후 `pclk_25` domain synchronizer를 통해서만 deassert하며, lock loss에는 pixel reset을 다시 assert한다. Public model/interface와 private binding evidence는 재생성된 IP와 일치시켜야 한다.

ADC/Qsys 내부 reset controller는 문서화된 vendor-managed exception으로 유지한다. Qsys 밖의 project-owned ADC sequencer는 local `adc_sys_clk` synchronized reset release를 사용하고 local release 전에는 command-valid를 inactive로 유지한다. PCLK-only G-sensor reset/clock 구조는 변경하지 않는다. 과거 P05A 시점에는 승인된 P05B target으로 implementation/verification이 pending이었다. Accepted P05 prerequisite 결과는 A.3에 기록한다.

### A.3 Phase 4A-P05B Reset / Clock Infrastructure — Accepted Prerequisite History

P05B는 승인된 policy를 현재 public candidate에 구현했다. `system_reset_controller`는 `KEY[0]` low를 asynchronous assertion으로 전달하고, 기존 1,000,000-cycle qualification 후 HCLK edge에서만 reset을 해제한다. Reset/synchronizer/counter state에는 Quartus가 지원하는 명시적 LOW power-up condition이 있으므로 configuration 완료 시 버튼이 이미 해제되어 있어도 반드시 reset 상태에서 시작한다. Production 값은 50 MHz에서 약 20 ms이며, test는 sequencing rule을 바꾸지 않고 parameter 값만 줄인다.

`reset_release_sync`는 project-owned asynchronous-assert/synchronous-deassert primitive다. VGA reset request는 `HRESETn AND vga_pll_locked`이며 두 단계 `pclk_25` synchronizer를 거쳐 해제된다. PLL lock loss는 VGA timing, pixel address, VRAM read-side state의 reset을 즉시 다시 assert한다. Private Quartus 19.1 `vga_pll`은 c0의 25 MHz, divide-by-2, 50% duty, 0° phase를 유지하면서 `locked`만 추가하도록 vendor flow로 재생성했다. Generated private collateral은 public repository 밖에 유지하며 public model과 manifest는 동일한 `inclk0/c0/locked` contract를 갖는다.

Project-owned ADC command sequencer는 이제 `adc_sys_clk` local synchronized reset을 사용하고 release 전 `command_valid=0`을 유지한다. Generated Qsys reset 구현은 변경하지 않았다. G-sensor는 active internal SPI PLL domain 없이 PCLK-only 구조를 유지한다. SDC도 변경하지 않았다.

P05C fitted evidence는 system reset controller, VGA/ADC local reset synchronizer와 VGA `locked` interface가 fit에 유지되고, 의도한 내부 clock이 모두 constrained이며, G-sensor 내부 generated clock이 없고, setup/hold/recovery/removal이 양수이고 TNS가 0임을 확인했다. 따라서 `RST-001`, `RST-002`, `CDC-004`는 VERIFIED다. `STA-001`은 최종 P14 multicorner/stability/exception 검토를 위해 IN_PROGRESS를 유지한다. ADC response CDC(`CDC-003`), VGA buffer-ownership CDC(`CDC-001`), 외부 I/O/electrical closure(`STA-002`)는 별도다.

### A.4 P09B G-Sensor Clock / Reset 통합 노트

통합된 P09B 구현은 registered mode-3 외부 SCLK와 함께 단일 50 MHz PCLK 도메인에서 완전히 동작한다. `spi_ee_config.iRSTN`을 `PRESETn`에 직접 연결하여 활성 로컬 `reset_delay` 인스턴스 없이 시스템 리셋 검증을 공유한다. LIVE/HOLD bank, IRQ 동기화/이력, pending scheduler 상태 및 30 ms watchdog도 모두 동일한 `PRESETn`을 공유한다.

Reset assertion은 비동기적이며 진행 중인 SPI 트랜잭션이나 APB 전송을 중단한다. Reset release는 시스템 리셋 검증(~20 ms)을 통해 PCLK에 동기화된다. Reset은 LIVE 및 HOLD bank, SEQ, VALID 및 pending scheduler 상태를 모두 클리어한다. 외부 ADXL345 보드 타이밍 및 전기적 특성 분석은 `STA-002` / `SPI-002`에서 계속 추적된다.

### A.5 P11 ADC Reset / CDC Freeze Note

P11 ADC target은 P05 reset architecture를 대체하지 않고 보존한다. `system_reset_controller`는 external reset conditioning과 약 20 ms HCLK release qualification을 계속 소유하고 `reset_release_sync`는 reusable destination-domain primitive다.

현재 확인된 `adc_sys_clk=25 MHz`, ADC hard-IP input `10 MHz`, configured total ADC rate `1 MSPS`는 Section 3/8의 clock fact이며 P11 frame cadence나 CDC closure 증명이 아니다.

P11은 `adc_sys_clk` deassertion을 하나의 multi-clock `system_reset_controller`에 합치지 않는다. Central policy는 centralized, destination synchronizer는 distributed로 유지한다. Project-local ADC logic은 `adc_reset_n`을 사용하고 Qsys internal reset/PLL-lock behavior는 vendor-managed로 유지한다. PLL `locked`를 project top에 새로 export하거나 generated HDL을 hand-edit하지 않는다.

P11 target은 historical direct response sampling 대신 stable bundled-data req/ack mailbox로 complete frame을 `adc_sys_clk -> PCLK`에 전달한다. Source는 ACK까지 payload를 stable하게 유지하고 busy 동안 overwrite/다음 completed frame publication을 하지 않으며 destination은 request를 synchronize해 frame 전체를 atomically capture한다.

P11 status:

- global HCLK/PCLK reset policy: P05 범위에서 이미 implemented/verified;
- project-local ADC reset synchronizer: 기존 infrastructure 보존;
- ADC response/frame CDC replacement: **(In-progress)**;
- Qsys lock-loss/vendor protocol behavior under P11: **(In-progress)**;
- external ADC/VGA electrical/placement closure: 별도 `STA-002` 범위.
