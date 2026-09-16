# VGA·HEX·LED 진단 펌웨어 v1

영문 [display_smoke.md](display_smoke.md)가 authoritative 문서입니다.

FPGA RTL·핀·타이밍 제약은 유지하고 `display_smoke.c` 펌웨어의 IMEM·DMEM만 사용합니다. PLIC는 미통합입니다.

## 정상 동작

1. 시작할 때 HEX에 `b00701`이 잠깐 표시되고 LED 10개가 모두 켜집니다.
2. VGA에 **VGA HEX LED TEST V1**, STEP, HEX 예상값, LED MASK, FRAME, LED 상태 상자 10개가 표시됩니다.
3. HEX는 `000000 → 111111 → … → 999999 → AAAAAA → … → FFFFFF`를 반복합니다.
4. 0~9 단계에서는 LED0부터 LED9까지 하나씩 켜집니다. A/E는 전체 점등, B/F는 전체 소등, C/D는 교차 점등입니다.
5. VGA 상자는 왼쪽부터 LED0~LED9를 나타냅니다. 물리 LED와 같은 패턴인지 확인하세요.

진행 속도는 소프트웨어 지연 루프와 CPU 클록에 따라 달라집니다. LoRa 상대 장치·ADC 입력·타이머 주변장치·인터럽트 없이 실행됩니다. VRAM은 소프트웨어로 지우므로 기존 데모의 하드웨어 클리어 엔진 검증은 포함하지 않습니다.

## 오류 표시

| HEX 표시 | 의미 |
|---|---|
| `E1000n` | VGA VSYNC 플래그 대기 시간 초과 |
| `E2000n` | GPIO 출력 레지스터 읽기 불일치 |
| `E3000n` | HEX 값 레지스터 읽기 불일치 |

`n`은 현재 단계입니다. VSYNC에 문제가 있어도 MMIO 접근이 완료되면 HEX·LED 순환은 계속됩니다. `b00701`에 계속 멈추면 첫 프레임 처리를 끝내지 못한 상태로 알려주세요. 레지스터 검증만으로 실제 핀 동작이 확인되는 것은 아닙니다.

## 공개 snapshot 범위

첫 public source snapshot은 호스트 테스트와 `display_smoke` 펌웨어 빌드만 지원합니다. 이미지 선택 도구, 전체 vendor build wrapper, SOF, 보드 결과는 공개하지 않습니다. 따라서 vendor 재생성과 실제 보드 acceptance는 사용자 수행 범위이며, 이 snapshot의 재현 가능한 공개 증거로 주장하지 않습니다.

향후 보드 검증에서는 화면 제목, FRAME 증가, 화면의 HEX 예상값과 실제 HEX 일치, LED 상자와 실제 LED 일치를 확인하고 오류 코드나 마지막 단계를 기록해야 합니다. 현재 snapshot에는 보드 결과가 포함되지 않습니다.

호스트 검증은 정상 순환·프레임버퍼 범위·VSYNC 시간 초과·레지스터 오류 주입을 확인합니다. CPU/RTL 시뮬레이션이나 실제 보드 검증을 대신하지 않습니다. 기존 데모의 동작 차이에 대한 원인은 아직 확정하지 않았습니다.
