# Baseline SoC AES-GCM Accelerator Specification — 한국어 Companion

> **상태:** DRAFT — active FPGA baseline을 기준으로 복원한 문서이며 Developer + ChatGPT Chat의 최종 리뷰 대상이다.
>
> **정본 언어:** 영어. 이 문서와 `spec/14_aes_gcm.md`가 충돌할 경우 영문 canonical specification이 authoritative source이다.
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

Unsupported offset read는 0이고 write는 무시된다.

현재 APB path에는 PSLVERR/AHB bus-fault propagation도 없다.

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
| Medium | register alias 제거 | current partial decode |
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
