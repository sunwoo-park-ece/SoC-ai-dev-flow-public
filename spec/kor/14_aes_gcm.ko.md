# Baseline SoC AES-GCM Accelerator Specification — 한국어 Companion

> **상태:** 현재 Baseline 기록 + Owner 승인 P13-01 TARGET (§24), 구현 및 Acceptance 전. 기존 Baseline 절은 관측값이며 Target 구현 완료를 의미하지 않는다.
>
> **정본 언어:** 영어. 이 문서와 `../14_aes_gcm.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
>
> **상위 명세:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. 목적

이 문서는 active FPGA baseline에 통합된 software-visible AES-GCM accelerator를 정의한다.

주요 범위는 다음과 같다.

- APB/MMIO register contract
- project-local APB wrapper와 third-party AES-GCM VHDL core의 경계
- AES-128 operation mode
- key / IV / sequence / AAD header / payload / tag formatting
- encrypt/decrypt command와 status semantics
- single-block payload length behavior
- firmware polling contract
- 보안 및 correctness limitation
- verification requirement
- 향후 AXI/DMA/PLIC 이전 baseline cleanup target

현재 블록은 **16-byte payload window를 갖는 single-operation, polling-controlled AES-128-GCM accelerator**이다. Streaming DMA crypto engine, secure key vault, multi-context accelerator, interrupt-driven peripheral은 아니다.

## 2. Active Architecture Boundary

```text
CPU
 |
 | AHB
 v
AHB -> APB bridge
 |
 +--> PSEL[4]
       |
       v
  apb_aes_gcm                  PCLK = 50 MHz
       |
       +-- project-local MMIO register / control FSM
       |
       +-- top_aes_gcm
             |
             +-- upstream-derived VHDL AES/GCM datapath
```

Canonical base:

```text
AES_GCM_BASE = 0x4004_0000
APB slot     = PSEL[4]
```

Active wrapper:

```text
rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v
```

Cryptographic VHDL core는 같은 `pipe0/` directory 아래에 있다.

Wrapper와 core는 모두 APB `PCLK` domain에서 동작하며 AES 내부 별도 CDC는 없다.

```text
PREADY = 1
```

이고 baseline에는 AES interrupt output이 없다.

## 3. Provenance / Ownership

VHDL AES-GCM core는 Apache-2.0 license의 다음 upstream project를 기반으로 한다.

```text
BLu85/AES-GCM-128-192-256-bits
```

Attribution/license 정보는 다음 파일에 유지한다.

```text
rtl/peripherals/aes_gcm/README.md
THIRD_PARTY_NOTICES.md
licenses/BLu85-AES-GCM-Apache-2.0.txt
```

Project-local 작업 범위는 active Verilog APB wrapper, MMIO programming model, operation sequencing, project-specific packet/AAD construction, firmware driver, SoC integration이다.

따라서 underlying AES-GCM algorithm VHDL core 전체를 본 프로젝트에서 직접 설계했다고 표현하면 안 된다.

## 4. Canonical Register Map

Wrapper는 `PADDR[7:2]`를 decode한다.

| Offset | Register | Access | Reset | 의미 |
|---:|---|---|---:|---|
| `0x00` | `NAME0` | R | constant | ASCII `"apb-"` |
| `0x04` | `NAME1` | R | constant | ASCII `"gcm "` |
| `0x08` | `VERSION` | R | constant | ASCII `"1.00"` |
| `0x0C` | `CTRL` | R/W command | `0` | start / enc-dec / clear status |
| `0x10` | `STATUS` | R | `0` | busy / done / tag-ok / error |
| `0x20..0x2C` | `KEY0..3` | R/W | `0` | 128-bit key |
| `0x30` | `NONCE_DIR` | R/W | `0` | `[31:8]` session nonce, `[7:0]` direction |
| `0x34` | `SEQ_HI` | R/W | `0` | sequence `[63:32]` |
| `0x38` | `SEQ_LO` | R/W | `0` | sequence `[31:0]` |
| `0x3C` | `LEN` | R/W | `0` | lower 16-bit payload length |
| `0x40..0x4C` | `PAYLOAD_IN0..3` | R/W | `0` | 128-bit input payload |
| `0x50..0x5C` | `TAG_IN0..3` | R/W | `0` | decrypt expected tag |
| `0x60..0x6C` | `PAYLOAD_OUT0..3` | R | `0` | 128-bit result |
| `0x70..0x7C` | `TAG_OUT0..3` | R | `0` | generated tag |
| `0x80..0x8C` | `HDR0..3` | R | `0` | AAD debug snapshot |

Word ordering은 register 번호가 증가할수록 MSB에서 LSB 방향이다.

```text
KEY = KEY0 || KEY1 || KEY2 || KEY3
```

PAYLOAD/TAG도 동일하다.

## 5. CTRL

```text
bit 0 START
bit 1 ENC_DEC
bit 2 CLR_STATUS
```

`START=1` write는 `BUSY=0`일 때 operation을 시작한다.

```text
ENC_DEC=0 -> encrypt
ENC_DEC=1 -> decrypt/authenticate
```

BUSY 중 다시 START하면 현재 operation을 restart하지 않고 `ERROR=1`을 set한다.

`CLR_STATUS=1`은:

```text
DONE
TAG_OK
ERROR
```

를 clear한다. BUSY나 key/input/output register는 clear하지 않는다.

현재 implementation에서는 CTRL에 write할 때마다 `enc_dec_reg`도 `PWDATA[1]`으로 갱신된다. 따라서 `CLR_STATUS` bit만 1로 쓰면 visible direction readback은 0으로 바뀐다. 이것은 operation 결과 자체에는 영향이 없지만 control/readback semantics cleanup 대상이다.

## 6. STATUS

```text
bit 0 BUSY
bit 1 DONE
bit 2 TAG_OK
bit 3 ERROR
```

`BUSY`는 accepted START부터 필요한 core result capture 완료까지 1이다.

`DONE`은 output capture까지 완료됐음을 의미하며 clear/reset 전까지 유지된다.

Encrypt 정상 완료 시 `TAG_OK=1`로 처리된다.

Decrypt에서는 generated tag와 `TAG_IN[127:0]`을 비교한다.

```text
match    -> TAG_OK=1
mismatch -> TAG_OK=0, ERROR=1
```

현재 ERROR source는 최소한:

- BUSY 중 START
- core ICB counter overflow
- decrypt tag mismatch

이다.

Bus error가 아니라 software polling status로 전달된다.

## 7. AES-128 / Key

Wrapper는 accepted operation마다:

```text
AES mode = AES-128
```

으로 고정한다.

```text
KEY[127:0]
 = KEY0 || KEY1 || KEY2 || KEY3
```

이며 upstream core의 256-bit key port 상위 128 bit에 배치되고 AES-128용 key-valid selector를 사용한다.

Upstream core가 다른 key size를 지원하더라도 baseline APB contract에서는 expose하지 않는다.

## 8. IV / Sequence

```text
NONCE_DIR[31:8] = session_nonce[23:0]
NONCE_DIR[7:0]  = DIR[7:0]
SEQ_HI          = SEQ[63:32]
SEQ_LO          = SEQ[31:0]
```

96-bit GCM IV:

```text
IV = NONCE_DIR || SEQ_HI || SEQ_LO
   = session_nonce[23:0] || DIR[7:0] || SEQ[63:0]
```

SEQ는 hardware auto-increment가 없으며 software가 관리한다.

동일 key에서 서로 다른 protected message에 동일 IV를 재사용하면 안 된다. IV uniqueness/replay policy는 향후 firmware/protocol contract가 소유한다.

## 9. Fixed 16-byte AAD Header

Project-specific AAD는 항상 16 bytes이다.

```text
AAD[127:0]
 = 16'hA55A
 || NONCE_DIR[31:0]
 || SEQ_HI[31:0]
 || SEQ_LO[31:0]
 || LEN[15:0]
```

START 시 이 header를 `HDR0..3`에 debug snapshot으로 저장한다.

현재 software가 임의 AAD buffer를 따로 제공하는 기능은 없다.

## 10. Payload / LEN

Payload window는 정확히 128 bits 한 block이다.

```text
PAYLOAD_IN0 || PAYLOAD_IN1 || PAYLOAD_IN2 || PAYLOAD_IN3
```

Baseline에서 유효한 LEN contract:

```text
0 <= LEN <= 16 bytes
```

- `LEN=0`: AAD-only operation, payload output zero 취급
- `LEN=1..15`: MSB 쪽부터 해당 byte 수만 valid
- `LEN=16`: 16 bytes 전체 valid

현재 active `bval_from_len()`은 explicit 0..15 case 이외에는 all-valid 16-byte mask를 반환한다. 따라서 `LEN>16`을 쓰면 data window는 16 bytes인데 AAD header에는 큰 LEN 숫자가 들어가는 이상한 상태가 가능하다.

그러므로 hardware validation 추가 전까지 software는 반드시:

```text
LEN <= 16
```

을 지켜야 한다.

Multi-block streaming은 지원하지 않는다.

## 11. Operation FSM

```text
START
  -> CORE_RESET
  -> KEY_PULSE
  -> IV_START
  -> WAIT_READY
  -> SEND_AAD
       |
       +-- LEN=0 -> PKT_END
       |
       +-- LEN!=0 -> SEND_DATA -> WAIT_CT -> PKT_END
  -> WAIT_RESULT
  -> DONE_PULSE
  -> IDLE
```

각 accepted operation마다 VHDL core soft-reset 후 AES-128 key load, IV load, 16-byte AAD 전달, optional 1-block payload 전달, GHASH packet terminate, result/tag capture 순서로 진행한다.

`WAIT_CT`는 delayed GCTR ciphertext/bval을 GHASH가 소비하도록 packet-valid를 1 cycle 추가 유지하기 위한 state이다.

Core output capture는 drive FSM과 독립적으로 수행되어 short valid pulse를 놓치지 않도록 설계되어 있다.

## 12. Encrypt Firmware Contract

```text
1. BUSY=0 확인
2. KEY0..3 설정
3. NONCE_DIR / SEQ_HI / SEQ_LO 설정
4. LEN / PAYLOAD_IN 설정
5. stale STATUS clear
6. CTRL.START, ENC_DEC=0
7. DONE polling
8. ERROR=0 확인
9. PAYLOAD_OUT read
10. TAG_OUT read
```

Encrypt에서는 TAG_IN이 verification에 사용되지 않는다.

## 13. Decrypt / Authenticate Contract

```text
1. BUSY=0 확인
2. KEY 설정
3. IV/SEQ 설정
4. LEN / ciphertext 설정
5. expected TAG_IN 설정
6. stale STATUS clear
7. CTRL.START, ENC_DEC=1
8. DONE polling
9. TAG_OK=1 && ERROR=0 확인
10. 그 이후에만 PAYLOAD_OUT을 authenticated plaintext로 사용
```

Hardware 내부에서는 tag verification 완료 전 plaintext output이 먼저 capture될 수 있다. Software trust boundary는 output register 존재 여부가 아니라 최종 `DONE/TAG_OK/ERROR`이다.

## 14. BUSY 중 Register Write

APB wrapper는 BUSY 중 일반 input register write를 막지 않는다.

Core-driving 주요 값은 START 시 internal register로 copy되지만, baseline software는 operation 동안 input set 전체를 immutable로 취급해야 한다.

특히 decrypt의 TAG comparison은 core tag 도착 시 wrapper의 `TAG_IN` 값을 사용하므로 BUSY 중 TAG_IN 변경은 금지한다.

```text
BUSY=1
-> KEY/IV/SEQ/LEN/PAYLOAD_IN/TAG_IN 변경 금지
-> 추가 START 금지
```

## 15. Reset

System/APB reset은:

- BUSY/DONE/TAG_OK/ERROR
- key register
- nonce/sequence/len
- input/output payload/tag
- debug header
- wrapper/core control state

를 0으로 초기화한다.

또한 wrapper가 operation마다 core soft reset을 발생시킨다.

AES는 별도 clock domain이 없다.

## 16. Security Limitation

현재 블록은 production hardened security boundary가 아니다.

주요 limitation:

```text
KEY register readback 가능
key가 overwrite/reset 전까지 MMIO에 남음
secure key vault 없음
privilege/access control 없음
nonce/sequence auto management 없음
anti-replay 없음
explicit zeroize command 없음
payload/tag MMIO 직접 read 가능
interrupt 없음
```

따라서 “secure key storage”나 전체 secure-channel architecture를 제공한다고 설명하면 안 된다.

## 17. APB Decode Limitation

Wrapper는 `PADDR[7:2]`만 decode하기 때문에 register map이 0x100-byte 주기로 repeat된다.

이 alias는 implementation artifact이며 canonical address가 아니다.

현재 Direct-APB Wrapper-local Unsupported Decoded Offset은 Read 0/Write 무시이나 Partial Decode로 등록된 Register에 Alias되는 경우는 제외한다. 이는 CPU Bridge가 비정규 Slot4 Offset을 차단하는 정책을 무효화하지 않는다.

AES Wrapper 자체에는 `PSLVERR`가 없고 Crypto/Program 오류는 STATUS로만 전달한다. 다만 현재 CPU→AHB/APB Bridge는 비정규 Slot4 Offset/Size를 AES PSEL 전에 차단하여 Two-cycle AHB ERROR를 반환한다. Direct-APB Wrapper Alias와 Direction 제한은 남는다.

Canonical firmware access는 aligned 32-bit MMIO를 사용한다.

## 18. Firmware Integration

Active driver:

```text
firmware/drivers/aes_gcm.c
firmware/include/aes_gcm.h
```

Driver는 key/IV/payload/tag programming, status clear, encrypt/decrypt start, DONE polling을 제공한다.

현재 normal sequence에서 firmware가 START 전에 stale status를 clear하는 것은 current RTL semantics와 맞는다.

다만 `aes_gcm_wait_done()`은 timeout 없는 busy loop이므로 production-facing path에서는 bounded timeout policy가 필요하다.

## 19. Verification Evidence Boundary

Legacy APB reference-model SoC test는 CPU/APB register sequence 및 fixed golden behavior를 확인하지만 실제 VHDL crypto core를 compile하지 않는다.

따라서 그 PASS만으로 active AES-GCM algorithm correctness를 증명할 수 없다.

`verification/legacy/` 아래 GHDL/direct-core 자료는 참고/역사 evidence이며 현재 baseline signoff로 자동 승격되지 않는다.

Major feature integration 전에는 active wrapper + active VHDL core를 함께 사용해 fresh AES-128-GCM KAT regression을 남겨야 한다.

AES-001은 User/Chat 승인에 따라 `VERIFIED`다. 실제 production APB wrapper/VHDL core에서 독립 oracle 기반 0·7·16바이트 encrypt/decrypt KAT가 통과했다. 상세 내부 보고서는 정제된 공개 AES evidence package가 승인될 때까지 `PRIVATE_LOCAL_EVIDENCE_REQUIRED`다. 다른 AES cleanup 행과 VER-006은 이 범위에 포함되지 않는다. 별개의 full-SoC mixed-language CPU compile 실패는 VER-001 증거로 보존한다.

## 20. Required Verification

최소 directed regression:

1. NAME/VERSION
2. reset values
3. KEY/IV/SEQ/PAYLOAD/TAG word ordering
4. AAD debug header
5. 96-bit IV
6. AES-128-GCM encrypt known-answer vector
7. decrypt/tag verify known-answer vector
8. modified tag rejection
9. LEN=0
10. LEN=1..16 전 범위
11. LEN>16 explicit rejection after cleanup
12. START while BUSY
13. CLR_STATUS
14. back-to-back operation
15. stale DONE/TAG_OK leakage 없음
16. core overflow/error
17. BUSY 중 register mutation
18. register alias/noncanonical access

Expected crypto value는 RTL 자체가 아니라 independent trusted implementation 또는 published vector에서 가져와야 한다.

## 21. Baseline Cleanup Targets

| Priority | Cleanup | 이유 |
|---|---|---|
| High | active wrapper/core fresh AES-128-GCM KAT | reference model PASS만으로 crypto core 증명 불가 |
| High | `LEN>16` explicit reject | 현재 out-of-range가 16-byte valid mask로 처리됨 |
| High | byte/word ordering independent-vector 검증 | protocol interoperability risk |
| High | decrypt trust contract hardening | TAG success 전 plaintext 사용 금지 |
| High | key zeroization policy | key가 readable MMIO에 남음 |
| Medium | BUSY 중 input write block/semantics 정의 | mid-operation ambiguity |
| Medium | CLR_STATUS와 ENC_DEC retained state 분리 | 현재 clear write도 direction readback 변경 |
| Medium | bounded firmware timeout | 무한 polling 방지 |
| Medium | AES Local Exact Decode 구현/검증 | CPU Bridge의 비정규 주소/크기 차단을 유지하고 승인된 Target은 Wrapper Alias를 제거하며 Direction 정책은 별도로 유지 |
| Medium | future PLIC AES interrupt contract | baseline polling-only |
| Medium | future DMA/streaming 별도 architecture | current one-block APB window |

## 22. Future AXI / DMA Boundary

향후 high-throughput crypto path가 필요하면 현재 register window를 억지로 multi-block protocol로 확장하기보다 새 spec에서 다음을 정의해야 한다.

```text
AXI ownership
DMA/descriptor or streaming interface
source/destination buffer
message/block framing
AAD handling
nonce/sequence ownership
completion/error
arbitration
security/isolation
```

현재 APB interface는 control/status 또는 small-message path로 남길 수 있다.

## 23. Baseline Invariants

1. AES-GCM canonical base는 `0x4004_0000`, APB slot 4이다.
2. Active wrapper는 `pipe0/apb_aes_gcm_ip.v`의 `apb_aes_gcm`이다.
3. PREADY는 항상 1이다.
4. AES interrupt는 없다.
5. Wrapper가 expose하는 mode는 AES-128이다.
6. Key는 KEY0..3의 128 bits이다.
7. IV는 `NONCE_DIR || SEQ_HI || SEQ_LO`의 96 bits이다.
8. AAD는 `A55A || NONCE_DIR || SEQ || LEN`의 fixed 16 bytes이다.
9. Payload window는 128-bit 한 block이다.
10. Canonical LEN은 0..16 bytes이다.
11. Encrypt는 PAYLOAD_OUT + TAG_OUT을 생성한다.
12. Decrypt는 TAG_IN과 generated tag를 비교해 TAG_OK/ERROR를 만든다.
13. Completion/authentication은 polling이다.
14. Sequence/nonce 관리는 software 책임이다.
15. Key는 readable MMIO state이며 secure storage가 아니다.
16. VHDL crypto core는 third-party Apache-2.0-derived이고 APB/SoC integration은 project-local이다.
17. Historical reference-model test는 fresh active-core KAT signoff를 대체하지 않는다.

## 24. P13-01 Approved Target Contract — 구현 및 Acceptance 전

> **Lifecycle:** Owner가 승인한 D01~D12 Architecture와 상세 ABI를 반영한 Target 명세이다. **현재 RTL/FW가 이미 구현했다는 뜻이 아니다.** 위의 기존 Baseline 절은 현재/레거시 동작을 기록하며, 이 절은 구현 후 적용할 Target Contract다. 이 Target 명세만으로 Tracker, AES SoC Health, VERIFIED 상태를 승격하지 않는다.
> **Scope boundary:** APB, Memory Map 또는 Tracker의 변경은 별도 범위 결정을 필요로 한다.

### 24.1 인터페이스와 데이터 포맷 (D01, D04, D05, D09)

- `AES_GCM_BASE=0x4004_0000`, `PSEL[4]`, aligned 32-bit MMIO, `PREADY=1`, AES-128, Payload 0~16 byte, PCLK/polling-only 유지. AES IRQ/DMA/Replay Engine 없음.
- `+0x3C LEN`은 전체 32-bit R/W 저장·Readback. Firmware에서 truncation/masking 금지. START 시 전체 LEN을 `<=16`으로 검증하고, 유효한 LEN에만 AAD의 하위 16 bit 사용.
- Target `+0x08 VERSION`은 ASCII `"2.00"` (`0x322E3030`). 기존 현재 버전 `"1.00"`과 구분.
- KEY/IV/SEQ/PAYLOAD/TAG/HDR는 Offset 증가 순 MSW-first. Byte Array→Word는 `w=(b0<<24)|(b1<<16)|(b2<<8)|b3` 형태의 Word 값 Big-endian Pack으로 CPU byte-address endianness와 별개다.
- IV는 `NONCE_DIR || SEQ_HI || SEQ_LO` 96 bit, AAD는 `16'hA55A || NONCE_DIR || SEQ_HI || SEQ_LO || LEN[15:0]` 128 bit. `LEN=n`이면 가장 높은 n byte만 valid (`LEN=7 -> bval=16'hFE00`), LEN 밖의 Tail Byte는 인증된 결과가 아니며 Caller로 복사하지 않는다.

### 24.2 CTRL `+0x0C` — 배타적 명령 (D04~D06)

| Bit | Name | Target 의미 |
|---|---|---|
| 0 | `START` | W1P; IDLE에서 Encrypt/Decrypt 시작, Read 0. |
| 1 | `ENC_DEC` | START 인자(0 Encrypt, 1 Decrypt). 마지막 **IDLE에서 수락된 유효 Encoding START**의 방향 Readback, Invalid LEN Terminal Reject 포함. CLR_STATUS는 보존, Reset/Zeroize는 0. |
| 2 | `CLR_STATUS` | IDLE 전용 W1P. DONE/TAG_OK/모든 Operation·Programming Cause 삭제; 방향/입출력/Key/Core 내용 유지. Read 0. |
| 3 | `ZEROIZE` | IDLE 전용 W1P. 민감 상태 소거 + Core Reset Maintenance 시작. Read 0. |
| 31:4 | Reserved | Read 0; Write-one은 `CTRL_CMD_ERR`. |

허용되는 32-bit 값은 `0x0` No-op, `0x1` Encrypt START, `0x3` Decrypt START, `0x4` CLR_STATUS, `0x8` ZEROIZE뿐이다. `0x2`, 복합 Command(`0x5`, `0x9` 등), Reserved-bit 사용은 `CTRL_CMD_ERR`로 거부하고 Command/Direction/Data Side Effect가 없다. BUSY 중 명령은 24.4에 따라 거부한다. Invalid LEN START는 Encoding은 유효하므로 Direction Readback은 갱신한다.

### 24.3 STATUS `+0x10` — Terminal / Error Cause (D02, D03, D08)

| Bit | Name | Target 의미 |
|---:|---|---|
| 0 | `BUSY` | Crypto 또는 Zeroize Maintenance 중. 새 START 접수 불가. |
| 1 | `DONE` | 마지막 IDLE-accepted START의 Terminal Outcome. **성공 의미 아님**. ZEROIZE는 DONE 미설정. |
| 2 | `TAG_OK` | 정상 Encrypt/Tag Match, PROG_ERROR가 있더라도 1일 수 있음. |
| 3 | `ERROR` | `OP_ERROR \| PROG_ERROR`, 독립 Sticky 아님. |
| 4 | `OP_ERROR` | `LEN_ERROR \| AUTH_FAIL \| CORE_OVERFLOW`. |
| 5 | `PROG_ERROR` | `BUSY_WRITE_ERR \| CTRL_CMD_ERR \| BUSY_START_ERR \| ZEROIZE_BUSY_ERR`. |
| 6 | `LEN_ERROR` | full-width LEN>16 START 거부. |
| 7 | `AUTH_FAIL` | Decrypt Tag 불일치. |
| 8 | `CORE_OVERFLOW` | Core ICB Overflow Terminal Fault. |
| 9 | `BUSY_WRITE_ERR` | BUSY 중 Program Register Write 거부. |
| 10 | `CTRL_CMD_ERR` | Malformed CTRL 또는 BUSY CLR_STATUS. |
| 11 | `BUSY_START_ERR` | BUSY 중 유효 START 요청 거부. |
| 12 | `ZEROIZE_BUSY_ERR` | BUSY 중 ZEROIZE 거부. |
| 13 | `ZEROIZE_ACTIVE` | Zeroize Reset Sequence 진행 중. 이때 BUSY=1. |
| 31:14 | Reserved | Read 0. |

Operation Cause(LEN/AUTH/OVERFLOW)는 새 IDLE Accepted START, IDLE CLR_STATUS, Accepted ZEROIZE, Reset에서 Clear. Programming Cause(BUSY_WRITE/CTRL_CMD/BUSY_START/ZEROIZE_BUSY)는 **IDLE CLR_STATUS, Accepted ZEROIZE 또는 Reset에서만** Clear. 새 START에서 자동 Clear하지 않음. STATUS Read는 Side Effect 없음. `DONE/TAG_OK`는 새 Accepted START/CLR/ZEROIZE/Reset 시 Clear. 요약 비트는 원인 비트의 OR와 항상 일치. `DONE=1,TAG_OK=1,PROG_ERROR=1,ERROR=1` 가능하며 Trusted FW는 실패 반환.

BUSY는 실제 새 START 접수가 가능한 시점까지 1을 유지해야 하며 Core Completion 직후 조기 BUSY=0으로 Back-to-back START를 놓쳐서는 안 된다. Zeroize 수행 중 BUSY=ZEROIZE_ACTIVE=1이고 DONE=0; 정상 완료 후 양 비트는 0이며 불법 접근이 없었다면 전체 STATUS는 0.

### 24.4 Command 우선순위와 에러 동작 (D01~D04, D06, D08)

1. System/APB Reset이 최우선. Software-visible 상태와 Core-control Epoch Reset. Reset으로 중단된 Bus Transaction은 정상 응답 보장 없음.
2. ACTIVE Operation의 Core Overflow는 동시 Success/Tag Pulse보다 우선. `BUSY=0,DONE=1,TAG_OK=0,CORE_OVERFLOW=1` Terminal Failure이며 Late Pulse로 이전 Output이 재노출되면 안 됨. 이것은 **Software BUSY Zeroize 허용이 아니라 내부 Fatal Fault Handling**이다. VHDL Core Reset 시퀀스로 불가능하면 Hard STOP 및 Owner 재결정; 무한 BUSY를 정상 성공으로 인정하지 않음.
3. IDLE ZEROIZE 수락은 24.5 수행.
4. IDLE START 수락 시 이전 Operation Outcome/Cause 및 PAYLOAD_OUT/TAG_OUT Clear. Full LEN `<=16`이면 Crypto 진입/HDR 생성. 초과하면 Core Pulse 없이 `BUSY=0,DONE=1,TAG_OK=0,LEN_ERROR=1`, 이전 PAYLOAD_OUT/TAG_OUT/HDR를 0으로 Clear. Program Input은 진단용 유지.
5. IDLE CLR_STATUS는 모든 DONE/TAG_OK/Cause만 Clear, Direction/Input/Output/Core 유지. 잔존 Output은 신뢰 유효성이 없음.
6. BUSY 중 부적합 접근은 관련 Programming Cause만 기록하고 진행 중 연산/FSM/Tag Comparator/Direction/Output에 영향 없음. 유효 START -> BUSY_START_ERR, 유효 ZEROIZE -> ZEROIZE_BUSY_ERR, CLR_STATUS 또는 Malformed CTRL -> CTRL_CMD_ERR, KEY/IV/LEN/PAYLOAD_IN/TAG_IN Write -> BUSY_WRITE_ERR. `CTRL=0`은 No-op. 완료와 불법 Write가 동일 PCLK에서 겹치면 완료 상태와 Programming Cause를 모두 기록.

BUSY 중 거부된 APB Write는 `PREADY=1`, `PSLVERR` 없이 OKAY로 완료되고 `PROG_ERROR`로만 보고한다. 총 16개 Program Word(KEY4/IV3/LEN1/PAYLOAD4/TAG4)는 BUSY에서 변경하지 않는다. 특히 Decrypt TAG_IN 비교값에 대한 Side Effect가 없어야 한다.

### 24.5 Zeroize C 목표와 BUSY Reject (D05, D06)

`CTRL=0x8` IDLE 수락 시 KEY, NONCE_DIR/SEQ/LEN, PAYLOAD_IN/TAG_IN, PAYLOAD_OUT/TAG_OUT, HDR, Wrapper-held Core-driving Secret/Control State, Direction/Status를 Clear하고 VHDL Core Reset을 적절히 Assert/Release한다. 완료까지 BUSY=1, ZEROIZE_ACTIVE=1로 새 START를 받지 않는다. 완료 후 상기 SW Readback은 0, Old Core Late Result 재노출 금지. RESET Coverage와 Pulse Width는 P13-02/04에서 증명한다.

BUSY 중 ZEROIZE 요청은 `ZEROIZE_BUSY_ERR`를 Set하면서 기존 연산/Key/Output/Reset State를 변경하지 않고 거부한다. Core Hang/Timeout 시 SW Zeroize 불가하므로 별도 System Reset/Recovery가 필요하다. 이 정책은 **물리 Flop Erasure, Key Vault, Side-channel Resistance를 보장하지 않는다**.

### 24.6 Decrypt Trust와 Output 수명 (D07, D08)

선택된 정책은 **Firmware-only Authentication Gate**다. Hardware의 Raw PAYLOAD_OUT은 Tag Match 전이나 Wrong-tag 후에도 Plaintext를 노출할 수 있다. 인증 전 Raw MMIO 접근 차단을 보장하지 않는다. 정상 FW API만 `DONE && TAG_OK && !ERROR` 확인 후 Caller Output에 Valid LEN Byte만 제공한다. AUTH_FAIL, Programming Error, Overflow, Invalid LEN, Timeout 시 Caller Output은 0 초기화 상태(또는 미변경이 아닌 0 선택)로 유지한다. Firmware Single Owner/Serial MMIO 전제가 깨지면 Hardware가 해당 Trust Boundary를 보호하지 않는다.

새 IDLE Accepted START는 이전 PAYLOAD_OUT/TAG_OUT Clear. LEN Invalid START는 HDR도 Clear. 정상 완료 후 LEN 범위 내 Data/Tag는 다음 START/ZEROIZE/RESET까지 Readable. CLR_STATUS는 Output 물리 값을 지우지 않으나 신뢰 상태는 해제한다.

### 24.7 APB/AHB Bridge 및 Wrapper Local Decode 정책 (D10)

CPU→AHB/APB Bridge는 Slot4의 Canonical Offset/Aligned Word/Full Address를 Validation하고 Invalid Offset, Alias, Size, Alignment는 AES PSEL 없이 기존 Two-cycle AHB ERROR로 종료한다. Target AES Wrapper도 Wrapper에서 사용 가능한 전체 APB Address Width로 정확한 Canonical Local Offset을 Decode해야 하며 수락 판정에 `PADDR[7:2]`로 잘라서는 안 된다. 정규 Register Word는 계속 사용 가능하며 `+0x100` 및 다른 High-bit Alias는 이를 선택하지 못한다. Direct-APB의 Reserved/Noncanonical Local Offset Read는 0(RAZ), Write는 무시(WI)하고 MMIO 상태나 Crypto Core 부작용이 없어야 한다. `PREADY=1`, AES `PSLVERR` 없음을 유지하며 Local RAZ/WI가 잘못된 CPU 접근의 성공을 뜻하지 않는다.

정규 RO/WO Register의 Wrong-direction 접근은 Invalid Offset과 별개이며 이번 개정은 기존 정책을 변경하지 않는다. 특히 Bridge는 Direction을 검사하지 않아 정규 RO Write는 OKAY/No-op일 수 있다. 현재 Wrapper는 앞 절의 Partial-decode Alias가 여전히 존재하며 Exact Decode 및 검증은 Target 작업이지 구현 완료 주장이 아니다. APB-005 전체 VERIFIED 승격 금지.

### 24.8 Firmware 연계 및 Security Scope (D11, D12)

정상 FW는 전체 LEN/Pointer 검증을 MMIO보다 먼저 수행하고, IDLE 확인/CLR_STATUS/입력 Program/STATUS 재검증/START 후 최대 caller-supplied Poll Budget회 STATUS Read로 Terminal을 판정한다. 성공 조건은 `DONE && TAG_OK && !ERROR`; 실패 때 Output 공개 금지. `poll_budget=0`은 순수 Argument Check 후 **MMIO 0회, 즉시 TIMEOUT**. `N>0`이면 최대 N개 **완료된** STATUS Read로 판정; Bus 영구 Stall/CPU Trap은 이 소프트웨어 한도로 제한 불가. AES-001 기존 12 Poll 관측을 49~50 PCLK Latency 최대치로 오인하지 않으며 실제 Cycle/기본 Poll Budget은 P13-04에서 측정한다.

FW/Protocol은 Encryption `(Key, IV)` 유일성, Sequence Persistence 및 Replay Defense를 책임진다. HW는 Auto-IV/Nonce, Replay Counter, Secure Vault, Physical Erasure, DMA, IRQ/PLIC, Constant-time System Guarantee 또는 Health AES Provider Enable을 제공하지 않는다. SoC Health AES는 후속 검증 전 `EXCLUDED_PENDING_CLEANUP` 유지.

### 24.9 Target AC와 현재 상태

| AC ID | Req | 필요한 검증 | 현재 |
|---|---|---|---|
| `AES-AC-01` | AES-002, D01/D02 | 0~16 /17/65535/65536/65552 LEN, Full Readback, Invalid START Core Pulse 없음/DONE 확인 | OPEN |
| `AES-AC-02` | AES-003, D09 | MSW/BE Byte Order, 독립 GCM Oracle, Partial Tail 정책 | OPEN (AES-001 KAT만 VERIFIED) |
| `AES-AC-03` | AES-004, D07/D08 | Wrong Tag Cause와 FW Plaintext 비공개 | OPEN |
| `AES-AC-04` | AES-005, D05/D06 | Zeroize 후 민감 MMIO=0, Reset/Late Pulse, BUSY Zeroize 거부 | OPEN |
| `AES-AC-05` | AES-006, D03/D04/D08 | BUSY Write No-mutation, CTRL, Direction, Sticky Cause, 동시 Event | OPEN |
| `AES-AC-06` | AES-007, D10 | Direct-APB Reserved/Noncanonical RAZ/WI 및 부작용 없음, `+0x100`/High-bit Alias 차단, CPU Invalid 접근의 Two-cycle ERROR 및 AES PSEL 차단을 검증하고 정규 Wrong-direction 정책은 별도로 유지 | OPEN |
| `AES-AC-07` | FW-010/FW-002, D11 | Bounded Poll, Zero-budget 0 MMIO, Error Code와 Output Gate | OPEN |
| `AES-AC-08` | D08/D11 | Overflow Terminal Fault, Late Result 차단 | OPEN |
| `AES-AC-09` | D12 | Security/Nonce/Replay 책임 및 한계 명시 | OPEN |

`AES-001`은 이전 Actual-core 6-case KAT (Encrypt/Decrypt LEN 0/7/16) 범위에서만 VERIFIED. AES-002~007, FW-010, VER-006 및 APB-005/FW-002 상태는 이 Target 명세만으로 승격하지 않는다. 이 명세는 Simulation, Synthesis, Board Run의 증거가 아니다.

### 24.10 Traceability

- [AES English canonical](../14_aes_gcm.md), [Firmware companion](19_firmware_contract.ko.md), [APB subsystem](../05_apb_subsystem.md), [Memory Map](../01_memory_map.md), [Tracker](../baseline_cleanup.md).
- 구현/검증은 P13-02 RTL, P13-03 FW, P13-04 Actual-core independent DV 및 Latency, P13-05 CPU E2E 후속 단계에서 별도 수행한다.
