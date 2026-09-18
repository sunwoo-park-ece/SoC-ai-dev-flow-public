# P08B VGA / VRAM 명세

> **상태:** 현재 활성 계약. 영문 [`../08_vga.md`](../08_vga.md)가 정본이며, 이 문서는 의미적으로 동기화된 한국어 동반 문서다.
>
> **검토 소스 앵커:** `f28e95df2eafcb939e04ffaca728c44f74c90612`. 기능 범위 승인이지 릴리스 선언이 아니다.

## 1. 상태와 범위

활성 디스플레이 주변장치는 `AMBA_SoC_TOP`에 연결된 `AHB_VRAM_DUAL_BUFFER`다. 640 x 480, 1-bpp 이중 버퍼 프레임버퍼와 VGA 타이밍, 스왑 제어, 하드웨어 클리어 엔진을 제공한다.

동결 소스의 `VGA-001`부터 `VGA-006`까지는 소유자가 기능 범위를 승인했고 검증되었다. 이는 Clean Baseline 릴리스 완료가 아니다. 정적 CDC, 전체 STA, 보드 경고 처분, 리셋 윈도 분석, 프로그래머 식별은 별도로 열려 있다. 휴면 APB 소스 처분인 `VGA-007`도 OPEN이다.

공개 증적은 [`reports/evidence/vga-hwclear/`](../../reports/evidence/vga-hwclear/summary.md), 엔지니어링 사례는 [CS-009](../../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md)에 있다.

## 2. 현재 활성 계약

### 2.1 구조와 저장소

`AHB_VRAM_DUAL_BUFFER`는 AHB 주변장치이며 휴면 `APB_VGA_Top`가 아니다. 각 프레임버퍼 뱅크는 9,600개의 32-bit 워드(38,400 bytes)로 640 x 480 1-bpp 픽셀을 나타낸다. VGA 픽셀 판독기는 표시 뱅크를 소유하고, 승인된 CPU 쓰기와 동작 중인 클리너는 반대 뱅크를 사용한다.

### 2.2 정규 주소와 접근 정책

| 주소 | 접근 | 계약 |
|---|---|---|
| `0x2000_0000`–`0x2000_95FF` | 정렬된 32-bit 쓰기 전용 | 현재 쓰기 가능한 백 버퍼. |
| `0x2001_0000` | read / bit 0 W1C | `VRAM_STATUS`. |
| `0x2001_0004` | write | `VRAM_CONTROL` 명령. |
| 그 밖의 로컬 주소, 프레임버퍼 읽기, subword/비정렬 프레임버퍼 접근 | ERROR | 데이터 쓰기와 명령 부작용이 없다. |

위 표만 소프트웨어 아키텍처 주소다. 더 넓은 fabric 선택이나 과거 로컬 별칭은 계약에 포함되지 않는다.

### 2.3 AHB 응답과 동작 수락

수락된 요청은 문서화된 ready/response 순서로 완료한다. 대상 뱅크가 busy이거나 쓸 수 없어 수락할 수 없는 요청은 2-cycle AHB ERROR를 받는다. 거절된 요청은 프레임버퍼 write enable을 올리거나 동작을 시작/변경해서는 안 된다.

클리너 동작은 한 번에 하나만 outstanding이다. clear 시작 시 대상 뱅크를 래치하며, 뒤의 표시 뱅크 변경은 그 동작을 다른 뱅크로 돌릴 수 없다. 스왑은 정의된 VSync 경계에서만 보인다. 소프트웨어는 새 소유권에 의존하기 전에 관련 상태를 기다려야 한다.

### 2.4 제어와 상태

`VRAM_CONTROL`은 활성 RTL이 구현한 clear, swap, combined 명령을 낸다. `VRAM_STATUS`는 live `BUSY`/`READY`와 sticky 완료 이벤트를 보고한다. bit 0은 W1C이며 1을 쓰면 이벤트를 확인하고 0을 써서는 지워지지 않는다. set/clear 우선순위와 reset 동작은 RTL/DV 행렬로 결정적이어야 한다.

## 3. 인터페이스·레지스터·타이밍

프레임버퍼 워드 인덱스는 `0..9599`다. 성공한 하드웨어 clear는 래치된 대상 뱅크의 정확히 9,600 워드를 쓴다. 픽셀은 선형 1-bpp 래스터 순서이며 VGA 타이밍 생성기 아래 선택된 표시 뱅크가 흑백 RGB를 낸다.

CPU와 VGA는 서로 다른 클록 도메인이다. 이 기능 계약은 정적 CDC 완료를 주장하지 않으며, 타이밍 설명도 전체 post-route STA 완료를 주장하지 않는다.

## 4. 불변식과 오류 동작

- 정규 프레임버퍼 쓰기는 쓰기 가능한 뱅크만 변경한다.
- 거절·미지원·읽기·subword·비정렬 프레임버퍼 접근에는 쓰기 부작용이 없다.
- 클리너는 수락 후 대상 뱅크를 바꾸지 않는다.
- 표시 이미지는 정의된 스왑 경계에서만 뱅크가 바뀐다.
- 완료는 W1C 확인 전까지 관측 가능하며, BUSY와 READY는 IDLE-high 레벨 추론이 아닌 live 상태다.
- 정확한 clear 횟수는 RTL/DV 속성이다. 보드 사진은 흑백 화면 전이를 뒷받침할 수 있지만 9,600개 개별 쓰기를 입증할 수 없다.

## 5. 수용 기준

| ID | 기준 | 증적 종류 |
|---|---|---|
| `VGA-AC-01` | 정규 aperture와 invalid-gap 동작이 결정적이다. | Directed RTL/DV |
| `VGA-AC-02` | 미지원 또는 미수락 트래픽은 부작용 없이 ERROR를 낸다. | Directed RTL/DV |
| `VGA-AC-03` | busy 소유권, swap, clear-target 래치가 원자적이다. | Directed RTL/DV |
| `VGA-AC-04` | 완료는 결정적 순서의 sticky W1C다. | Directed RTL/DV 및 firmware 실행 |
| `VGA-AC-05` | 수락된 clear마다 래치된 뱅크의 정확히 9,600 워드를 쓴다. | Directed RTL/DV |
| `VGA-AC-06` | 하드웨어가 예상 clear/swap 화면 전이를 보인다. | 보드 사진 |
| `VGA-AC-07` | combined/no-write swap이 예상 화면 결과를 보인다. | 보드 사진 |
| `VGA-AC-08` | 보드 운용자가 실행 이미지를 승인했다. | 보드 관측 |

## 6. 현재 요구사항 상태

| 요구사항 | 상태 | 근거 |
|---|---|---|
| `VGA-001` | VERIFIED | 정규 decode/boundary directed test. |
| `VGA-002` | VERIFIED | write-only/error DV, 소스 검토, firmware build. |
| `VGA-003` | VERIFIED | contention/no-side-effect 및 CPU fault-path DV. |
| `VGA-004` | VERIFIED | clear-only, combined, overlap, target-latch DV. |
| `VGA-005` | VERIFIED | W1C ordering/collision DV 및 firmware 실행 경로. |
| `VGA-006` | 기능 범위 VERIFIED | exact-count RTL/DV와 보드 가시 smoke 증적. STA/CDC 완료는 아님. |
| `VGA-007` | OPEN | 휴면 `APB_VGA_Top` 처분을 미룸. |

실행별 해시, 도구 결과, 사진 해시, 한계는 규범 계약이 아닌 [증적 result](../../reports/evidence/vga-hwclear/result.json)에 보존한다.

## 7. 승인 대상과 이연 작업

승인 대상은 위 동결 소스 동작이다. 다음은 이 수용 범위 밖이다.

| ID | 상태 | 이유 |
|---|---|---|
| `CDC-001` | NOT_RUN / unresolved | 정적 CDC sign-off 없음. |
| `STA-001` | IN_PROGRESS | 내부 STA는 SCOPED_PASS 한정이며 전체 완료가 아님. |
| `STA-002` | BLOCKED | 보드/I/O electrical timing 소유권 미해결. |
| VGA/ADC warnings | OPEN | 두 경고의 명시 처분 필요. |
| Reset window | known risk | 추가 reset-domain 분석 필요. |
| Programmer identity | unavailable | 프로그래머 식별 증적 미수집. |

## 8. 추적성

| 계약 영역 | 소스와 증적 |
|---|---|
| 활성 주변장치와 cleaner | `rtl/video/vram/AHB_VRAM_DUAL_BUFFER.v`, `rtl/video/vram/HW_Cleaner.v` |
| firmware 인터페이스 | `firmware/include/vram.h`, `firmware/drivers/vram.c` |
| directed verification | `verification/directed/vga/` |
| 요구사항 추적기 | [`../baseline_cleanup.md`](../baseline_cleanup.md) |
| 보드 증적 | [`reports/evidence/vga-hwclear/`](../../reports/evidence/vga-hwclear/summary.md) |
| 엔지니어링 사례 | [CS-009](../../docs/engineering/CS-009-p08b-vga-hwclear-w1c.md) |

## 부록 A. 정리 전 역사 메모

과거 기준선의 permissive alias, fixed-success 응답, immediate/live-bank 가정, level식 완료 해석은 역사적 맥락일 뿐 현재 계약으로 사용해서는 안 된다.
