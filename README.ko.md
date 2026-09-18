# SoC AI 개발 플로우

이 저장소는 개인 FPGA SoC 프로젝트의 **공개 가능한 소스 기준 저장소**다. 확정된 사양, 직접 작성한 RTL/FW, 고지와 함께 재배포 가능한 오픈소스 RTL, 공개 검증 소스, 정제된 보고서를 보관한다.

표준 엔지니어링 환경은 WSL Ubuntu + Codex다. RTL/FW 구현, Verilator 검사, 벤더 CLI 실행, ModelSim/XSim 시뮬레이션, 결과 분석과 엔지니어링 보고서 작성은 이 환경에서 수행한다. Antigravity는 확정 사양을 기준으로 독립 DV를 작성한다. Windows Work는 검토가 끝난 근거를 받아 포트폴리오, PDF/PPT, 면접 자료를 다듬고 필요한 경우 GUI 전용 벤더 작업을 보조하지만, 표준 빌드나 엔지니어링 보고서의 소유자는 아니다.

## Hardware Overview

현재 FPGA baseline은 5단계 파이프라인 RV32I CPU를 중심으로 AHB-Lite 버스 패브릭, 전용 메모리 및 디스플레이 서브시스템, APB 주변장치 서브시스템을 통합한 커스텀 SoC입니다.

![Current SoC Block Diagram](docs/assets/images/soc_block_diagram.png)

> **그림의 범위:** 이 블록 다이어그램은 상위 수준의 아키텍처 개요를 제공합니다. 표준 아키텍처, 메모리 맵 및 인터페이스 계약은 [`spec/`](spec/README.md) (특히 [`spec/00_soc_architecture.md`](spec/00_soc_architecture.md), [`spec/01_memory_map.md`](spec/01_memory_map.md), [`spec/08_vga.md`](spec/kor/08_vga.ko.md))에 정의되어 있습니다. 그림과 사양서의 세부 내용이 다를 경우 사양서가 우선합니다.
>
> *현재 P08B 상태 참고:* 블록 다이어그램은 개략적인 기능 토폴로지를 나타냅니다. 동결된 P08B 실제 RTL에서는 AHB 듀얼 VRAM 서브시스템 내에 전용 하드웨어 클리어 엔진(`HW_Cleaner`), W1C(Write-1-to-Clear) 상태 동기화(`VSYNC_EVENT`, `OP_DONE`, `OP_ABORT`), `DOMAIN_READY` 핸드셰이크, 그리고 2-cycle `HRESP=ERROR` 버스 예외 응답 경로가 통합되어 있습니다. PLIC, AXI, DMA, 외부 SDRAM 등은 구현 예정 로드맵 단계이며 현재 베이스라인에는 포함되어 있지 않습니다.

주요 하드웨어 서브시스템:
- **RV32I 5단계 CPU 코어:** 로컬 명령어 메모리(IMEM)와 AHB 스타일 로드/스토어 메모리 접근 인터페이스를 갖춘 In-order 5단계 파이프라인 CPU로, 정밀한 버스 오류 트랩(`mcause=5/7`)을 지원합니다.
- **AHB 데이터 메모리 (DMEM):** AHB 패브릭에 직접 연결된 32 KiB 온칩 데이터 메모리.
- **VGA / 듀얼 VRAM 디스플레이 서브시스템 (`AHB_VRAM_DUAL_BUFFER`):** 독립적인 25 MHz 픽셀 클럭(`pclk_25`)으로 구동되는 640×480 @ 60 Hz 1-bpp 단색 비트맵 파이프라인으로, 물리적 듀얼 뱅크 혼합 폭 BRAM, `(799,524)->(0,0)` 프레임 랩 스왑, 9,600 워드 자동 하드웨어 클리어 엔진, W1C 상태 레지스터를 포함합니다.
- **AHB-to-APB 브리지:** `0x1000_0000`–`0x1000_FFFF` 주변장치 영역을 디코딩하여 AHB 트랜잭션을 APB 버스 전송으로 변환합니다.
- **APB 주변장치:** UART (115200 bps), GPIO (푸시버튼, 슬라이드 스위치, LED), 시스템 타이머 (64비트 마이크로초 카운터), ADXL345 G-센서 인터페이스, ADC (아날로그 조이스틱 / 온도 센서), AES-GCM 128비트 암호화 가속기, 6자리 7세그먼트 HEX 디스플레이 컨트롤러.

## Hardware Demos

실제 FPGA 보드 시연 영상, 동작 캡처 및 개발 기록은 프로젝트 소유자의 YouTube 채널에 공개되어 있습니다:

- **YouTube — FPGA / SoC / Embedded Project Demos:** https://www.youtube.com/channel/UC9DlYapKa23KqJkNadjSObQ

시연 영상 및 캡처 사진은 물리적 DE10-Lite FPGA 보드에서의 정상 동작을 확인하는 보조적인 시각적 증거입니다. 모든 기술적 주장과 검증 결과는 저장소 내 공식 엔지니어링 패키지를 통해 추적 가능합니다:
- **P08B VGA 하드웨어 클리어 및 W1C 상태 통합:** 엔지니어링 사례 분석 [CS-009](docs/engineering/CS-009-p08b-vga-hwclear-w1c.md) 및 공개 증적 [P08B-VGA-EV-01](reports/evidence/vga-hwclear/summary.md) 수록.
- **정확한 9,600회 HW Clear 검증:** 자율적인 9,600 워드 프레임버퍼 클리어 및 원자적 버퍼 스왑 시퀀스는 방향성 RTL 시뮬레이션 어설션([`tb_p08b_vga.sv`](verification/directed/vga/tb_p08b_vga.sv))과 다중 사이클 보드 사진 증적([`reports/evidence/vga-hwclear/media/`](reports/evidence/vga-hwclear/))을 통해 교차 검증되었습니다.

*시각적 데모는 화면 표시 동작을 보여줄 뿐이며, 내부 버스 프로토콜 정합성, 클럭 도메인 교차(CDC) 신호 무결성, 정적 타이밍 분석(STA) 결과를 증명하지 않습니다. 모든 기술적 계약은 시뮬레이션 어설션, 타이밍 분석 보고서, 검증 증적에 의해서만 규정됩니다.*

## 구현 예정 Roadmap

본 로드맵은 베이스라인 구축 이후 단계적 SoC 고도화를 위한 엔지니어링 개발 계획입니다. 이는 **향후 진행할 계획(Working Plan)이며 현재 구현 완료된 기능 목록이 아닙니다**:

1. **PLIC 및 CPU 외부 인터럽트 경로:**
   - 플랫폼 레벨 인터럽트 컨트롤러(PLIC) 게이트웨이 및 레지스터 맵 확정.
   - 주변장치 인터럽트 신호(UART, 타이머, GPIO, 디스플레이 VSync)를 CPU 트랩 경로에 통합.
   - CSR 인터럽트 처리, 벡터/직접 분기, ISR 디바이스 드라이버 검증.
2. **AXI 인터커넥트 마이그레이션:**
   - 타깃 AXI4 버스 패브릭 및 다중 마스터 중재 정책 도입.
   - AXI-to-APB 브리지를 통해 기존 APB 주변장치 서브시스템 유지.
   - CPU 데이터 패스 및 디스플레이 마스터를 AHB-Lite에서 AXI로 점진적 전환.
3. **다채널 DMA 및 AXI 버스 중재:**
   - 구성 가능한 채널을 갖춘 AXI 마스터 DMA 엔진 구현.
   - 하드웨어 스케줄링, 라운드로빈/우선순위 중재 및 소프트웨어 제어 레지스터 정의.
   - 버스 백프레셔, 전송 경합, 완료 인터럽트 및 에러 응답 검증.
4. **외부 SDRAM 서브시스템:**
   - 물리적 패드 제약조건 및 리프레시 컨트롤러를 포함한 SDR SDRAM 인터페이스 추가.
   - AXI 메모리 맵에 SDRAM 컨트롤러 통합.
   - 물리적 타이밍 클로저, 버스트 전송 대역폭, 행/뱅크 접근 지연 시간 검증.
5. **DMA 스테이징 및 버퍼 데이터 패스:**
   - CPU DMEM, VRAM, DMA, 외부 SDRAM 간의 구조적 내부 버퍼링 경로 정의.
   - 프레임 생성 및 주변장치 스트리밍 시 불필요한 CPU 메모리 복사(memcpy) 오버헤드 제거.
6. **데이터 캐시 (D-Cache) 컨트롤러:**
   - 외부 메모리 인터페이스 안정화 후 세트 연관(Set-Associative) 데이터 캐시 아키텍처 도입.
   - 캐시 라인 리필, 라이트 정책, 무효화 및 플러시 메커니즘 구현.
   - DMA 상호작용 및 소프트웨어 캐시 유지보수 명령에 대한 일관성 계약 정의.
7. **시스템 레벨 통합 및 성능 클로저:**
   - 오픈소스 회귀 테스트벤치 및 독립 UVM 검증 커버리지 확대.
   - 이종 클럭 CDC 경로, 리셋 동기화, 터미널 에러 전파 정리.
   - 실제 하드웨어 Fmax, 리소스 사용량, 메모리 대역폭, IPC 벤치마크 지표 측정.

*주의: 본 로드맵은 실무 개발 계획입니다. 각 기능은 표준 개발 수명 주기(명세서 ➔ RTL/펌웨어 구현 ➔ 독립 DV / 시뮬레이션 ➔ FPGA 합성 및 타이밍 클로저 ➔ 보드 측정 증적 ➔ 마일스톤 리뷰)를 통과한 후에만 공식 활성 베이스라인으로 승격됩니다.*


## 저장 경계

```text
$PUBLIC_REPO  공개 가능한 spec/RTL/FW/verification 및 정제 보고서
$VENDOR_ROOT 라이선스·생성물이 포함된 비공개 Quartus/Vivado 프로젝트
$RUN_ROOT    빌드, 로그, 파형, 원본 리포트, 임시 산출물
export/      다른 환경으로 넘길 검토 완료 산출물
```

비공개 전체 FPGA 빌드는 다음 계약을 따른다.

```text
PUBLIC_REPO + PRIVATE_VENDOR_PROJECT + LOCAL_ENV + RUN_DIR
= PRIVATE FULL FPGA BUILD
```

Phase 3에서 구현한 공개 검증 계약은 다음과 같다.

```text
PUBLIC_REPO + PUBLIC BEHAVIORAL MODELS
= OPEN LINT / SIMULATION / ELABORATION
```

완전한 벤더 GUI 프로젝트, 생성 HDL, 벤더 시뮬레이션 collateral은 공개하지 않는다. 자세한 내용은 [FPGA 경계](fpga/README.md), [서드파티 고지](THIRD_PARTY_NOTICES.md), [검증 현황](verification/README.md)을 참고한다.

## 시작 지점

- [사양](spec/README.md)
- [RTL](rtl/README.md)
- [펌웨어](firmware/README.md)
- [검증](verification/README.md)
- [스크립트](scripts/README.md)
- [보고서](reports/README.ko.md)
- [엔지니어링 사례](docs/engineering/README.md)
- [Git 작업 흐름](docs/GIT_WORKFLOW.ko.md)
- [역할 분담](docs/AGENT_ROLES.ko.md)
- [현재 상태](docs/status/current_status.md)

## 현재 상태

현재 저장소는 진행 중인 소스 snapshot이며 Clean Baseline v1이나 벤더 IP 없는 FPGA bitstream build가 아니다. 동결 P08B VGA 기능 범위(`VGA-001..006`)는 directed RTL/DV와 보드 가시 smoke 증적으로 owner accepted 상태지만 CDC/STA, 경고, reset-window, programmer identity, release 작업은 열려 있다. CPU trap-policy Gate 0은 startup `mtvec` 설치가 commit된 이후에만 scoped PASS이며, 그 이전 reset window는 알려진 미검증 위험으로 남아 있다. [현재 상태](docs/status/current_status.md)와 [CS-009](docs/engineering/CS-009-p08b-vga-hwclear-w1c.md)를 참고한다.

CPU와 AES-GCM 오픈소스 의존성은 라이선스와 함께 포함한다. 공개 시뮬레이션 모델은 비공개 Intel/Altera 메모리·PLL·ADC IP의 인터페이스를 대체하고, VGA 동기 및 GSensor helper는 사양 기반으로 다시 구현했다. 비공개 Quartus 빌드는 동일한 공개 RTL을 직접 참조한다. Benchmark/Dhrystone 소스는 의도적으로 제외한다. 향후 성능보고서를 공개할 때는 별도 검토를 거치고 공식 Dhrystone 2.1과 프로젝트의 Dhrystone-style workload를 구분해야 한다. [Quartus 빌드 프로필](fpga/quartus/README.md)과 [모델 계약](docs/models/PORTABLE_MODEL_CONTRACTS.md)을 참고한다.

프로젝트 직접 작성물은 [Apache License 2.0](LICENSE)을 적용하며, 서드파티 파일은 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 기록된 각 라이선스를 유지한다.
