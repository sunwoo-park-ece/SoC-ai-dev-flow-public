# SoC Health Firmware 계약 및 정합성 트래커

> **상태:** S1/S2 계약 보존; S3 Timer/UART/G-sensor/ADC/joystick/VGA provider 구현, 로컬 host 시험, 실제 peripheral RTL 통합 및 RV32I build 완료. S4-A board I/O provider와 HEX raw getter는 host/RTL 검증을 포함해 구현했다. S4-B 공통 formatter 및 실제 VGA/UART1 TX observer도 구현·로컬 검증했으며 실제 board, timing 또는 Clean Baseline 합격 근거가 아니다.
> **언어:** [영어 문서](../22_soc_health_firmware.md)가 정본이며 이 한국어 companion은 같은 계약을 반영한다.
> **역할:** Role A는 독립 health firmware를 정의한다. Role B는 개별 IP 명세를 대체하지 않고 baseline-cleanup spec/FW 정합성 부채를 모은다.
> **소스 기준:** `390db6da2dcc8bbfa1c93b444525b0ba1e852056`. Trace ID: Issue #7 S0 결과 `5845036298`, S0 승인 `5845199371`, S1 명령 `5845199693`. 내부 governance locator이며 공개 runtime evidence가 아니다.

## 1. 상태, 목적 및 역사적 역할 분리

`firmware/apps/final_main.c`는 **HISTORICAL RC-CAR SYSTEM DEMO FIRMWARE**다. 출처 보존과 데모 재현을 위해 유지하며 외부 STM32 기반 RC-car 시스템에 의존한다. 정식 독립 SoC 통합 시험 펌웨어가 아니다. Issue #7 완료 및 리뷰 이후 Issue #6 C4-A/C4-B의 기반으로 사용하지 않는다.

소유자가 제공한 데모: [FPGA SoC + STM32 RC-car demo](https://www.youtube.com/shorts/XYbi3uSHmUU). 출처를 설명하는 링크이며 미래 health monitor를 독립적으로 검증한 근거가 아니다.

미래 정식 애플리케이션은 `firmware/apps/soc_health_main.c`다. 외부 RC-car 시스템 없이 독립 실행하며 production peripheral 계약을 사용하고, 진행과 실패를 보고하며 VGA와 PC UART 관찰자에 전달할 하나의 snapshot을 동결한다. ADC 전용 시험이 아닌 재사용 가능한 시스템 진단 자산이다.

S1은 문서만 변경한다. 애플리케이션, service, provider, scheduler 및 HEX raw getter는 S1 구현 산출물이 아니다. S2는 §10.1 기반 구조를 추가했고 S3는 §10.2 strong/functional provider만 추가한다. S3 승인 후 S4-A를 진행했으며 S4-A 승인 후 S4-B를 진행했으며 S5 이전 S4-B 소유자 리뷰가 필요하다. 또한 Issue #6 C4는 중단 상태를 유지한다. 레지스터, hardware 동작 및 기존 합격 범위의 권위는 owning IP spec에 있다. 기존 STOP gate를 보존한다. 이 문서는 P08B 재개, IRQ/PLIC 추가, ADC/peripheral RTL 재설계, pin 변경 또는 전역 cleanup/STA/board 종결을 승인하지 않는다.

## 2. Health 모델 및 실패 이력

### 2.1 현재 상태 및 evidence class

| 현재 상태 | 의미 |
|---|---|
| `UNKNOWN` | 적격 관측이 아직 없으며 낙관적으로 PASS 처리하지 않는다. |
| `PASS` | 명시한 evidence class와 provider 기준이 충족되었다. |
| `WARN` | 저하 또는 진행 중인 조건을 명시적으로 보고한다. 필수 deadline miss를 대체하지 않는다. |
| `FAIL` | 불일치, 필수 deadline miss 또는 판정에 해당하는 오류다. |
| `EXCLUDED` | 의도적으로 판정 범위에서 제외하며 PASS/FAIL에 기여하지 않는다. |

Evidence class는 `STRONG_PROGRESS`, `PHYSICAL_LOOPBACK`, `FUNCTIONAL_CONSISTENCY`, `REGISTER_READBACK`, `INPUT_OBSERVATION`, `VISIBLE_OUTPUT`, `OBSERVER_ONLY`, `EXCLUDED`다. 한 IP에 여러 근거가 있으면 별도로 표시한다. 레지스터 readback이나 눈에 보이는 출력 근거를 acquisition/display-domain 진행으로 승격하지 않는다.

### 2.2 현재 실패와 sticky 실패의 구분

각 record는 현재 상태, evidence class, `heartbeat_count`, `last_progress_epoch`, `miss_count`, `detail`/status를 포함한다. Snapshot에는 현재 `pass_mask`, `warn_mask`, `fail_mask`, `excluded_mask`와 별도의 `sticky_fail_mask`를 포함한다. UNKNOWN은 PASS에 암묵적으로 넣지 않고 명시하며 mask는 record 상태와 일치해야 한다.

현재 `FAIL`은 새 적격 근거에 따라 `PASS`로 복구될 수 있다. 그러나 `sticky_fail_mask`는 reboot 또는 별도로 승인된 미래 clear 기능까지 현재 boot session 동안 유지된다. 복구가 miss나 실패 이력을 지워서는 안 된다. 하나의 state field로 현재 상태와 과거 실패를 동시에 표현하지 않는다. 필수 deadline miss마다 해당 miss 이력을 증가시키고 FAIL로 판정한다. 같은 진행 중 transaction을 반복 polling한 것만으로 heartbeat를 여러 번 생성하지 않는다.

`AES_GCM = EXCLUDED_PENDING_CLEANUP`: AES는 sticky 실패 판정을 포함하여 PASS와 FAIL 어느 쪽에도 기여하지 않는다. Monitor에서 AES operation을 실행하지 않는다. AES cleanup 및 미래 heartbeat provider 추가에는 별도 승인이 필요하며 AES 부재는 시스템 실패가 아니다.

## 3. 불변 snapshot 및 관찰자

Health manager는 상태를 한 번 계산하고 epoch, 결정적인 signature, 현재 mask, sticky 이력, IP별 상태/evidence/progress 및 보드 시험 값을 담은 snapshot N을 동결한다. VGA와 PC UART는 동일 snapshot object/content를 받아 같은 epoch와 signature, mask, IP별 상태 및 선택한 progress counter를 표시한다. 각 관찰자가 health를 따로 재계산하지 않는다.

Signature는 초기화되지 않은 struct padding이 아닌 명시적 field로 결정적으로 계산한다. 관찰자가 소비하는 동안 N은 불변이다. Live provider 상태와 이후 N+1을 분리한다. 관찰자 지연/실패로 N을 변경하지 않으며 유한한 cursor와 저장소 소유권으로 진행 중 snapshot의 재사용을 막는다. 관찰자 staleness 및 마지막 완료 epoch를 별도로 보고한다. VGA 완료는 이미 렌더링한 N이 아닌 N+1을 위한 live 상태에 반영한다.

UART1 TX는 `OBSERVER_ONLY`이며 UART heartbeat에 기여하지 않는다. 실패/정체된 관찰자가 다른 provider나 snapshot service를 무한히 막아서는 안 된다. 동일 signature는 일관성 보조 수단이며 peripheral 정확성이나 물리 출력의 증명이 아니다.

## 4. 협력형 service 및 fault 경계

정상 probe와 observer는 모두 bounded 또는 nonblocking이어야 한다. 매 turn의 작업량이 유한하고 독립 service-epoch deadline과 명시적 오류 결과를 갖는 협력형 polling loop를 사용한다. Monitor 진행/보고를 허용하는 유일한 수단으로 Timer를 사용하지 않는다. Timer 실패도 보고할 수 있어야 한다. Service-epoch budget은 검증된 wall-clock 시간이 아니며 실제 quota와 timing은 S3/S5에서 측정한다.

Production bounded/status API를 사용하며 정상 경로에서 `timer_wait_ready()`를 호출하지 않는다. UART drain, renderer 문자열, 초기화 acknowledgement 및 operation wait에도 유한한 작업량/deadline이 필요하다. CPU/bus의 terminal fault가 아닌 한 하나의 IP 실패가 다른 IP service를 막지 않는다. 긴 VGA frame wait 대신 low-level status/operation API를 조합한다.

MMIO는 정식 주소의 정렬된 32-bit access만 사용한다. VGA status 사전 확인은 이후 store에서 발생하는 lock-loss race를 제거하지 못한다. [VGA 계약](../08_vga.md)에 따라 거부된 framebuffer/control store는 기존 terminal CPU trap으로 진입할 수 있다. 복구 가능한 MMIO/trap 재설계를 약속하지 않으며 멈춘 bus instruction을 software polling budget으로 제한할 수 없다. 승인된 diagnostic fail-stop과 pre-mtvec risk 경계를 유지한다.

## 5. IP별 heartbeat 계약

| 대상 | Production API / 권위 | 필수 근거 |
|---|---|---|
| CPU/system service | 미래 service loop; [CPU](../21_cpu_core.md), [firmware](../19_firmware_contract.md) | Service epoch와 snapshot publication이 진행한다. 시스템 liveness이며 독립 CPU hardware 합격이 아니다. |
| Timer | `timer_start/count/status/clear_ready`; [Timer](../10_timer.md) §21 | `STRONG_PROGRESS`: active 중 COUNT 진행, 새 READY, acknowledgement 및 새 START/restart. Exact-N one-shot을 사용하며 W1C만으로 재시작하지 않는다. |
| UART | `uart0_putc_timeout`, `uart1_getc_nonblock`, RX error API; [UART](../09_uart.md) 현행 P07B | `PHYSICAL_LOOPBACK`: RX1에서 deadline 안에 정확한 기대 token 수신. §6의 topology/제외 범위를 따른다. |
| GPIO | `gpio_set_input/output`, `gpio_write/read/read_output`; [GPIO](../11_gpio.md) active P04 | `PHYSICAL_LOOPBACK`: settling 이후 synchronized GPIO1이 독립 생성 GPIO0 pattern과 일치한다. §7. |
| G-sensor | `gsensor_read_sample()`; [G-sensor](../12_gsensor.md) §§7–9 | `STRONG_PROGRESS`: 성공한 coherent sample 및 sequence 진행. 정적인 XYZ도 허용한다. NO_NEW/BUSY는 heartbeat를 증가시키지 않으며 계속 진행이 없으면 deadline에서 실패한다. CAPTURE/read/RELEASE는 단일 소유자다. |
| ADC | `adc_init/enable/capture/get_frame_count/get_error_status`; [ADC](../15_adc_joystick.md) §§8–11 | `STRONG_PROGRESS`: 정식 v2 identity, bounded enable acknowledgement, 새 coherent HOLD, CH1/CH2 valid, HOLD seq 진행 및 일관된 FRAME_COUNT 진행. Sticky acquisition error를 기록한다. |
| Joystick policy | `joystick_policy_eval`, `adc_get_raw_joy_status/get_calibration`; [ADC policy](../15_adc_joystick.md) §§10–11 | `FUNCTIONAL_CONSISTENCY`: HW ADC_JOY_STATUS가 동일 raw HOLD와 현재 calibration의 독립 FW 평가와 일치한다. Validity 및 saturated strict threshold를 포함하며 매 epoch 물리 움직임을 요구하지 않는다. |
| VGA | `vram_status/clear_events/start_operation`, bounded text write; [VGA](../08_vga.md) | `STRONG_PROGRESS`: DOMAIN_READY, 새/반복 VSYNC, 발행한 SWAP, 그 operation에 연결된 새 OP_DONE, OP_ABORT 없음. §9. |
| SW | `sw_read()`; [SW](../17_sw.md) P04 | `INPUT_OBSERVATION` 및 보드 제어: synchronized SW[9:0], 선택적 activity count. 정적 SW도 유효하다. |
| LED | `led_write/read`; [LED](../18_led.md) | `REGISTER_READBACK`와 별도 관찰 `VISIBLE_OUTPUT`: LED[9:0] = 캡처한 SW[9:0]. |
| HEX | `hex_display_*`; [HEX](../16_hex_display.md) | `REGISTER_READBACK`와 별도 관찰 `VISIBLE_OUTPUT`: §8의 정확한 dual-mode 계약. |
| PC UART TX | UART1 bounded TX API | `OBSERVER_ONLY`: 동결 snapshot을 표시하며 UART loopback을 판정하지 않는다. |
| AES-GCM | [AES](../14_aes_gcm.md) | `EXCLUDED`: 항상 EXCLUDED_PENDING_CLEANUP, monitor operation 없음. |

ADC FRAME_COUNT는 CAPTURE 호출이 아닌 PCLK LIVE publication을 센다. Producer가 loop보다 빠를 수 있으므로 capture 사이 정확히 +1을 요구하지 않는다. Coherent HOLD sequence와 주변 count 관측을 modulo-32 wrap 및 acquisition baseline에 따라 비교하며 독립 register를 동시에 읽었다고 주장하지 않는다. `(valid_mask & 0x03) == 0x03`을 요구한다. Sticky acquisition error는 명시적 acknowledgement 전에 기록하며 실패를 조용히 지우지 않는다. ADC는 RELEASE 없는 CAPTURE-only HOLD다. G-sensor의 별도 RELEASE lifecycle은 유지한다.

다음 CAPTURE/calibration 변경 전에 단일 소유자의 안정된 calibration readback으로 joystick policy를 비교한다. 기대 방향은 HW JOY_STATUS가 아닌 raw/validity와 pure FW model에서 계산한다. Init/enable 오류를 버리거나 stale HOLD를 반환하는 compatibility joystick wrapper는 health progress 근거가 될 수 없다.

## 6. UART 물리 loopback 및 관찰자 배선

동결한 자동 경로는 **UART0 / LoRa-side TX → physical jumper → UART1 / PC-side RX**다.

```text
PCLK = 50 MHz
divisor = 434 on both UARTs
format = 8-N-1
nominal terminal rate = 115200
UART0 TX: YES     UART1 RX: YES
UART1 TX: NO      UART0 RX: NO
LoRa AUX: NO      external LoRa module: NO
```

명목 hardware baud는 50,000,000/434로 약 115207.37 bit/s다. Raw UART API를 사용하며 AUX를 확인하는 LoRa module wrapper를 요구하지 않는다. 기존 pin을 보존한다. `fpga/quartus/constraints/de10_lite_pins.tcl` 기준 UART0 `lora_tx`는 Y4, UART1 `uart_rx`는 AA2, 관찰자 `uart_tx`는 AB2다.

호환되는 3.3-V logic/common ground를 사용한다. UART1 RX에는 PC adapter TX나 다른 외부 송신자가 동시에 연결되면 안 된다. PC adapter RX는 UART1 TX를 관찰할 수 있으며 UART0 RX와 외부 LoRa 동작은 판정하지 않는다. 보드 시험 전에 실제 board/header 배선을 확인해야 하며 이 명세는 배선을 관측한 근거가 아니다.

결정적인 sequence-tagged framed token과 하나의 outstanding transaction, 정확한 기대 수신 byte 및 bounded deadline을 사용한다. S0 transaction 안은 `A5 5A | seq32 little-endian | ~seq32 little-endian | C3 3C`(12 byte)다. Rendering 중에도 RX를 공정하게 service하며 RX FIFO는 16 byte다. Bounded TX retry/resynchronization이 무한 FIFO drain이 되어서는 안 된다. Stale/corrupt/malformed token이나 sticky RX error는 progress를 충족하지 못한다. UART1 TX 출력 실패/staleness는 관찰자 근거에 한정한다.

## 7. GPIO, SW 및 LED 보드 시험

동결한 GPIO 경로는 **GPIO[0] output → physical jumper → GPIO[1] input**이다. Owned mask는 `0x0003`, drive mask는 `0x0001`, sense mask는 `0x0002`다. 정식 GPIO_IO0/1 pin V10/W10은 UART pin과 별개다. GPIO1에 경쟁 외부 driver가 없어야 하며 실제 JP1/header 연결과 전압 호환성을 보드 사용 전에 확인한다.

GPIO0 output latch를 먼저 준비하고 production direction API로 GPIO1 input/GPIO0 output을 구성한다. 단일 소유자의 masked operation으로 다른 direction/output bit를 보존한다. 수신 input과 독립적으로 바뀌는 0/1 pattern을 생성하고 synchronizer에 충분한 bounded settling 이후 양쪽 논리 값을 반복 확인한다. Synchronized GPIO1을 보관한 GPIO0 기대 bit와 비교한다. DATA_OUT readback만으로는 부족하다. 다른 GPIO bit나 IRQ/PLIC 경로는 이 baseline 판정 대상이 아니다.

Input service마다 synchronized `s = SW[9:0]`를 한 번 읽고 보드 명령을 위해 보관한다. 정적 SW도 유효하다. **LED[9:0] = SW[9:0]**를 쓰고 캡처한 s와 LED latch readback을 비교한다. 공통 snapshot에 캡처한 SW, 명령한 LED 및 readback을 보고한다. 각 실제 LED가 대응 switch를 따라가는지는 사용자가 별도로 확인한다. 이 mapping 중에는 무관한 LED heartbeat animation이나 aggregate status multiplexing을 하지 않는다.

## 8. HEX dual-mode 보드 계약

Production HEX CTRL shadow를 초기화한다. `SW[9]`는 mode, `SW[8:0]`는 payload p다. 활성 표시 중 ENABLE=1이다. 필수 SW 보드 시험 mapping이 HEX/LED에 aggregate health를 표시하자는 제안보다 우선한다. Aggregate status는 VGA/PC UART에 표시한다.

### 8.1 Mode 0 — decoded numeric/value 표시

```text
p = SW[8:0]
P2 = p[8] (zero-extended nibble)
P1 = p[7:4]
P0 = p[3:0]
HEX5 HEX4 HEX3 HEX2 HEX1 HEX0
 P2   P1   P0   P2   P1   P0
VALUE = p | (p << 12)
RAW_MODE = 0
```

예: p=0x000 → `000000`, p=0x12A → `12A12A`, p=0x1FF → `1FF1FF`. 이 mode에서 HEX2/5는 의도적으로 0/1만 표시하며 raw diagnostic으로 6개 digit의 모든 segment를 시험한다.

### 8.2 Mode 1 — raw segment diagnostic

```text
group = SW[8:7]
on_mask = SW[6:0] in {g,f,e,d,c,b,a} order
raw = (~on_mask) & 0x7f
RAW_MODE = 1
```

| group | HEX pattern |
|---|---|
| `00` | 6개 digit 모두 raw. |
| `01` | HEX2..0은 raw, HEX5..3은 blank(`0x7f`). |
| `10` | HEX5..3은 raw, HEX2..0은 blank(`0x7f`). |
| `11` | HEX0/2/4는 raw, HEX1/3/5는 보수 pattern `on_mask`. |

ri는 HEXi의 선택한 7-bit pattern이다. `RAW_LOW = r0 | (r1 << 7) | (r2 << 14)`, `RAW_HIGH = r3 | (r4 << 7) | (r5 << 14)`로 pack한다. Segment bit는 active-low로 0이 켜짐, 1이 꺼짐이며 blank는 `0x7f`다. DP bit는 없다. All-on/off와 7개 walking on_mask bit로 모든 digit/segment를 시험하며 실제 점등은 사람이 관찰하는 근거다.

전환 시 driver로 disable하고 VALUE 또는 RAW 두 bank를 쓴 다음 mode를 선택하여 re-enable한다. RAW 두 번의 write는 6개 digit의 atomic update가 아니다. Masked VALUE/RAW readback과 decoded CTRL=1 또는 raw CTRL=3을 확인한다. Snapshot에 mode/payload/group 및 명령/readback data를 포함한다. CTRL write는 driver만 수행하며 shadow 소유권을 유지한다.

### 8.3 S4 전용 raw getter 결정

승인된 S4 확장은 `firmware/include/hex_display.h` / `firmware/drivers/hex_display.c`의 `hex_display_read_raw_low()` 및 `hex_display_read_raw_high()`다. 정식 register를 부작용 없이 읽고 21 functional bit(`0x001fffff`)로 mask한다. CTRL 소유권/shadow 재설계는 허용하지 않는다. 구현/시험은 S4로 미루며 S1에는 driver API/code를 추가하지 않는다.

## 9. VGA heartbeat 및 publication 순서

VGA heartbeat는 **DOMAIN_READY + 새/반복 VSYNC + 발행한 SWAP + 그 operation에 연결된 새 OP_DONE + OP_ABORT 없음**을 요구한다. 정적 그림, stale sticky event 및 clear-only DONE은 충족하지 못한다.

Bounded state machine으로 READY/idle 대기, 필요 시 writable back bank clear와 clear 완료 확인, N 동결 및 유한 back-buffer chunk rendering, 기존 VSYNC acknowledgement 및 새 event 관측, ready/idle ownership에서 SWAP 발행, ABORT 없이 새 관련 DONE 및 새 VSYNC 확인을 조합한다. Progress는 N+1용 live state에 기록한다. 필요하면 다음 frame을 위해 새 back bank를 clear한다. Rendering은 주소 범위를 지키고 OP_BUSY 동안 framebuffer write를 하지 않는다.

Helper가 stale status를 지우기 전에 abort를 기록한다. 다음 cycle에서 같은 sticky bit 반복 읽기가 아닌 새 진행을 요구하도록 event를 acknowledge한다. `vga_text_begin_frame()`은 bounded이지만 반환 전에 wait/switch/clear하므로 명시적인 협력형 render-then-present 순서를 대체하지 않는다. 실제 screen image는 별도 사람이 확인하며 내부 heartbeat는 display-domain/ownership 진행만 입증한다.

## 10. 구현된 기반 구조 및 미래 stage gate

아래 경로는 현재 S2 기반 구조 및 host 검증 파일로 존재한다.

```text
firmware/apps/soc_health_main.c
firmware/include/soc_health.h
firmware/services/soc_health.c
firmware/services/soc_health_probes.c
firmware/services/soc_health_render.c
verification/firmware/soc_health_host.c
verification/firmware/soc_health_mmio.h
scripts/wsl/soc_health_host_test.sh
```

Services layer는 hardware driver가 아닌 application service다. 최소 `scripts/firmware/build_fw.sh` 수정으로 기존 app flow를 유지하면서 새 app에만 core/probes/render/providers service를 포함한다. Build에는 외부 RUN_ROOT가 필요하며 해당 환경을 설정한 지원 명령은 `scripts/firmware/build_fw.sh soc_health_main`이다. RV32I/ILP32 freestanding 동작, 기존 startup/trap, **16 KiB IMEM / 32 KiB DMEM** 및 명시적인 두 memory image identity를 보존한다. Memory 용량 및 startup/trap은 변경하지 않았다. S3는 strong-provider app을 build하며 실제 peripheral 합격 판정은 유보한다.

| Stage | 승인된 미래 경계 |
|---|---|
| S2 HEALTH CORE | App skeleton, service, record/현재 mask/sticky 이력, 불변 snapshot/signature, 협력형 bounded scheduler. |
| S3 STRONG PROVIDERS | Timer, UART loopback, G-sensor, ADC, joystick consistency, VGA progress. |
| S4-A BOARD I/O | GPIO0→1, SW, SW-mirrored LED, HEX dual mode/raw getter. |
| S4-B OBSERVERS | S4-A 리뷰 후 별도 승인하는 VGA와 PC UART 공통 snapshot rendering. |
| S5 CLOSURE | Host/unit test, RV32I build/image-size check, 관련 기존 regression, clean local checkpoint. |

S1에서는 S2–S5를 구현하지 않았다. S2 기반 구조, S3 provider, S4-A board I/O 및 S4-B observer는 구현/승인됐다. S5 closure 검증과 문서를 완료했으며 S5 소유자 리뷰를 위해 중단한다. S5 이후에도 Issue #6 C4-A/C4-B 재개 전에 리뷰를 위해 중단한다. Push/vendor 실행/baseline release/global tracker closure를 암묵적으로 승인하지 않는다.

### 10.1 승인된 S2 core ABI, ownership 및 결정적 signature

Stable ID는 SYSTEM_SERVICE=0, TIMER=1, UART_LOOP=2, GPIO=3, GSENSOR=4, ADC=5, JOY_POLICY=6, VGA=7, SW=8, LED=9, HEX=10, AES_GCM=11이다. Mask bit `1u << id`는 고정한다. State/evidence enum 순서는 §2와 같다. Record는 state, evidence, heartbeat_count, last_progress_epoch, miss_count, detail을 보관한다. 현재 mask는 publication 시 복사한 record에서 산출하며 UNKNOWN은 bit가 없다. FAIL은 sticky 이력을 설정하고 복구해도 지우지 않는다. Runtime sticky-clear API는 없다.

S2 checkpoint에서 한 cooperative owner가 Timer 없이 software epoch를 증가시킨다. 각 turn은 열 개 pending provider(ID 1–10) 중 하나를 round-robin 방문하고 observer character를 최대 두 개 처리한다. SYSTEM_SERVICE progress는 software service turn 실행만 뜻한다. S2 peripheral placeholder는 UNKNOWN 및 `SOC_HEALTH_NOT_IMPLEMENTED`(0x4e4f5451, NOT QUALIFYING HARDWARE EVIDENCE)을 유지한다. AES는 provider/callback 없이 EXCLUDED_PENDING_CLEANUP이며 AES report는 모두 거부한다. Production S2 code는 MMIO를 수행하지 않는다.

Progress/deadline-miss token은 IP/event stream별 중복을 제거한다. 첫 event 이후 token은 modulo 2^32에서 0이 아닌 2^31 미만의 차이로 전진해야 한다. Replay/old completion으로 FAIL을 복구할 수 없다. PENDING은 detail만 갱신한다. Armed deadline은 unsigned epoch 경과 및 2^31 미만 budget으로 검사하며 한 번 만료 후 disarm한다. 이는 실제 시간 측정이 아닌 유한 software-turn budget이다. Caller는 epoch 전체 wrap 전에 deadline을 service해야 한다. Terminal CPU/bus fault는 복구 보장 밖이다.

두 static snapshot slot은 logical record/metadata를 복사한다. Publication은 두 observer lease를 취득하며 사용 중인 slot은 덮어쓰지 않는다. 둘 다 점유되면 null을 반환하고 live backlog를 증가시킨다. Observer는 완료/timeout 시 자기 lease만 release하며 두 release 이후에만 slot을 재사용한다. Pointer는 취득한 lease 수명 동안만 유효하며 release/reinitialization 후 사용하면 안 된다. Concurrent/interrupt ownership protocol은 없다. Live 갱신 및 release는 다음 snapshot metadata만 바꾸고 발행된 content는 바꾸지 않는다. Observer 완료는 placeholder 소비이며 실제 display/UART 전달이 아니다.

두 const-input cursor는 같은 snapshot pointer/epoch/signature를 소비한다. Ready cursor는 service 호출마다 `EPOCH=xxxxxxxx SIG=xxxxxxxx`의 한 character를 생성한다. 64-epoch budget에서 지연 observer를 release하고 live observer miss만 증가시킨다. 다른 observer는 독립적으로 완료할 수 있다. App은 32 software turn마다 publication을 요청하고 active render를 완료/timeout까지 유지한다. S4-B는 §10.4의 실제 observer를 추가하며 S2 cursor는 compatibility/unit test용으로 유지한다.

Signature는 32-bit FNV-1a(seed 2166136261, prime 16777619)이며 각 explicit uint32 word의 네 little-endian byte를 처리한다. Target prime 곱은 shift/add로 구현하여 multiply/divide helper가 필요 없다. 정확한 97-word 순서는 다음과 같다.

1. Version tag 0x53483201, epoch, publication_id.
2. pass_mask, warn_mask, fail_mask, excluded_mask, sticky_fail_mask, publication_backlog.
3. observer_miss_count[0], [1], 이후 observer_last_epoch[0], [1].
4. ID 0부터 11까지 각각 ID, state, evidence, heartbeat_count, last_progress_epoch, miss_count, detail.

Signature 자체, struct padding, pointer, slot lease 및 live deduplication token은 제외한다. 같은 logical field는 같은 signature를 만들지만 checksum은 collision-free 보장이나 hardware 합격 근거가 아니다.

### 10.2 S3 strong provider 및 검증 범위

`firmware/include/soc_health_providers.h`와 `firmware/services/soc_health_providers.c`가 provider-local state를 추가한다. Generic S2 core는 변경하지 않았다. `soc_health_main`은 실제 provider dispatcher를 호출한다. S2 pending-dispatch API는 unit test용으로 유지하며 현재 app은 strong dispatcher를 사용한다. 두 API 모두 stable ID 순서를 따른다. 초기 bounded visit은 UART, Timer, G-sensor, ADC, VGA 순서이며 이후 열 개 ID 1–10을 round-robin 방문한다. 각 step은 유한하다. UART는 readiness poll 한 번으로 최대 한 byte 송신 및 최대 네 byte 수신/drain, ADC는 `adc_enable(0)`으로 한 번 요청 후 turn별 acknowledgement 확인, VGA는 deterministic back-bank word 한 개만 기록한다. JOY는 ADC acquisition을 공유한다. S3 checkpoint에서는 GPIO/SW/LED/HEX가 pending placeholder였다. S4-A는 §10.3의 board callback을 연결한다. AES는 dispatch하지 않는다. S2 cursor는 hardware output을 하지 않는다.

기본 provider budget은 262144 software epoch, Timer compare는 50000 PCLK count다. 초기 유한 engineering parameter이며 측정된 wall-clock quota나 board 보장이 아니다. 소유한 peer 가정에서 하나의 outstanding 12-byte UART transaction은 16-byte RX FIFO에 들어가며 RX error는 명시적으로 FAIL한다. Scheduler count로 hardware progress를 만들지 않는다.

| Provider | 유한 qualification / 실제 progress token | 실패/복구 |
|---|---|---|
| Timer | STOP/W1C/RELOAD, 알려진 compare START 및 baseline COUNT; 증가, 새 READY, W1C 및 clear 확인; 재시작 후 새 COUNT 증가 확인. 이 완료 시에만 interval generation token을 증가시킨다. | Frozen COUNT, READY 부재, ACK 고착 또는 restart 실패는 fail/miss. 유한 stop/restart 재시도는 sticky를 보존한다. |
| UART | 두 divisor 434; 정확한 `A5 5A / seq32 LE / ~seq32 LE / C3 3C`. 유한 TX/RX가 각 expected byte를 검사하고 TX 전체 발행 및 12-byte 검증 완료 시 transaction seq를 인정한다. | Bad/stale byte, RX error 또는 deadline은 fail. Empty FIFO 관측까지 유한 drain, partial state 초기화 후 다음 seq를 증가시켜 이전 partial이 새 token을 완료하지 못한다. UART1 TX/UART0 RX/AUX는 사용하지 않는다. |
| G-sensor | Production `gsensor_read_sample()` CAPTURE/read/RELEASE 및 새 실제 sample.seq. Static XYZ 허용. | NO_NEW/BUSY/repeated/stale seq는 deadline까지 pending. 늦은 적격 복구 전 만료 검사로 miss/sticky를 보존하며 invalid result는 fail. |
| ADC | Canonical `adc_init`, 보관한 calibration/count/error baseline, ENABLE 요청/ack; production CAPTURE, CH1/2 valid, 새 HOLD seq, (0, 2^31) FRAME_COUNT delta, CAPTURE 전후 error 확인. Token은 FRAME_COUNT가 아닌 HOLD frame.seq다. | Identity 실패는 명시적 reinit까지 유지. Enable/NO_NEW/stale/frozen-count deadline, invalid mask 또는 sticky error는 fail. Provider는 ADC error를 clear하거나 compatibility joystick wrapper를 사용하지 않는다. Count jump >1 허용. |
| JOY | 정확한 eligible ADC HOLD 보관, current calibration readback, 다음 CAPTURE 전 독립 `joystick_policy_eval`과 HW 여섯 bit 비교. Token은 비교한 HOLD seq다. | Mismatch의 expected/actual을 보존하고 fail. Same-HOLD calibration 변경은 재검사하되 중복 progress나 이미 인정한 seq의 복구를 만들지 않는다. 새 eligible generation은 sticky 보존하며 복구 가능. Invalid/error ADC frame은 ineligible이다. |
| VGA | 단일 operation owner: READY/idle, back-bank word 하나, stale VSYNC/DONE acknowledgement, 새 VSYNC, SWAP 발행(CLEAR 없음), fresh associated DONE/BUSY 없음/ABORT 없음. Token은 완료된 SWAP generation이다. | Helper W1C 전 ABORT 보존, readiness 상실 또는 deadline은 fail. 유한 READY/idle/event 준비로 복구하며 dashboard/monolithic frame helper/두 번째 MMIO owner를 추가하지 않는다. Terminal bus/CPU fault는 복구 밖이다. |

`RUN_ROOT=<fresh-external-directory> scripts/wsl/soc_health_provider_test.sh`는 실제 provider 및 production driver를 독립 register/transaction 입력으로 시험한다. `RUN_ROOT=<fresh-external-directory> scripts/wsl/soc_health_provider_rtl_test.sh`는 같은 C code를 production Timer/UART/G-sensor/ADC+JOY/VGA RTL과 연결한다. RTL fixture는 APB/AHB access, 모의 UART0→UART1 serial continuity, static digital sensor peer 및 ADC PCLK publication input을 구동하며 portable PLL/RAM model은 simulation abstraction이다. RISC-V CPU를 실행하지 않으며 별도 재실행한 P09 CPU/P11 acquisition+CDC regression을 대체하지 않는다. Host/모의 UART continuity는 실제 jumper/board 합격이 아니다. Guard는 raw target log를 보존하며 필수 asserted case 누락/source drift를 거부한다. 격리 결함 및 실패 exit fixture로 거부와 parent nonzero 전파를 검증한다.

### 10.3 S4-A board I/O provider 및 검증 범위

`firmware/services/soc_health_board_io.c`와 `include/soc_health_board_io.h`는 static board state를 보관한다. 선택적 dispatcher callback으로 기존 S3 전용 harness를 보존하며 app은 GPIO=3, SW=8, LED=9, HEX=10에 callback을 연결한다. Ten-way schedule, strong provider 함수, health core, copied snapshot ABI/signature 및 AES 제외는 유지한다. 각 visit은 유한하며 IRQ, busy wait 또는 두 번째 VGA owner가 없다.

GPIO는 소유한 두 pin을 input으로 해제하고 GPIO0 low를 preload한 뒤 production API로 GPIO0 output/GPIO1 input을 설정한다. 독립적으로 보관한 `0,1,1,0`을 구동하며 소유 pair 외 direction/output bit를 보존한다. 각 sample은 visit을 넘어 최소 세 software epoch 기다린 후 synchronized GPIO1과 expected stimulus를 비교한다. MMIO는 PCLK를 전진시키므로 두 input synchronization stage를 포함한다. DIR/DATA_OUT readback은 보조 검사다. 네 sample이 모두 일치할 때만 loopback generation이 완료된다. 전체 cycle의 262144-epoch deadline은 DATA_OUT이 정상이어도 stuck/late/inverted sense를 거부하며 configuration/readback 불일치는 즉시 fail한다. 이후 완전한 cycle은 current PASS를 복구하되 sticky를 보존한다.

SW는 command generation마다 canonical masked 10-bit read 한 번을 수행한다. Observation token/heartbeat는 read 횟수이며 switch motion이나 autonomous progress가 아니다. Static input도 유효하다. LED와 HEX가 모두 retire할 때까지 capture value/generation을 공유한다. Consumer는 262144-epoch budget을 넘으면 다음 fair visit에서 fail하고 pending bit를 해제하며 두 bit가 모두 clear된 후에만 새 capture를 한다. LED는 한 visit에서 captured value write 및 masked latch readback 비교를 수행한다. LED/HEX completion token은 소비한 SW generation이고 완전한 일치 transaction에서만 전진한다.

HEX는 최초 init, 각 command 전 production CTRL shadow resync를 수행한다. 다섯 visit으로 disable → data → mode → enable → readback을 진행한다. RAW 두 bank write는 non-atomic이며 disabled 상태에서 수행한다. Decoder는 `p=SW[8:0]`, `VALUE=p|(p<<12)`, CTRL=1이다. RAW는 CTRL=3, `on=SW[6:0]`, active-low `raw=(~on)&127`, group `SW[8:7]`: 00 모든 digit, 01 아래 세 digit, 10 위 세 digit, 11 짝수 digit raw/홀수 digit on이다. 각 bank에 세 digit을 7-bit stride로 packing한다. CTRL 및 해당 VALUE/RAW readback은 functional masking 후 정확히 일치해야 한다. `hex_display_read_raw_low/high()`는 canonical +0x08/+0x0c read 및 0x001fffff mask만 하며 CTRL shadow를 바꾸지 않는다. Provider는 CTRL을 직접 write하지 않는다.

Signed/copied record detail은 기존 32-bit 형식을 유지한다. SW는 captured 10-bit value, LED [9:0]는 captured SW/[19:10]는 masked readback, HEX [9:0]는 captured SW/[11:10]는 actual CTRL/[27:24]는 mismatch flag(CTRL/LOW/HIGH/VALUE = 1/2/4/8)다. Mode/payload/group은 SW에서 복원할 수 있고 일치한 command의 expected/actual register 전체도 capture에서 결정적으로 복원한다. Static board state는 전체 command/readback word도 보관하지만 live provider state이며 추가 snapshot pointer/leased payload가 아니다. GPIO 성공 detail 0x103은 drive/sense ownership이며 0x71/0x72 failure prefix는 sense deadline/configuration이다. Consumer deadline은 0x73, LED mismatch는 0x74다.

Evidence는 GPIO=PHYSICAL_LOOPBACK(자동 시험 wiring은 **simulated**), SW=INPUT_OBSERVATION, LED/HEX=REGISTER_READBACK을 유지한다. Observation/mirror generation을 STRONG_PROGRESS로 승격하지 않는다. 실제 GPIO jumper continuity, SW electrical behavior, LED illumination/mapping, HEX illumination/digit/polarity는 NOT_RUN board gate다.

Fresh external RUN_ROOT로 `scripts/wsl/soc_health_board_io_test.sh`, `scripts/wsl/soc_health_board_io_rtl_test.sh`, `scripts/wsl/soc_health_board_io_negative_test.sh`를 실행한다. Host는 모든 S3 assertion을 유지하고 decoder/raw 전체 matrix, getter offset/mask/shadow, shared generation, GPIO fault/recovery, consumer bounded retirement 및 failure 중 all-active fairness/snapshot immutability를 검사한다. RTL 통합은 production C core/provider/driver를 production APB_GPIO/SW/LED/HEX와 연결하고 simulated pin jumper 및 외부 SW 기반 독립 LED/physical-segment oracle을 사용한다. RISC-V CPU는 실행하지 않는다. 격리 source defect와 compile/leaf/guard exit는 immutable raw log/실제 source hash를 보존하며 거부해야 한다. 기존 S2/S3/P04/P10 suite는 별도 regression gate로 유지한다. S4-A 시점 dashboard/실제 UART observer는 미구현이었다. S4-B는 §10.4를 추가하며 S2 cursor는 non-MMIO compatibility/test API로 유지한다. S4-A 소유자 리뷰는 S4-B 이전 승인했다.


### 10.4 S4-B 공통 formatter 및 실제 observer

`include/soc_health_observers.h` / `services/soc_health_observers.c`의 순수 `soc_health_format_line(snapshot, line_index, buffer, size)` 하나를 VGA/UART가 함께 사용한다. Return은 잘리지 않은 logical length이며 size>0이면 buffer 안에 terminator를 기록하고 size=0이면 쓰지 않는다. Logical line은 19개, buffer는 고정 48 bytes이며 uppercase hexadecimal/tiny helper만 사용한다. Formatter에는 printf/allocation/MMIO가 없다. State는 P/W/F/?/X다. Text의 모든 값은 복사된 snapshot에서 읽으며 live health state를 읽지 않는다.

동결된 logical format은 다음과 같다(값은 예시).

```text
SOC HEALTH EP=00001234 SIG=89ABCDEF
P=000007FF W=00000000 F=00000000
S=00000004 X=00000800

IP    ST HB       MISS DETAIL
SYS   P  00001234 0000 RUN
TMR   P  00000042 0000 READY
UART  P  00000031 0000 SEQ=00000031
GPIO  P  00000008 0000 LOOP
GSEN  P  00000079 0000 SEQ=000001A2
ADC   P  00000078 0000 SEQ=000001A1
JOY   P  00000078 0000 MATCH
VGA   P  00000020 0000 SWAP
SW    P  00000041 0000 V=155
LED   P  00000041 0000 V=155
HEX   P  00000041 0000 M=0 P=155
AES   X  00000000 0000 PENDING

SYSTEM: PASS
```

Current failure가 있으면 footer는 `SYSTEM: FAIL F=xxxxxxxx S=xxxxxxxx`다. AES PENDING 외 non-PASS record는 불확실한 symbolic detail 대신 `D=xxxxxxxx`를 쓴다. 후속 User/Chat 지시에 따라 MISS만 low 16-bit이며 SEQ/HB/mask/EP/SIG/raw detail은 32-bit 전체(8자리 hex)를 표시한다. SW/LED V는 retained 10-bit captured value, HEX M/P는 copied SW에서 산출한다. 실제 UART/GSEN/ADC SEQ를 live access나 ABI 확장 없이 표시하도록 S4-B는 **성공 report detail**에 qualified transaction/sample/HOLD sequence를 기록한다. S4-A의 detail은 baud=434/zero/FRAME_COUNT였으며 이 gap을 실제 provider로 재현하고 세 곳의 좁은 변경 전에 보고했다. Token, qualification, count freshness/provider-local baseline, error code, core snapshot layout/signature, S4-A 의미는 유지한다. ADC 성공 detail은 이제 FRAME_COUNT가 아닌 HOLD seq이며 이 진단 payload 변경은 아래 tracker에 기록한다.

VGA는 기존 640x480 one-bit framebuffer 및 변경하지 않은 8x8 font renderer를 사용한다. Renderer는 32-pixel-aligned word 단위이므로 권장 x=24 대신 x=32, y=16+16*logical_line을 사용한다. Table header y=80, IP row y=96..272, footer y=304이며 blank line으로 section 간격을 유지한다. 모든 glyph는 visible bounds 안에 있다. 기존 S3 VGA FSM이 **유일한 operation owner**다. PREPARE callback은 visit마다 최대 여덟 word로 back buffer를 clear하고 최대 네 glyph/여덟 word를 render한다. 모든 line 완료 후 stale VSYNC/DONE ack → fresh VSYNC → SWAP → fresh associated DONE/no ABORT → qualification → VGA lease release 순서를 유지한다. App에는 별도의 one-word probe transaction이 없으며 no-hook one-word 경로는 승인된 S3 regression harness용으로만 남긴다. Monolithic begin-frame/clear helper, hardware CLEAR 또는 두 번째 owner는 추가하지 않는다.

두 실제 observer는 같은 published N을 취득하고 VGA/UART pointer 및 reader bit를 독립 보관한다. VGA는 sole owner의 DONE/abort/readiness loss/deadline에서, UART는 독립적으로 release한다. N은 완료 전 VGA state를 담으며 완료는 live state만 바꾸고 다음 publication에 반영한다. Release 후 pointer를 지우고 released pointer로 text를 재개하지 않는다. 기존 two-slot no-overwrite/backlog 및 97-word signature ABI는 유지한다. App은 한 observer pair를 직렬로 진행하고 pending 중 publication backlog를 기록하며 lease test는 두 slot 점유도 검사한다.

UART1 TX는 turn마다 bounded readiness attempt 한 번/최대 한 byte를 보내고 baud divisor는 기존 UART provider가 그대로 설정한다. `=== SOC HEALTH SNAPSHOT ===\r\n` → blank line을 포함한 common logical line별 CRLF → 40개 hyphen/CRLF를 출력한다. 마지막 byte acceptance 후 TX ready를 기다려 drain을 확인하고 release한다. ANSI/cursor/clear-screen은 없으며 PuTTY는 append-only diagnostic log를 보관한다. 262144-software-epoch observer budget timeout은 UART lease만 release하고 live observer miss를 기록한다. VGA는 유한 preparation budget 및 전체 transaction의 기존 owner deadline을 사용한다. UART1 TX는 UART heartbeat를 report하지 않으며 UART0 TX→UART1 RX 자동 heartbeat 경로를 유지한다.

Host는 literal logical-line fixture 및 승인된 unchanged font asset을 독립 per-pixel raster로 배치하여 bounds/determinism/no-MMIO, state/detail/footer, exact PC text, 두 완료 순서, partial work, N 불변성, 독립 timeout/abort release, backlog 및 모든 active provider의 fair visit/progress를 assert한다. 실제 provider/driver/RTL 통합은 accepted framebuffer write별 commit/address/data/back bank, SWAP 전 독립 expected raster 전체, fresh DONE 후 presentation bank와 UART1 TX의 독립 serial decode를 검사하여 같은 frozen EP/SIG를 증명한다. UART0→UART1 RX와 S3 strong peripheral을 동시에 실행하지만 CPU E2E는 아니다. Fresh external RUN_ROOT로 `scripts/wsl/soc_health_observer_test.sh`, `soc_health_observer_rtl_test.sh`, `soc_health_observer_negative_test.sh`(모두 `scripts/wsl/` 아래)를 실행한다. 격리 결함 및 successful-target/failed-guard fixture는 nonzero와 일관된 FAIL artifact로 전파해야 한다. 기존 16KiB IMEM을 지키도록 새 observer service만 `-Os`로 build하며 text/font infrastructure를 중복하지 않는다.

실제 VGA image quality, UART cable/USB adapter/PuTTY, GPIO jumper, SW/LED/HEX/sensor/ADC, real-time quota, stack high-water 및 vendor timing은 NOT_RUN이다. S4-B 소유자 리뷰는 승인됐다. S5 closure 결과 리뷰에서 중단하며 C4 pause/no push를 유지한다.

### 10.5 최종 software architecture

이 map은 S5 checkpoint의 최종 SYSFW-01 구현을 설명한다. 아래 path는 실제 tree의 관련 부분이며 제안 구조가 아니다. App은 health service를 통해 production driver API를 조정한다. `joystick_policy.c`는 MMIO driver가 아닌 순수 policy model이다. S4-A에서 `hex_display.c/.h`에 side-effect-free masked RAW_LOW/RAW_HIGH getter를 추가했으므로 모든 driver가 변경되지 않았다고 표현하지 않는다.

#### 코드 구조

```text
firmware/
├── apps/
│   └── soc_health_main.c         # 진입점; 협력형 loop 및 callback 연결
├── include/
│   ├── soc_health.h              # Stable ID, state/evidence, core/snapshot/lease ABI
│   ├── soc_health_providers.h    # Strong-provider state, dispatcher 및 callback interface
│   ├── soc_health_board_io.h     # GPIO/SW/LED/HEX provider context 및 interface
│   ├── soc_health_observers.h    # 최종 formatter/observer cursor 및 VGA hook
│   └── hex_display.h             # HEX API; S4-A RAW_LOW/RAW_HIGH getter
├── services/
│   ├── soc_health.c              # Live record/history, copied snapshot 및 FNV-1a
│   ├── soc_health_probes.c       # S2 placeholder dispatch; 호환성/단위시험
│   ├── soc_health_providers.c    # Strong-provider FSM; 단일 VGA operation owner
│   ├── soc_health_board_io.c     # GPIO loop, 공유 SW generation, LED/HEX 검사
│   ├── soc_health_observers.c    # 최종 공유 text, VGA preparation 및 UART1 TX
│   └── soc_health_render.c       # S2 non-MMIO observer skeleton; 호환성/시험
└── drivers/
    ├── timer.c                   # Timer MMIO command/status
    ├── uart.c                    # UART0/1 MMIO 및 bounded byte API
    ├── gsensor.c                 # Coherent CAPTURE/read/RELEASE API
    ├── adc.c                     # ADC v2 identity, HOLD, error 및 calibration
    ├── joystick_policy.c         # 순수 raw-frame/calibration policy; MMIO 없음
    ├── gpio.c                    # GPIO direction/latch/input MMIO
    ├── sw.c                      # 전용 synchronized SW register API
    ├── led.c                     # 전용 LED latch/readback API
    ├── hex_display.c             # HEX shadow/packing 및 S4-A raw getter
    ├── vram.c                    # Framebuffer write 및 VGA status/operation
    └── vga_text.c                # 기존 8x8 font 및 packed framebuffer text
```

`soc_health_observers.c`와 `soc_health_observers.h`가 최종 S4-B hardware observer 경로다. App의 변수명은 `render`지만 type은 `soc_health_observers_t`다. App은 `soc_health_observers_vga_prepare`/`soc_health_observers_vga_release`를 provider context에 연결하고 loop마다 `soc_health_observers_uart_service`를 호출한다. `soc_health_render.c`는 S2 bounded non-MMIO cursor skeleton, `soc_health_probes.c`는 S2 pending-only dispatch로 남아 있으며 최종 app hardware 경로가 아니다. 호환성/단위시험 API는 유지되고 health build 목록에 포함되지만 사용하지 않는 function은 link-time section GC로 제거될 수 있다.

#### 데이터 및 제어 흐름

```text
+------------------------------------------------------------------------------+
| soc_health_main.c -- one cooperative software epoch per loop                 |
| Epoch/system record -> one bounded provider dispatch -> UART observer tick   |
| Then check publication cadence; no full-provider sweep in one turn.          |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| Provider layer: soc_health_providers.c + soc_health_board_io.c               |
| Timer: COUNT/READY/ACK/restart    GPIO: settled 0,1,1,0 pin loop             |
| UART: UART0 TX -> UART1 RX       SW: captured synchronized 10-bit generation |
| GSEN: CAPTURE/read/RELEASE + seq LED: same SW generation -> mirror/readback  |
| ADC: coherent HOLD/seq/count    HEX: same SW -> decoder/raw readback         |
| JOY: HW status vs pure FW policy; ADC may qualify JOY in its bounded step.   |
| VGA: sole operation-owner FSM; invokes observers VGA prepare/release hooks.  |
| Reports: fresh progress token/detail, failure, pending or deadline miss.     |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| soc_health.c -- live core state (single cooperative owner)                   |
| 12 stable IP records: state/evidence/HB/last_progress/misses/detail          |
| Fresh progress -> current PASS; FAIL/deadline miss -> sticky_fail_mask.      |
| Recovery changes current state; sticky failure history remains.              |
| AES-GCM: EXCLUDED_PENDING_CLEANUP; never dispatched as a provider.           |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| soc_health_publish_snapshot -- two static copied slots, no allocation        |
| Copy logical fields; derive current PASS/WARN/FAIL/EXCLUDED masks here.      |
| Compute deterministic 32-bit FNV-1a over explicit little-endian fields.      |
| Slot reader bits = VGA | UART; any held lease prevents slot overwrite.       |
| Publication due after 32 epochs since last success, only if app pair idle;   |
| otherwise increment backlog; no free slot also increments core backlog.      |
+------------------------------------------------------------------------------+
                                       |
                                       v
+------------------------------------------------------------------------------+
| soc_health_observers.c -- same const snapshot N -> one common formatter      |
| soc_health_format_line: copied EP/SIG/masks/records; no live reads or MMIO.  |
| Both observers retain N across turns; explicit cursors bound work.           |
+------------------------------------------------------------------------------+
               | same frozen N                  | same frozen N
               v                                v
+-------------------------------------+  +-------------------------------------+
| VGA dashboard (observers.c)         |  | UART1 PC-TX observer (observers.c)  |
| Called inside provider VGA FSM      |  | One byte/readiness attempt per turn |
| 640x480; 8x8; 16px row pitch        |  | Same EP/SIG and logical lines       |
| Bounded back-buffer clear/glyphs    |  | Append-only CRLF; banner/separator  |
| Then owner: stale-event ACK ->      |  | Final-byte drain before release     |
| fresh VSYNC -> SWAP -> fresh DONE   |  | Timeout releases UART lease only    |
| No ABORT -> live VGA progress       |  | TX never qualifies UART heartbeat   |
| VGA hook releases its own lease     |  | UART cursor clears on own release   |
+-------------------------------------+  +-------------------------------------+
```

Diagram은 mutable health record와 copied view를 구분한다. Current mask는 live core에 계속 저장하지 않고 `soc_health_publish_snapshot`에서 생성한다. UNKNOWN은 네 current mask에 포함되지 않는다. Signature는 explicit-field deterministic consistency identifier이며 cryptographic hash 또는 physical output 증명이 아니다. Mutable reader bit와 structure padding은 signature 입력에 포함하지 않는다.

VGA preparation은 기존 `soc_health_vga_service` owner의 callback이며 두 번째 operation controller가 아니다. Prepare visit마다 최대 eight-word clear 또는 four-glyph render 후 dispatcher로 복귀한다. Owner만 fresh VSYNC/SWAP/associated DONE을 진행하고 ABORT를 거부한다. UART observer는 선택한 provider dispatch 뒤에 별도로 진행한다. 두 output 모두 health state를 재계산하지 않고 같은 `soc_health_format_line`과 snapshot EP/SIG를 사용한다. 자동 UART evidence는 12-byte UART0 TX -> UART1 RX token loop이며 UART1 TX는 observer-only다.

#### 한 publication cycle

1. `soc_health_epoch_begin`은 software epoch를 증가시키고 system-loop progress를 report한다. 이는 software 실행 기록이며 독립 CPU hardware qualification은 아니다.
2. `soc_health_providers_service`는 bounded dispatch 하나를 선택한다. 초기 setup visit 다섯 번(UART, Timer, GSEN, ADC, VGA) 뒤 provider ID 1-10을 round robin으로 방문한다. Dispatch는 transaction을 한 단계 진행하며 모든 provider를 완료하지 않는다. Eligible ADC capture는 정확히 같은 HOLD로 JOY를 함께 qualify할 수 있다.
3. Progress/failure/pending/deadline report가 live record를 갱신하며 core API는 WARN도 지원한다. Fresh progress token만 HB를 qualify하고 pending work는 progress를 만들지 않는다. Failure의 sticky history는 recovery 뒤에도 유지한다. SW는 LED/HEX가 retire할 때까지 하나의 captured generation을 보존한다.
4. Provider dispatch 뒤 UART1은 기존 observer cursor를 최대 one byte 진행한다. 마지막 성공 publication 이후 최소 32 epoch가 지나고 현재 두 observer가 모두 idle일 때만 app이 publish하며 busy이면 backlog를 증가시킨다. 이는 software cadence이지 측정된 wall-clock rate가 아니다.
5. Core는 reader가 없는 slot을 선택해 logical record/metadata를 복사하고 current mask를 생성하며 explicit-field FNV-1a와 두 reader lease bit를 설정한다. Free slot이 없으면 overwrite 대신 backlog를 기록한다. `soc_health_observers_begin`은 같은 const N을 두 cursor에 전달한다.
6. 이후 VGA dispatch에서 단일 owner가 N의 전체 back buffer를 단계적으로 준비하고 stale event를 acknowledge한 뒤 fresh VSYNC를 기다려 SWAP한다. Fresh associated DONE과 no ABORT가 필요하다. Completion은 live VGA progress를 qualify하고 VGA lease를 release한다. Failure/timeout이면 성공 completion 없이 해당 lease를 release한다.
7. 사이에 실행되는 UART observer visit은 같은 logical line을 banner/CRLF/separator와 함께 출력한다. 마지막 byte drain 뒤 UART lease를 release하고 timeout은 UART lease만 release하며 live observer miss를 기록한다. 어느 observer든 먼저 완료할 수 있다.
8. 두 reader bit가 모두 해제된 뒤에만 slot을 재사용하며 release 시 observer pointer를 지운다. N 관측 중 provider progress/observer metadata 갱신은 live state만 바꾸고 이후 N+1에 나타난다. 따라서 N의 VGA record는 자기 dashboard SWAP completion 이전 상태다.

**Evidence 경계:** Host/unit verified; provider/driver/RTL verified; RV32I image built. `soc_health_main` CPU E2E, physical board 및 Quartus/TimeQuest는 NOT_RUN이고 AES는 excluded다. S5 readiness matrix와 남은 gate는 §11.1을 참조한다. 이 설명은 새 verification 또는 C4 권한을 추가하지 않는다.


## 11. 합격 및 미래 반증 map

미래 시험은 contract → 독립 oracle → stimulus/checker → 고유 source/run → raw evidence/verdict를 연결한다. S1 동결 시 모두 NOT_RUN이었다. S2는 독립 serialized-signature oracle, IP별 mask, padding/copy/lease, token/deadline 및 bounded scheduler/observer 시험을 포함한 host suite가 통과했고 격리된 여섯 결함 mutation을 거부했다. Compile/target/guard 실패 fixture는 parent nonzero 및 일관된 FAIL 보고서로 전파한다. 실제 RV32I skeleton build가 통과했고 기존 display_smoke의 전후 memory image는 동일하다. 그 hardware/board/review 범위는 S2에서 NOT_RUN이었다. S3 provider host 및 실제 peripheral RTL 통합, 격리 결함 거부와 관련 과거 regression은 통과했다. 실제 peripheral 실행, board 배선/display, real-time quota 및 stack high-water는 NOT_RUN이다. S3 소유자 리뷰는 S4-A 이전 승인됐으며 S4-A host/RTL 검사와 격리 결함 거부는 §10.3에서 검증했다. S4-A 소유자 리뷰는 승인했으며 S4-B 소유자 리뷰는 승인됐고 S5 closure 결과의 소유자 리뷰가 필요하다. `RUN_ROOT=<external-directory> scripts/wsl/soc_health_host_test.sh`를 실행하며 매번 새 output storage를 사용한다. Raw evidence는 checkout 밖에 보존하고 stage 결과로 보고하며 계약에 내장하지 않는다.

| 기준 | Oracle / 반드시 거부할 결함 |
|---|---|
| State/history | 명시적인 상태 전이/deadline. 복구 시 sticky failure/miss를 보존하며 excluded AES fail bit 또는 UNKNOWN의 낙관적 PASS를 거부한다. |
| Snapshot | 하나의 불변 object 및 명시적 field signature. Observer별 재계산 또는 N 소비 중 overwrite를 거부한다. |
| UART/GPIO | 독립 요청 token/pattern과 수신/synchronized 값 비교. Stale/corrupt token과 output readback이 일치해도 stuck/inverted GPIO를 거부한다. |
| G-sensor/ADC | Coherent capture 및 시간적인 seq/count 진행. Constant seq의 API success, invalid CH1/2 mask 또는 무시한 ADC sticky error를 거부한다. |
| Joystick | Raw HOLD/calibration 기반 saturation/strict boundary. HW status 복사 대신 axis/validity/threshold 불일치를 거부한다. |
| VGA | 새 acknowledged event 순서 및 operation ownership. Static image, stale VSYNC/DONE, clear-only DONE 또는 무시한 ABORT를 거부한다. |
| SW/LED/HEX | 캡처한 SW로 latch/packing을 독립 예측한다. LED mismatch와 잘못된 HEX group/polarity를 거부한다. Readback으로 물리 점등을 판정하지 않는다. |
| Build/regression | 실제 RV32I image-size/build 및 관련 regression exit. Leaf/guard/parent 실패가 최종 nonzero와 일관된 보고서에 전파되어야 한다. |

신규/중요 변경 checker는 승인된 production/과거 evidence를 변경하지 않고 격리 fixture에서 valid case를 수락하고 targeted counterexample을 거부해야 한다. 유한 polling도 terminal CPU/bus fault를 복구하지 못하며 signature 일치도 물리 출력을 입증하지 못한다. 실패 시도를 보존하고 runtime 판정과 source-level alignment를 구분한다.

### 11.1 S5 검증 closure 및 C4 인계 경계

S5는 production C, driver, peripheral RTL, checker 및 build script를 변경하지 않고 완료했다. S2/S3/S4-A/S4-B host 4종 및 provider/driver/RTL 3종이 새 run에서 통과했다. S2 isolated mutation 6종, S3 host mutation 10종/RTL mutation 6종, S4-A negative 19종, S4-B negative 32종은 실제 targeted rejection/실패 전파를 다시 검증했다. Timer P06, UART P07, VGA/VRAM P08B, G-sensor P09 host(실제 GS RTL은 S3 integration), HEX P10 functional/shadow, ADC/JOY P11 C2/C3, GPIO/SW/LED P04 host 및 S4-A real RTL을 실행했다. 이 결과는 CPU E2E 또는 physical acceptance가 아니다. Raw command/source/hash/target/guard/parent 증거는 외부 run과 S5 결과 댓글에 보존한다.

Fresh `soc_health_main` RV32I/ILP32/nostdlib build: `.imem` **13,492 / 16,384 bytes (82.3486%)**, headroom **2,892**, S4-B 대비 delta **0**. `.dmem_init` **1,048**, `.bss` **1,556**, allocated span **2,604 / 32,768**, headroom **30,164 bytes**. ELF section/map/symbol로 확인했으며 ELF/MIF/map/disassembly hash를 보존했다. Undefined symbol은 없고 printf/allocation/memcpy/memset/mul/div/mod helper 또는 예상 밖 libc/libgcc는 없다. Observer service만 기존 `-Os`, 나머지는 O2다. 대표 non-health `display_smoke`의 entry 대비 IMEM/DMEM binary/MIF가 동일하며 health service는 포함되지 않는다. Default depth는 4096/8192를 유지한다.

16 KiB baseline retained; capacity pressure observed: **YES**; closure fit: **YES**. 가장 큰 linked text는 board service 1,660, signature 1,288, formatter 1,020 bytes다. 새 observer의 formatter/UART service/VGA prepare는 1,020/384/332 bytes이며 S4-B 성장의 주요 부분이나 전체 text를 지배하지 않는다. 추가 size optimization이나 memory 확대는 수행하지 않았다.

아래는 Issue #7 인계 matrix다. RV32I BUILT는 firmware image에 해당 경로가 포함된다는 뜻이며 CPU 실행을 뜻하지 않는다. CPU/system의 host 검증은 health core/scheduler만 의미한다. Physical UART jumper/USB-UART/PuTTY, GPIO jumper, SW/LED/HEX mapping, VGA monitor, ADC/joystick/sensor, real-time quota, stack high-water, soc_health_main CPU E2E 및 Quartus/TimeQuest는 모두 NOT_RUN이다. AES는 EXCLUDED_PENDING_CLEANUP이다. S5 및 Issue #7 인계를 User/Chat이 승인하기 전 Issue #6 C4를 재개하지 않는다. Baseline release/Issue closure/push도 수행하지 않았다.

| Scope | Host | RTL/driver | Firmware image | Physical | CPU E2E | Vendor |
|---|---|---|---|---|---|---|
| CPU/system loop | HOST VERIFIED (health core/scheduler only) | — | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| Timer | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| UART heartbeat | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| UART observer | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| GPIO | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| G-sensor | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| ADC | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| Joystick | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| VGA heartbeat | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| VGA dashboard | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| SW | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| LED | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| HEX | HOST VERIFIED | RTL/DRIVER VERIFIED | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| AES-GCM | EXCLUDED | EXCLUDED | EXCLUDED | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| snapshot/formatter | HOST VERIFIED | RTL/DRIVER VERIFIED (observer outputs) | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |
| build flow | HOST VERIFIED (image compatibility) | — | RV32I BUILT | PHYSICAL NOT_RUN | CPU E2E NOT_RUN | VENDOR NOT_RUN |

### 11.2 실기 하드웨어 수용 및 텔레메트리 실측 증적 (이슈 #6 C4-B / putty_26_09_27_1.log)

Terasic DE10-Lite FPGA 실기 보드 수용 시험은 이슈 #6 C4-B를 통해 수행되었으며, 시리얼 텔레메트리 로그에서 6,800만 클럭 사이클에 걸쳐 수집된 **4,055개 연속 파싱 헬스 스냅샷**을 통해 완전성이 검증되었습니다:
- **텔레메트리 로그**: `/home/swp/soc/putty_26_09_27_1.log` (SHA-256 `469047c4b037e6b0bcbdaee63e9098a09f8043815ff5e78b931756ed7109cd3e`).
- **실기 보드 사진**: `/home/swp/soc/P11_board_test.jpg` (SHA-256 `45f0180f3fbcbe2d686fcad80878bb7bd08069cba50be750916788c8432a6227`), `docs/assets/images/soc_health_board_demo.jpg`. 에포크 141,025,616 사이클(`0x0867E150`)에서 촬영되었으며 `SYSTEM: PASS`, 스위치 `V=380`, `HEX=180` 출력 상태를 증명함.
- **48초 실기 보드 시연 영상**: `https://www.youtube.com/shorts/RxXCySoRTMY`.

#### 주요 실기 검증 결과:
1. **자율 오류 검출 및 복구 (GPIO 루프백)**:
   - 의도적인 GPIO 점퍼(`PIN_V10` $\leftrightarrow$ `PIN_W10`) 분리 시 실시간으로 오류를 포착하여 `MISS` 카운트가 `0x007A`까지 증가하고 sticky 실패 비트 `S=0x00000008` (bit 3 = GPIO)을 래치함.
   - 점퍼 재연결 즉시 시스템 중단 없이 `P ... LOOP`로 자동 복구되며 하트비트가 신속히 재개(`HB=0x00141D30` = 131만 패킷)되어 CPU 행 없는 자율 복구 복원력을 입증함.
2. **SW-to-HEX APB 수학적 변환 및 MMIO 리드백 검증**:
   - 펌웨어 변환 규칙 $M = (\text{SW} \gg 9) \ \&\ 1$ 및 $P = \text{SW} \ \&\ \text{0x1FF}$가 31가지 고유 스위치 입력 패턴 및 4,055개 스냅샷 전체에서 **불일치 0건 (100% 수학적 일치)**으로 검증됨.
   - `HEX_CTRL`, `HEX_VALUE`, `HEX_RAW_LOW`, `HEX_RAW_HIGH`의 하드웨어 MMIO 리드백 결측 오류 0건 (`HEX P ... MISS=0000`).
3. **ADC 및 조이스틱 결측 없는 공존성 (Zero Miss)**:
   - 시퀀스 번호가 단조 증가하여 `SEQ=0x084ABAAE` (실기 보드 상 1억 3,911만 회 캡처)에 도달했으며 시험 전 과정에서 **결측 프레임 0건 (`MISS=0000`)** 유지.
   - 하드웨어 레지스터 `ADC_JOY_STATUS`와 펌웨어 오라클 `joystick_policy_eval()`이 **4,055개 스냅샷 전체에서 100% 일치**.
4. **서브시스템 간 공존성**:
   - 고대역폭 VGA 메모리 트래픽(8,333회 이상 프레임버퍼 스왑), 577,912회 UART 하드웨어 루프백 전송(손실 0건), 동적 스위치 토글링, 지속적인 HEX MMIO 리드백이 병행 실행되는 동안 ADC 샘플링 및 CPU 실행에 간섭을 전혀 주지 않음.

## 12. Baseline-cleanup spec/FW 정합성 트래커 (Role B)

### 12.1 운영 정책 및 schema

`canonical IP spec ↔ RTL-visible behavior ↔ FW driver/API ↔ soc_health assumption`을 추적한다. Owning IP spec이 권위를 유지하며 이 문서는 임시 통합 ledger다. Issue #7 및 이후 cleanup에서 새로운 불일치를 영어/한국어 양쪽에 추가한다. 지금 관련 없는 owning spec을 대폭 고치지 않는다. Cleanup 말기에 한 번의 통합 reconciliation 점검에 이 ledger를 사용하며 조정 후 status/evidence를 갱신하고 항목을 삭제하지 않고 이력을 남긴다.

필수 field는 ID, IP/subsystem, canonical spec source, FW source/API, observed mismatch, accepted/current authority, required future reconciliation, status, origin issue/phase, verification evidence다. 허용 status는 `OBSERVED`, `CLEANUP_PENDING`, `IMPLEMENTATION_ACCEPTED_DOC_STALE`, `FW_STALE`, `SPEC_STALE`, `VERIFIED_ALIGNED`다.

`VERIFIED_ALIGNED`는 명시한 계약의 source/API 정합성만 의미하며 새 runtime/board 합격이 아니다. 아래는 소스 기준의 S0 발견 내용/status 분류를 보존한다. S1 문서 조치는 명시적으로 기록하며 관련 없는 cleanup requirement를 closed로 승격하지 않는다.

Evidence ID: **E0** = 기준 소스의 S0 static source inspection 및 승인된 결과. **E1** = S1 local documentation checkpoint의 문서 delta. 둘 다 실행된 firmware test를 뜻하지 않는다. Owning spec은 자체 과거 evidence reference를 포함한다. 이 문서에 raw log, machine-local path 또는 private payload를 넣지 않는다.

### 12.2 초기 record 및 S1 조치

모든 row는 Issue #7/S0에서 기원하여 S1로 이어진다. FW column의 `firmware/`, spec column의 `spec/` prefix는 repository-relative다.

| ID / subsystem | Canonical spec source | FW source/API | 관측 불일치/부채 | 승인/현행 권위 | 필요 조정 / S1 조치 | Status (범위) | Origin | Evidence |
|---|---|---|---|---|---|---|---|---|
| HREC-CPU / CPU | `19_firmware_contract.md` §2; `21_cpu_core.md` | `bsp/start.S` | Startup 설명에 early mtvec 설치/diagnostic fail-stop이 빠져 있다. | 기존 startup은 mtvec를 설치하고 fail-stop; pre-mtvec risk 유지. | 이후 startup 설명을 조정하고 trap 동작 보존. | IMPLEMENTATION_ACCEPTED_DOC_STALE | #7/S0→S1 | E0; startup source |
| HREC-TIMER / Timer | `10_timer.md` §21; `19_firmware_contract.md` §37 | `drivers/timer.c`, `include/timer.h` | Command subset은 정합하나 timer_wait_ready는 unbounded. | Exact-N START/STOP/RELOAD; W1C로 재시작하지 않음. | Health는 status/유한 service 사용; legacy wait 부채 별도 유지. | VERIFIED_ALIGNED (command subset); CLEANUP_PENDING (legacy wait) | #7/S0→S1 | E0; driver source |
| HREC-UART / UART0/1 | `09_uart.md` P07B; firmware §38 | `drivers/uart.c`, `include/uart.h`, `drivers/lora_uart.c` | 옛 A4는 safe minimum 미해결로 서술하나 현행 217 limit/유한 API 존재. | 현행 P07B; raw loop는 AUX/module policy 제외. | 옛 addendum은 이후 조정; §6에 loop 예외 동결. | IMPLEMENTATION_ACCEPTED_DOC_STALE; VERIFIED_ALIGNED (active API) | #7/S0→S1 | E0; UART source; E1 §6 |
| HREC-GPIO / GPIO | `11_gpio.md` active Part II; firmware P04 note | `drivers/gpio.c`, `include/gpio.h`, `bsp/linker.ld` | Firmware §11/linker comment가 SW/LED pseudo-GPIO 설명 유지. | P04 실제 16-pin GPIO 및 synchronized input. | 과거 설명/comment는 이후 조정; owned pair만 사용. | IMPLEMENTATION_ACCEPTED_DOC_STALE | #7/S0→S1 | E0; APB_GPIO/driver source |
| HREC-GSENSOR / G-sensor | `12_gsensor.md` §§7–9; firmware §12 | `drivers/gsensor.c`, `include/gsensor.h` | API는 정합; 시간적인 seq 요구는 health layer에서 추가해야 함. | Single-owner CAPTURE/read/RELEASE, 유한 NO_NEW/BUSY. | ABI 보존; 새 heartbeat progression은 이후 검증. | VERIFIED_ALIGNED | #7/S0→S1 | E0; coherent driver source |
| HREC-ADC / ADC | `15_adc_joystick.md` §§8–9; firmware §§13/27 | `drivers/adc.c`, `include/adc.h`, `include/soc_memory_map.h` | Parent C3/C3.5 승인에도 광범위 In-progress label 잔존. | 승인된 v2 checkpoint; bit6 reserved zero; C4 pending. | Status 설명은 이후 조정; C4 gate/count 의미 분리 유지. | IMPLEMENTATION_ACCEPTED_DOC_STALE (narrative); VERIFIED_ALIGNED (API) | #7/S0→S1 | E0; v2 source/parent acceptance |
| HREC-JOY / joystick | `15_adc_joystick.md` §§10–11 | `drivers/joystick_policy.c`, `include/joystick_policy.h`, `drivers/joystick.c` | Pure model 정합; compatibility init/enable은 결과를 버리고 read는 stale HOLD fallback 가능. | Coherent HOLD/current calibration의 saturated strict-threshold model. | Health는 adc API 직접 사용; compatibility 한계를 관측 부채로 유지. | VERIFIED_ALIGNED (pure model); OBSERVED (compatibility) | #7/S0→S1 | E0; policy/wrapper source |
| HREC-VGA / VGA | `08_vga.md` §§2–3 | `drivers/vram.c`, `include/vram.h`, `drivers/vga_text.c` | Firmware §7은 VGA wait를 unbounded로 서술; begin_frame은 반환 전 switch/clear. | 현행 wait는 bounded; 명시적 operation/ownership 계약. | 옛 설명은 이후 조정; 협력형 render-then-swap 조합. | IMPLEMENTATION_ACCEPTED_DOC_STALE; OBSERVED (helper ordering) | #7/S0→S1 | E0; VRAM/text source |
| HREC-HEX / HEX | `16_hex_display.md` §§5–7,10,12 | `drivers/hex_display.c`, `include/hex_display.h` | 기존 CTRL/packing 정합; S0 시점 monitor readback용 RAW getter 없음; S4-A에서 좁은 범위로 추가했다. | P10 shadow ownership; 읽을 수 있는 21-bit RAW bank. | S4-A getter 구현/시험 완료; 과거 P10 설명 조정은 연기. | VERIFIED_ALIGNED (existing API/getters, host/RTL); physical evidence NOT_RUN | #7/S0→S1→S4-A | E0; HEX source; E1 §8.3; S4-A §10.3 host/RTL |
| HREC-SW / SW | `17_sw.md` P04 note | `drivers/sw.c`, `include/sw.h` | 과거 target/unimplemented 본문과 active note 불일치. | Synchronized dedicated 10-bit slot8 input. | 본문은 이후 조정; static input 유효. | IMPLEMENTATION_ACCEPTED_DOC_STALE; VERIFIED_ALIGNED (API) | #7/S0→S1 | E0; SW source |
| HREC-LED / LED | `18_led.md` P04 note | `drivers/led.c`, `include/led.h` | 옛 본문에 APB_LED 부재/LED9 reset 소유권 잔존. | Dedicated 10-bit slot9 output latch/readback. | 설명은 이후 조정; 물리 evidence 구분 유지. | IMPLEMENTATION_ACCEPTED_DOC_STALE; VERIFIED_ALIGNED (API) | #7/S0→S1 | E0; LED source |
| HREC-AES / AES-GCM | `14_aes_gcm.md`; firmware AES rules | `drivers/aes_gcm.c`, `include/aes_gcm.h` | Baseline cleanup 미완료로 health dependency가 될 수 없음. | 기존 owning contract; health EXCLUDED_PENDING_CLEANUP. | 별도 후속 cleanup/provider 승인; 여기서 AES operation 없음. | CLEANUP_PENDING | #7/S0→S1 | E0; accepted scope; E1 §2 |
| HREC-BUILD / build | `19_firmware_contract.md` memory contract | `firmware/README.md`, `scripts/firmware/build_fw.sh`, `bsp/linker.ld` | README의 fallback은 script에 없음; linker GPIO/JOYSTICK comment stale. | 외부 RUN_ROOT 필수; 16 KiB/32 KiB 용량 유지. | S1 README fallback 수정; linker comment 조정은 연기, service/image fit은 S2–S5 검증. | FW_STALE (S0 README finding); OBSERVED (linker debt) | #7/S0→S1 | E0; build/linker source; E1 README |
| HREC-APP / application role | `19_firmware_contract.md`; 이 spec §1 | `apps/final_main.c`; firmware/top README | 역사적 RC-car app의 canonical-vs-demo 분리 표시 부재. | 유지하는 외부 시스템 demo; 미래 standalone soc_health_main. | S1에 역할/link 문서화; 이후 구현 및 통합 조정 pending. | CLEANUP_PENDING (S0 role finding; S1 documentation disposition recorded) | #7/S0→S1 | E0; accepted scope; E1 role entries |

### 12.3 연기한 문서 및 확장 규칙

`08_vga.md`, `09_uart.md`, `10_timer.md`, `11_gpio.md`, `12_gsensor.md`, `14_aes_gcm.md`, `15_adc_joystick.md`, `16_hex_display.md`, `17_sw.md`, `18_led.md` 및 companion의 광범위 재작성과 관련 없는 firmware-contract section/linker 과거 comment 조정은 연기한다. 지금 firmware contract에는 historical/new-health entry만 추가한다. 이 ledger는 `baseline_cleanup.md`를 대체하거나 기존 requirement status를 변경하지 않는다.

이후 IP 추가에는 production API, evidence 강도, bounded 실패 동작, 독립 oracle 및 시험을 명시한 후 승인에 따라 양쪽 언어 contract/tracker를 갱신한다. 조정 시 origin, 이전 status, 최종 조치 및 evidence를 보존한다. AES 참여에는 별도 승인 cleanup/provider 작업이 선행되어야 하며 placeholder가 미래 범위 확장을 암시하지 않는다.

### 12.3 S2 정합성 범위

S2 기반 구조 작업에서 새로운 spec/FW 불일치를 발견하지 않았다. 위 S0/S1 ledger는 peripheral/cleanup 부채를 닫지 않고 유지한다. S2는 §10.1만 구현하며 hardware provider를 runtime verified로 승격하지 않는다.

### 12.4 S3 정합성 범위

S3에서 새로운 owning spec/FW 불일치를 발견하지 않았다. 기존 API를 사용하며 peripheral RTL/driver, ADC ABI 또는 과거 cleanup ledger는 변경하지 않았다.

### 12.5 S4-A 정합성 범위

새로운 owning spec/FW 불일치는 발견하지 않았다. HREC-HEX는 S0 origin을 보존하며 승인된 getter 구현/host/RTL 검증을 기록한다. 관련 없는 역사적 API 설명이나 physical acceptance는 종결하지 않는다.

### 12.6 S4-B 정합성 범위

| ID / IP | Source requirement | S4-A에서 관측한 gap | 좁은 S4-B 조치 | Status / evidence |
|---|---|---|---|---|
| HREC-OBS-SEQ / UART, GSEN, ADC observer input | S4-B common-format SEQ 및 frozen-only text | Actual qualified token은 live에만 있고 copied 성공 detail은 baud=434/0/FRAME_COUNT라 실제 SEQ를 표시할 수 없었다. | 성공 detail에만 qualified sequence 기록; core ABI/qualification/failure 의미 보존. ADC FRAME_COUNT baseline은 provider-local 유지. | IMPLEMENTED_HOST_RTL_VERIFIED; S4-B finding 및 실제 provider→snapshot→formatter assertion; owner accepted at S4-B; S5 closure review pending. |

다른 owning spec/cleanup history는 조정하지 않는다. 이 finding은 peripheral RTL, physical acceptance, C4 또는 P08B STOP gate를 재개하지 않는다.

### 12.7 S5 Issue #7 정합성 disposition

위 S0/S1 finding과 원래 status는 이력으로 보존한다. 아래는 Issue #7만의 현행 status/evidence이며 broad owning-spec debt 또는 physical/runtime acceptance를 종결하지 않는다.

| ID | Current scoped status | S0–S5 disposition / evidence |
|---|---|---|
| HREC-APP | VERIFIED_ALIGNED (Issue #7 application-role split) | S1 역할 문서 및 구현된 canonical soc_health_main; historical RC-car final_main source 보존. |
| HREC-BUILD | VERIFIED_ALIGNED (health build/README); OBSERVED (historical linker comments) | S5 fresh RV32I build/size/symbol 감사 및 display_smoke image byte 일치; 관련 없는 linker 설명 부채 유지. |
| HREC-UART | VERIFIED_ALIGNED (health loop/observer); IMPLEMENTATION_ACCEPTED_DOC_STALE (old owning prose) | S3/S4-B 승인 및 S5 host/real serial RTL: UART0→UART1 RX qualification; UART1 TX observer 전용. |
| HREC-GPIO | VERIFIED_ALIGNED (owned pair health); IMPLEMENTATION_ACCEPTED_DOC_STALE (historical prose) | S4-A 승인; S5 host fault 및 simulated GPIO0→1 jumper의 real RTL; physical jumper NOT_RUN. |
| HREC-GSENSOR | VERIFIED_ALIGNED (API/health progression) | S3 승인 및 S5 host/RTL advancing coherent CAPTURE/read/RELEASE; physical sensor NOT_RUN. |
| HREC-ADC | VERIFIED_ALIGNED (v2 API/health); IMPLEMENTATION_ACCEPTED_DOC_STALE (owning narrative) | S3 승인; S5 C2/C3 및 health host/RTL freshness/validity/error; C4 pending 유지. |
| HREC-JOY | VERIFIED_ALIGNED (pure model/health); OBSERVED (compatibility wrapper debt) | S5 raw HOLD/calibration 독립 oracle 및 C3 policy boundary; wrapper 한계 유지. |
| HREC-VGA | VERIFIED_ALIGNED (health owner/dashboard); IMPLEMENTATION_ACCEPTED_DOC_STALE (historical waits); OBSERVED (legacy helper ordering) | S4-B 승인; S5 full raster/back-bank/fresh VSYNC/SWAP/DONE 및 N 불변성; monitor NOT_RUN. |
| HREC-HEX | VERIFIED_ALIGNED (API/getters/health) | S4-A 승인; S5 P10 functional/shadow 및 shared-SW host/RTL; physical illumination NOT_RUN. |
| HREC-SW | VERIFIED_ALIGNED (API/health); IMPLEMENTATION_ACCEPTED_DOC_STALE (old owning prose) | S5 captured synchronized 10-bit input 및 shared generation 검사; physical switch NOT_RUN. |
| HREC-LED | VERIFIED_ALIGNED (API/health); IMPLEMENTATION_ACCEPTED_DOC_STALE (old owning prose) | S5 captured SW mirror/latch oracle; physical mapping NOT_RUN. |
| HREC-AES | CLEANUP_PENDING; EXCLUDED_PENDING_CLEANUP | AES 실행/provider 없음; 별도 cleanup 승인 필요. |
| HREC-OBS-SEQ | VERIFIED_ALIGNED (accepted successful diagnostic payload, host/RTL only) | S4-B 사용자 승인: UART/GSEN/ADC 성공 detail은 qualified 32-bit seq; S5 exact eight-digit/upper-bit 검사. |
| HREC-CPU / HREC-TIMER | Original scoped status/debt retained | Startup/trap 또는 legacy timer-wait 변경 없음; health bounded service만 검증, CPU execution NOT_RUN. |
