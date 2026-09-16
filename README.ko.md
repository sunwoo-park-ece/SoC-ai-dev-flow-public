# SoC AI 개발 플로우

이 저장소는 개인 FPGA SoC 프로젝트의 **공개 가능한 소스 기준 저장소**다. 확정된 사양, 직접 작성한 RTL/FW, 고지와 함께 재배포 가능한 오픈소스 RTL, 공개 검증 소스, 정제된 보고서를 보관한다.

표준 엔지니어링 환경은 WSL Ubuntu + Codex다. RTL/FW 구현, Verilator 검사, 벤더 CLI 실행, ModelSim/XSim 시뮬레이션, 결과 분석과 엔지니어링 보고서 작성은 이 환경에서 수행한다. Antigravity는 확정 사양을 기준으로 독립 DV를 작성한다. Windows Work는 검토가 끝난 근거를 받아 포트폴리오, PDF/PPT, 면접 자료를 다듬고 필요한 경우 GUI 전용 벤더 작업을 보조하지만, 표준 빌드나 엔지니어링 보고서의 소유자는 아니다.

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
- [Git 작업 흐름](docs/GIT_WORKFLOW.ko.md)
- [역할 분담](docs/AGENT_ROLES.ko.md)
- [현재 상태](docs/status/current_status.md)

## 현재 상태

현재 저장소는 진행 중인 소스 snapshot이며 Clean Baseline v1이나 벤더 IP 없는 FPGA bitstream build가 아니다. Phase 4A-P08B는 Gate 0에서 정지했다. CPU/AHB precise store-access-fault 경로는 통과했지만 현재 firmware에는 승인된 safe trap endpoint가 없다. P08B production VGA 구현은 시작하지 않았다. [현재 상태](docs/status/current_status.md)를 참고한다.

CPU와 AES-GCM 오픈소스 의존성은 라이선스와 함께 포함한다. 공개 시뮬레이션 모델은 비공개 Intel/Altera 메모리·PLL·ADC IP의 인터페이스를 대체하고, VGA 동기 및 GSensor helper는 사양 기반으로 다시 구현했다. 비공개 Quartus 빌드는 동일한 공개 RTL을 직접 참조한다. Benchmark/Dhrystone 소스는 의도적으로 제외한다. 향후 성능보고서를 공개할 때는 별도 검토를 거치고 공식 Dhrystone 2.1과 프로젝트의 Dhrystone-style workload를 구분해야 한다. [Quartus 빌드 프로필](fpga/quartus/README.md)과 [모델 계약](docs/models/PORTABLE_MODEL_CONTRACTS.md)을 참고한다.

프로젝트 직접 작성물은 [Apache License 2.0](LICENSE)을 적용하며, 서드파티 파일은 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 기록된 각 라이선스를 유지한다.
