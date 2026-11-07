# Baseline SoC AES-GCM Accelerator Specification

> **Status:** Current baseline documentation plus **P13-01 Owner-approved TARGET** in Section 25 (pending implementation and acceptance). Original baseline sections remain observational; target behavior is not yet implemented.
>
> **Canonical language:** English. If this file and `kor/14_aes_gcm.ko.md` conflict, this file is authoritative.
>
> **Parent specifications:** `soc_architecture.md`, `memory_map.md`, `apb_subsystem.md`, `reset_clock.md`, `interrupt_architecture.md`.

## 1. Purpose

This document defines the software-visible AES-GCM accelerator integrated into the active FPGA baseline.

It specifies:

- the APB/MMIO register contract,
- the boundary between project-local APB integration logic and the third-party AES-GCM VHDL core,
- AES-128 operating mode,
- key, IV, sequence, AAD-header, payload, and authentication-tag formatting,
- encrypt/decrypt command and status behavior,
- single-block payload-length semantics,
- firmware polling requirements,
- security and correctness limitations,
- verification requirements,
- cleanup items required before future interconnect, DMA, or interrupt integration.

The baseline block is a **single-operation, polling-controlled AES-128-GCM accelerator** with a 16-byte payload window. It is not a streaming DMA crypto engine, secure key vault, multi-context accelerator, or interrupt-driven peripheral.

## 2. Active Architectural Boundary

The active integration is:

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
       +-- project-local MMIO registers / control FSM
       |
       +-- top_aes_gcm
             |
             +-- upstream-derived VHDL AES/GCM datapath
```

Canonical base address:

```text
AES_GCM_BASE = 0x4004_0000
APB slot     = PSEL[4]
```

Active wrapper:

```text
rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v
```

The VHDL cryptographic implementation resides under:

```text
rtl/peripherals/aes_gcm/pipe0/
```

The entire wrapper and core execute in the APB `PCLK` domain. There is no AES-specific CDC in the active block.

The peripheral permanently asserts:

```text
PREADY = 1
```

and has no interrupt output in the baseline.

## 3. Provenance and Ownership Boundary

The VHDL AES-GCM core is based on the Apache-2.0-licensed project:

```text
BLu85/AES-GCM-128-192-256-bits
```

Repository attribution and license details are maintained in:

```text
rtl/peripherals/aes_gcm/README.md
THIRD_PARTY_NOTICES.md
licenses/BLu85-AES-GCM-Apache-2.0.txt
```

The project-local SoC work includes the active Verilog APB wrapper, MMIO programming model, operation sequencing, packet/AAD construction, firmware drivers, and SoC integration.

This specification does not claim that the underlying AES-GCM algorithmic VHDL core was authored locally.

## 4. Canonical Register Map

The wrapper decodes `PADDR[7:2]`.

| Offset | Register | Access | Reset | Meaning |
|---:|---|---|---:|---|
| `0x00` | `NAME0` | R | constant | ASCII `"apb-"` |
| `0x04` | `NAME1` | R | constant | ASCII `"gcm "` |
| `0x08` | `VERSION` | R | constant | ASCII `"1.00"` |
| `0x0C` | `CTRL` | R/W command | `0` | start / encrypt-decrypt / clear-status |
| `0x10` | `STATUS` | R | `0` | busy / done / tag-ok / error |
| `0x20` | `KEY0` | R/W | `0` | key bits `[127:96]` |
| `0x24` | `KEY1` | R/W | `0` | key bits `[95:64]` |
| `0x28` | `KEY2` | R/W | `0` | key bits `[63:32]` |
| `0x2C` | `KEY3` | R/W | `0` | key bits `[31:0]` |
| `0x30` | `NONCE_DIR` | R/W | `0` | `[31:8]` session nonce, `[7:0]` direction |
| `0x34` | `SEQ_HI` | R/W | `0` | sequence bits `[63:32]` |
| `0x38` | `SEQ_LO` | R/W | `0` | sequence bits `[31:0]` |
| `0x3C` | `LEN` | R/W | `0` | payload length, lower 16 bits used |
| `0x40` | `PAYLOAD_IN0` | R/W | `0` | payload bits `[127:96]` |
| `0x44` | `PAYLOAD_IN1` | R/W | `0` | payload bits `[95:64]` |
| `0x48` | `PAYLOAD_IN2` | R/W | `0` | payload bits `[63:32]` |
| `0x4C` | `PAYLOAD_IN3` | R/W | `0` | payload bits `[31:0]` |
| `0x50` | `TAG_IN0` | R/W | `0` | expected tag bits `[127:96]` for decrypt |
| `0x54` | `TAG_IN1` | R/W | `0` | expected tag bits `[95:64]` |
| `0x58` | `TAG_IN2` | R/W | `0` | expected tag bits `[63:32]` |
| `0x5C` | `TAG_IN3` | R/W | `0` | expected tag bits `[31:0]` |
| `0x60` | `PAYLOAD_OUT0` | R | `0` | result bits `[127:96]` |
| `0x64` | `PAYLOAD_OUT1` | R | `0` | result bits `[95:64]` |
| `0x68` | `PAYLOAD_OUT2` | R | `0` | result bits `[63:32]` |
| `0x6C` | `PAYLOAD_OUT3` | R | `0` | result bits `[31:0]` |
| `0x70` | `TAG_OUT0` | R | `0` | generated tag bits `[127:96]` |
| `0x74` | `TAG_OUT1` | R | `0` | generated tag bits `[95:64]` |
| `0x78` | `TAG_OUT2` | R | `0` | generated tag bits `[63:32]` |
| `0x7C` | `TAG_OUT3` | R | `0` | generated tag bits `[31:0]` |
| `0x80` | `HDR0` | R | `0` | debug AAD header bits `[127:96]` |
| `0x84` | `HDR1` | R | `0` | debug AAD header bits `[95:64]` |
| `0x88` | `HDR2` | R | `0` | debug AAD header bits `[63:32]` |
| `0x8C` | `HDR3` | R | `0` | debug AAD header bits `[31:0]` |

For **direct wrapper-local APB access**, offsets not listed above read zero unless they alias a listed register because of the current partial decode. Noncanonical CPU accesses through the active bridge are rejected before AES selection.

## 5. CTRL Register

`CTRL` is at `+0x0C`.

```text
bit 0 START
bit 1 ENC_DEC
bit 2 CLR_STATUS
```

### 5.1 START

Writing `START=1` launches an operation if `BUSY=0`.

The same APB write carries the operation direction in `ENC_DEC`:

```text
ENC_DEC = 0 -> encrypt
ENC_DEC = 1 -> decrypt / authenticate
```

`START` is a command bit, not retained as a persistent control state.

If `START=1` is written while `BUSY=1`, the active operation is not intentionally restarted. The wrapper sets `ERROR=1` and leaves the current operation running.

### 5.2 CLR_STATUS

Writing `CLR_STATUS=1` clears:

```text
DONE
TAG_OK
ERROR
```

It does not clear `BUSY`, input registers, output registers, key material, IV fields, or the VHDL core by itself.

Any write to `CTRL` also loads the retained `ENC_DEC` readback bit from `PWDATA[1]`. Therefore a status-clear write containing only bit 2 also changes the visible retained direction bit to encrypt (`0`). Firmware shall not use the CTRL readback bit as a historical record of the last completed operation after arbitrary control writes.

## 6. STATUS Register

`STATUS` is at `+0x10`.

```text
bit 0 BUSY
bit 1 DONE
bit 2 TAG_OK
bit 3 ERROR
```

### 6.1 BUSY

`BUSY=1` from accepted START until the wrapper has captured all results required for completion.

### 6.2 DONE

`DONE=1` indicates that the wrapper considers the operation complete and the output registers have been captured.

`DONE` remains set until `CLR_STATUS` or reset.

### 6.3 TAG_OK

For encryption, the wrapper treats the internally generated tag as accepted and completes with `TAG_OK=1` when the operation finishes normally.

For decryption, the generated tag is compared against the 128-bit `TAG_IN` value. A match produces `TAG_OK=1`; a mismatch produces `TAG_OK=0` and sets `ERROR=1`.

### 6.4 ERROR

Current wrapper-visible error causes include at least:

- START issued while BUSY,
- AES-GCM core ICB counter overflow,
- authentication-tag mismatch on decrypt.

`ERROR` is sticky until explicitly cleared or reset.

The baseline has no APB error response for AES operation errors; software must inspect `STATUS`.

## 7. AES Operating Mode and Key Formatting

The wrapper explicitly selects:

```text
AES mode = AES-128
```

on every accepted operation.

The four MMIO key words form:

```text
KEY = KEY0 || KEY1 || KEY2 || KEY3
    = 128 bits
```

and are presented to the upstream 256-bit key port in the upper 128 bits. The wrapper drives the upstream AES-128 key-valid selection (`4'b0100`).

Only the 128-bit key programming model in this specification is part of the baseline contract. The upstream core's support for additional AES key sizes is not exposed by this APB wrapper.

## 8. IV and Sequence Construction

The software-visible IV components are:

```text
NONCE_DIR[31:8] = session_nonce[23:0]
NONCE_DIR[7:0]  = DIR[7:0]
SEQ_HI          = SEQ[63:32]
SEQ_LO          = SEQ[31:0]
```

The 96-bit GCM IV is constructed as:

```text
IV[95:0]
 = session_nonce[23:0]
 || DIR[7:0]
 || SEQ[63:0]
```

or equivalently:

```text
IV = NONCE_DIR || SEQ_HI || SEQ_LO
```

The sequence number is entirely software-managed. The hardware does not auto-increment it.

For a fixed key, software must not intentionally reuse the same GCM IV for different protected messages. IV allocation and persistence policy belong to the firmware/protocol contract, not to the accelerator hardware.

## 9. Fixed 16-Byte AAD Header

Every operation authenticates a project-specific 128-bit header as AAD.

```text
AAD[127:0]
 = MAGIC[15:0]
 || NONCE_DIR[31:0]
 || SEQ_HI[31:0]
 || SEQ_LO[31:0]
 || LEN[15:0]
```

where:

```text
MAGIC = 16'hA55A
```

The AAD header is always presented to the core as 16 valid bytes.

At START, the wrapper snapshots the constructed AAD into `HDR0..HDR3` for debug/readback. These registers are diagnostic and are not independently programmable AAD memory.

The baseline does not provide arbitrary software-supplied AAD.

## 10. Payload Window and Length Semantics

The software-visible payload window is exactly 128 bits:

```text
PAYLOAD_IN0 || PAYLOAD_IN1 || PAYLOAD_IN2 || PAYLOAD_IN3
```

The intended and supported baseline payload length is:

```text
0 <= LEN <= 16 bytes
```

For lengths 1 through 15, the wrapper generates a byte-valid mask with the most-significant `LEN` bytes marked valid. `LEN=16` marks all 16 bytes valid. `LEN=0` performs an AAD-only GCM operation and treats payload output as zero.

The active RTL function returns an all-valid 16-byte mask for values outside the explicit 0..15 cases. Therefore values greater than 16 are **not a valid software contract** even though the hardware may process a 16-byte data window while authenticating a larger numeric LEN value in the AAD header.

Software shall constrain:

```text
LEN <= 16
```

until explicit hardware length validation is added.

The accelerator does not stream multiple payload blocks and does not walk memory. Larger messages require a different architecture or software-level segmentation protocol; such segmentation is not defined by this baseline specification.

## 11. Word and Byte Ordering

The wrapper concatenates 32-bit register words in increasing register order from most-significant to least-significant bits:

```text
KEY      = {KEY0, KEY1, KEY2, KEY3}
PAYLOAD  = {IN0,  IN1,  IN2,  IN3}
TAG_IN   = {TAG0, TAG1, TAG2, TAG3}
```

Output capture follows the same convention:

```text
OUT0 = result[127:96]
OUT1 = result[95:64]
OUT2 = result[63:32]
OUT3 = result[31:0]
```

Firmware converting byte arrays to MMIO words shall preserve the byte order expected by the established AES-GCM test vectors and protocol framing. The 32-bit MMIO word ordering alone shall not be confused with the CPU's byte-address endianness.

## 12. Operation Sequence

An accepted operation follows the project-local wrapper FSM:

```text
START
  |
  v
CORE_RESET
  |
  v
KEY_PULSE
  |
  v
IV_START
  |
  v
WAIT_READY
  |
  v
SEND_AAD
  |
  +-- LEN = 0 ----------> PKT_END
  |
  +-- LEN != 0
          |
          v
      SEND_DATA
          |
          v
       WAIT_CT
          |
          v
       PKT_END
          |
          v
     WAIT_RESULT
          |
          v
      DONE_PULSE
          |
          v
         IDLE
```

The wrapper performs a soft reset of the VHDL core for each accepted operation, pulses the AES-128 key-valid input, loads the 96-bit IV, sends the fixed 16-byte AAD, optionally sends one payload block, terminates the GHASH packet, and waits for ciphertext/plaintext and tag result pulses.

`WAIT_CT` intentionally holds the GHASH packet-valid condition for an additional cycle so the delayed GCTR data/bval result is consumed before packet termination.

Result capture is performed independently of the drive-FSM state so short valid pulses from the VHDL core are not intentionally missed.

## 13. Encrypt Contract

The minimum software sequence is:

```text
1. wait for BUSY = 0
2. program KEY0..KEY3
3. program NONCE_DIR / SEQ_HI / SEQ_LO
4. program LEN and PAYLOAD_IN0..3
5. clear stale status
6. write CTRL.START with ENC_DEC=0
7. poll DONE
8. verify ERROR=0
9. read PAYLOAD_OUT0..3
10. read TAG_OUT0..3
```

`TAG_IN` is not used for encryption authentication checking and may be zeroed by firmware for deterministic diagnostics.

## 14. Decrypt / Authenticate Contract

The minimum software sequence is:

```text
1. wait for BUSY = 0
2. program KEY0..KEY3
3. program NONCE_DIR / SEQ_HI / SEQ_LO
4. program LEN and ciphertext into PAYLOAD_IN0..3
5. program expected TAG_IN0..3
6. clear stale status
7. write CTRL.START with ENC_DEC=1
8. poll DONE
9. require TAG_OK=1 and ERROR=0
10. only then accept PAYLOAD_OUT0..3 as authenticated plaintext
```

Firmware shall not treat decrypted output as trusted until authentication succeeds.

The active wrapper can capture output data before final tag comparison completes. This is normal internal behavior; software's trust boundary is the final `DONE/TAG_OK/ERROR` status, not the mere existence of nonzero output words.

## 15. Register Mutation While BUSY

The APB wrapper does not block ordinary register writes while an AES operation is busy.

Most core-driving values are copied into internal core registers at operation start, but software shall nevertheless treat the complete input programming set as immutable until `BUSY=0`.

This requirement is especially important for decrypt `TAG_IN`, because the tag comparison uses the wrapper's tag-input register value when the core tag arrives.

Baseline firmware rule:

```text
BUSY = 1
-> do not modify KEY, NONCE_DIR, SEQ, LEN, PAYLOAD_IN, or TAG_IN
-> do not issue another START
```

## 16. Reset Behavior

System/APB reset clears:

- BUSY, DONE, TAG_OK, ERROR,
- retained direction state,
- all key registers,
- IV/sequence/length registers,
- input payload/tag registers,
- output payload/tag registers,
- debug header registers,
- wrapper/core-control state.

The VHDL core reset input is asserted by either system reset or the wrapper's per-operation soft-reset pulse.

There is no separate reset or clock domain for AES-GCM.

## 17. Security Limitations of the Baseline

The baseline accelerator is suitable as a project cryptographic datapath, not as a hardened production security boundary.

Notable limitations are:

- key registers are software-readable,
- key material remains in MMIO registers until overwritten or reset,
- there is no hardware key vault or access privilege model,
- there is no automatic sequence/nonce allocation,
- there is no anti-replay state,
- there is no DMA isolation,
- there is no constant-time software access guarantee at system level,
- authentication failure is reported only through polling status,
- there is no explicit zeroization command,
- payload and tag registers are directly readable through MMIO.

Future documentation shall not describe this block as providing secure key storage or a complete secure-channel architecture.

## 18. APB Decode and Error Limitations

The wrapper decodes only:

```text
PADDR[7:2]
```

so the register map repeats every `0x100` bytes inside the already coarsely decoded APB slot. Such mirrors are implementation aliases, not canonical addresses.

The block exposes no `PSLVERR`; its crypto/programming errors use STATUS rather than bus faults. The current AHB/APB **bridge** separately blocks noncanonical CPU slot-4 offsets/sizes before selecting AES and returns two-cycle AHB ERROR. Wrapper-local direct-APB aliases/direction limitations remain.

For **current direct wrapper-local APB access**, unsupported or unused decoded offsets read as zero and writes are ignored, except where the partial decode aliases a listed register. This does not override the CPU-side bridge error response for noncanonical slot-4 addresses.

All canonical firmware accesses shall use naturally aligned 32-bit MMIO operations.

## 19. Firmware Integration

The active driver is:

```text
firmware/drivers/aes_gcm.c
firmware/include/aes_gcm.h
```

The driver exposes helpers for:

- key programming,
- IV/sequence programming,
- payload/tag input,
- payload/tag output,
- status clear,
- encrypt/decrypt START,
- DONE polling.

Current firmware correctly clears status before normal start sequences. Higher-level firmware should additionally enforce a bounded wait/timeout when forward progress matters; the low-level `aes_gcm_wait_done()` helper itself is an unbounded busy wait.

The baseline generates no AES interrupt, so all completion handling is polling-based.

## 20. Verification Status and Evidence Boundary

Different historical AES tests cover different layers and shall not be conflated.

A legacy APB reference-model SoC test verifies CPU/APB register programming and fixed golden-vector register behavior without compiling the actual VHDL AES-GCM core. Passing that test does **not** by itself prove the active VHDL cryptographic datapath.

Legacy GHDL material also records direct real-core golden-vector investigation. Because those artifacts are under `verification/legacy/`, they are evidence/reference material rather than current baseline signoff.

Before the baseline is frozen for major feature integration, the active source tree shall receive a fresh reproducible cryptographic regression using known AES-GCM vectors through the actual wrapper/core combination.

AES-001 is `VERIFIED` after User/Chat approval of the Phase 4A actual production APB wrapper/VHDL core AES-128-GCM KAT: independent-oracle encrypt/decrypt cases for 0, 7 and 16 payload bytes passed. The detailed internal report is `PRIVATE_LOCAL_EVIDENCE_REQUIRED` until a sanitized public AES evidence package is approved. This scoped result does not close the other AES cleanup rows or VER-006. The unrelated full-SoC mixed-language CPU compile failure is retained under VER-001 evidence.

## 21. Required Directed Verification

At minimum, baseline cleanup verification shall cover:

1. NAME/VERSION register values.
2. Reset values of all software-visible state.
3. Read/write and word ordering for KEY, IV/SEQ, PAYLOAD_IN, and TAG_IN.
4. AAD debug header construction.
5. 96-bit IV construction.
6. Standard AES-128-GCM known-answer encryption vectors.
7. Standard AES-128-GCM known-answer decryption/tag-check vectors.
8. Correct rejection/reporting of a modified tag.
9. `LEN=0` AAD-only behavior.
10. Every payload length from 1 through 16 bytes.
11. Explicit behavior for `LEN>16` after length validation is implemented.
12. START while BUSY.
13. CLR_STATUS semantics.
14. Back-to-back operations with different keys/IVs/data.
15. No stale DONE/TAG_OK result leakage between operations.
16. Core overflow/error handling.
17. Register mutation attempt while BUSY.
18. APB register mirror/noncanonical access policy.

Cryptographic expected values shall come from a trusted independent implementation or published test vectors, not from the RTL under test.

## 22. Baseline Cleanup Targets

The following items shall be transferred into the consolidated baseline cleanup plan.

| Priority | Cleanup target | Reason |
|---|---|---|
| High | Run and preserve a fresh actual-core AES-128-GCM KAT regression | APB reference-model PASS is not cryptographic-core proof |
| High | Explicitly reject `LEN > 16` | current byte-valid function otherwise treats out-of-range values as a full 16-byte window |
| High | Define and verify byte/word ordering with independent vectors | prevents silent protocol interoperability errors |
| High | Harden decrypt trust contract | plaintext must not be consumed before tag authentication succeeds |
| High | Define key-zeroization policy | key remains readable/stored until overwrite/reset |
| Medium | Block or formally define input-register writes while BUSY | avoids mid-operation state ambiguity, especially TAG_IN |
| Medium | Separate status-clear command from retained ENC_DEC state | CTRL clear currently also rewrites direction readback |
| Medium | Add bounded completion/timeout policy to production firmware | current low-level wait helper can spin forever |
| Medium | Implement and verify exact AES local decode | CPU bridge blocks noncanonical offsets/sizes; the approved target removes wrapper-local aliases while preserving the separate direction policy |
| Medium | Decide AES completion/error interrupt contract for future PLIC | baseline is polling-only |
| Medium | Decide future DMA/streaming architecture independently | current accelerator only accepts one 128-bit payload window |
| Low | Review debug-header exposure in final production-facing register map | debug visibility may not belong in a hardened interface |

## 23. Future DMA / AXI Boundary

The current accelerator is APB register driven and processes one payload window at a time.

A future high-throughput design shall not automatically extend this register interface into an ad-hoc multi-block protocol. If DMA or external memory is introduced, a new architecture specification shall define:

- descriptor or streaming interface,
- AXI master/slave ownership,
- source/destination buffers,
- block/message framing,
- AAD handling,
- nonce/sequence ownership,
- completion/error signaling,
- arbitration interaction,
- security/isolation boundaries.

The existing APB block can remain a control/status or small-message path if that is architecturally useful.

## 24. Baseline Invariants

The following statements are authoritative for the current FPGA baseline:

1. AES-GCM is at canonical APB base `0x4004_0000`, slot 4.
2. The active wrapper is `apb_aes_gcm` in `pipe0`.
3. `PREADY` is permanently high.
4. There is no AES interrupt output.
5. The wrapper exposes AES-128 only.
6. The software-visible key is 128 bits across KEY0..KEY3.
7. The GCM IV is 96 bits: `NONCE_DIR || SEQ_HI || SEQ_LO`.
8. The fixed AAD header is 16 bytes: `A55A || NONCE_DIR || SEQ || LEN`.
9. The payload window is one 128-bit block.
10. Canonical software payload length is 0..16 bytes.
11. Encryption produces PAYLOAD_OUT and TAG_OUT.
12. Decryption compares the generated tag against TAG_IN and reports TAG_OK/ERROR.
13. Completion and authentication status are software-polled.
14. Sequence/nonce management is software-owned.
15. Keys are readable MMIO state and are not secure-storage protected.
16. The VHDL cryptographic core is third-party Apache-2.0-derived; the APB/SoC integration is project-local.
17. Historical reference-model verification is not a substitute for fresh active-core cryptographic KAT signoff.

## 25. P13-01 Approved Target Contract — Pending Implementation and Acceptance

> **Lifecycle:** Owner-approved D01–D12 architecture and detailed ABI. This section is the **target contract**, not an assertion that the current RTL/FW implements it. Existing Sections 2–21 and 24 describe the observed/legacy baseline until P13-02/03 implementation and corresponding verification. No requirement status, tracker verdict, or AES-GCM SoC Health provider is promoted by this target contract.
> **Scope boundary:** Changes to the cross-owned APB, memory map or tracker require a separate scoped decision.

### 25.1 Fixed interface and register map (D01, D04, D05, D09)

- Preserve `AES_GCM_BASE=0x4004_0000`, slot `PSEL[4]`, aligned 32-bit APB/MMIO access, `PREADY=1`, AES-128, a single 0–16-byte payload window, PCLK domain and polling-only completion. There is no AES interrupt, DMA or hardware replay manager.
- Existing DATA register offsets remain unchanged. `LEN` at `+0x3C` becomes **full-width `uint32_t` R/W storage and readback**; no masking or truncation at write, before validation, or in firmware. A valid operation is `LEN<=16`; the AAD uses its lower 16 bits only after full-width validation.
- `VERSION` at `+0x08` becomes ASCII `"2.00"` (`0x322E3030`) when the target ABI is implemented. Existing `"1.00"` remains the current pre-cleanup value.
- Register words are concatenated in increasing offset, **MSW first**. Byte arrays pack to each 32-bit register **MSB first**: `w=(b0<<24)|(b1<<16)|(b2<<8)|b3` (not the CPU's byte-address endianness). `KEY=KEY0||KEY1||KEY2||KEY3`, `IV=NONCE_DIR||SEQ_HI||SEQ_LO`, `TAG_IN=TAG_IN0||...||TAG_IN3`; `PAYLOAD` and `HDR` use the same convention.
- Fixed AAD is exactly `16'hA55A || NONCE_DIR || SEQ_HI || SEQ_LO || LEN[15:0]`, 128 bits. `LEN=n` validates the **leftmost/high-order n bytes** of the one-block payload (`LEN=7 -> bval=16'hFE00`). Trailing output bytes beyond LEN are unspecified and **not authenticated payload**; trusted firmware copies only the first LEN bytes.

### 25.2 CTRL `+0x0C` — exclusive command encoding (D04–D06)

| Bits | Symbol | Approved write/read semantics |
|---|---|---|
| 0 | `START` | Write-one pulse for encrypt/decrypt; reads zero. |
| 1 | `ENC_DEC` | START argument, `0` encrypt / `1` decrypt. Readback is direction of the latest *well-encoded, IDLE-accepted* START (including invalid-LEN terminal rejection); not changed by CLR_STATUS. Reset/accepted ZEROIZE sets it to zero. |
| 2 | `CLR_STATUS` | IDLE-only write-one pulse: clears DONE, TAG_OK and all operation/programming cause bits; retains direction, all programmed input, stored output, and core state. Reads zero. |
| 3 | `ZEROIZE` | IDLE-only write-one pulse initiating sensitive-state cleanup and core reset maintenance; reads zero. |
| 31:4 | Reserved | Read zero; any write-one is a malformed command. |

Only full 32-bit CTRL values `0x0` (no-op), `0x1` (encrypt START), `0x3` (decrypt START), `0x4` (CLR_STATUS), `0x8` (ZEROIZE) are well encoded. `0x2`, `0x5`, `0x9`, START+CLR_STATUS, START+ZEROIZE, CLR_STATUS+ZEROIZE, and reserved-bit writes are malformed: no command/mode/data side effect, set `CTRL_CMD_ERR`. A well-encoded command attempted during `BUSY=1` is rejected according to Section 25.4. An IDLE-accepted START with invalid LEN is nevertheless a validly encoded command and updates retained ENC_DEC.

### 25.3 STATUS `+0x10` — precise outcome and cause ABI (D02, D03, D08)

| Bit | Symbol | Meaning |
|---:|---|---|
| 0 | `BUSY` | A crypto transaction or accepted zeroize maintenance is in progress; new START may not be accepted. |
| 1 | `DONE` | Most recently IDLE-accepted START reached a terminal outcome, **not necessarily success**. ZEROIZE does not assert DONE. |
| 2 | `TAG_OK` | Crypto completion accepted for encrypt or decrypt tag verified. Can coexist with `PROG_ERROR=1`; not sufficient for trusted FW success. |
| 3 | `ERROR` | Computed `OP_ERROR \| PROG_ERROR`; no independent stale summary flag. |
| 4 | `OP_ERROR` | Computed `LEN_ERROR \| AUTH_FAIL \| CORE_OVERFLOW`. |
| 5 | `PROG_ERROR` | Computed `BUSY_WRITE_ERR \| CTRL_CMD_ERR \| BUSY_START_ERR \| ZEROIZE_BUSY_ERR`. |
| 6 | `LEN_ERROR` | IDLE START rejected because the full 32-bit LEN exceeds 16. |
| 7 | `AUTH_FAIL` | Decrypt authentication tag mismatch. |
| 8 | `CORE_OVERFLOW` | Core ICB overflow terminal fault. |
| 9 | `BUSY_WRITE_ERR` | Programming register write rejected while BUSY. |
| 10 | `CTRL_CMD_ERR` | Malformed CTRL command, or CLR_STATUS requested while BUSY. |
| 11 | `BUSY_START_ERR` | Well-encoded START requested while BUSY. |
| 12 | `ZEROIZE_BUSY_ERR` | Well-encoded ZEROIZE requested while BUSY. |
| 13 | `ZEROIZE_ACTIVE` | Accepted zeroize/core-reset maintenance is in progress; BUSY must also be one. |
| 31:14 | Reserved | Read zero. |

`LEN_ERROR/AUTH_FAIL/CORE_OVERFLOW` are operation cause bits: clear at next IDLE-accepted START, IDLE CLR_STATUS, accepted ZEROIZE, or system reset. `BUSY_WRITE_ERR/CTRL_CMD_ERR/BUSY_START_ERR/ZEROIZE_BUSY_ERR` are sticky programming cause bits: clear **only** at IDLE CLR_STATUS, accepted ZEROIZE, or system reset; a new START does **not** hide prior programming misuse. STATUS reads never clear bits. `DONE/TAG_OK` clear on accepted START, CLR_STATUS, ZEROIZE or reset. If an input-write rejection overlaps final core success, the possible result is `DONE=1, TAG_OK=1, PROG_ERROR=1, ERROR=1`; normal FW must fail closed. STATUS summary bits always equal the OR of their constituent causes.

`BUSY` must not drop until the wrapper is actually ready to accept a subsequent START; a transient DONE pulse, core callback, or FSM cleanup step may not cause a lost back-to-back command. When ZEROIZE is active, `BUSY=1`, `ZEROIZE_ACTIVE=1` and `DONE=0`. After successful maintenance, `BUSY=0`, `ZEROIZE_ACTIVE=0` and, absent concurrent misuse, STATUS reads zero.

### 25.4 Admission, completion and error priority (D01–D04, D06, D08)

1. **System/APB reset** has highest priority; resets all software-visible registers, status, direction and the core-control epoch. A reset-aborted bus access need not return a normal completion response.
2. **Fatal Core overflow** in an active operation overrides a simultaneous successful completion/tag pulse. The wrapper must reach a bounded terminal failure (`BUSY=0, DONE=1, TAG_OK=0, CORE_OVERFLOW=1`) and prevent any late result from resurrecting a trusted output. The required internal error termination/reset is **not** a software ZEROIZE-on-BUSY exception. Feasibility and stale-pulse suppression require P13-02/04 actual VHDL/core verification; if impossible, stop and return for contract revision, not an endless BUSY presented as successful implementation.
3. **IDLE accepted ZEROIZE** supersedes stale output/status and enters maintenance as in 25.5.
4. **IDLE accepted START** clears prior operation outcome/cause and output result registers. If full `LEN<=16`, it enters crypto BUSY and constructs HDR. If LEN is invalid, no core reset/key/IV/data packet pulses are sent, `BUSY=0, DONE=1, TAG_OK=0, LEN_ERROR=1`, and prior PAYLOAD_OUT/TAG_OUT/HDR are cleared; programmed input registers are retained for diagnosis.
5. **IDLE accepted CLR_STATUS** clears only DONE/TAG_OK/error causes; leaves input, output, direction and core state intact. Data visible after CLR_STATUS has **no trust validity** despite remaining readable.
6. **BUSY invalid access** sets only the appropriate programming cause and does not mutate in-flight inputs, tag comparator state, outputs, core state or direction. Well-encoded START during BUSY -> `BUSY_START_ERR`; ZEROIZE -> `ZEROIZE_BUSY_ERR`; CLR_STATUS -> `CTRL_CMD_ERR`; a malformed CTRL -> `CTRL_CMD_ERR`; any programming KEY/IV/LEN/PAYLOAD_IN/TAG_IN write -> `BUSY_WRITE_ERR`. `CTRL=0` remains no-op. Concurrent core completion and rejected APB access must preserve both the genuine terminal outcome and new programming cause.

Every busy-time rejected APB write completes with `PREADY=1`, no AES `PSLVERR`/CPU access-fault response. `PROG_ERROR` is the error channel. The 16 programming words (4 KEY, 3 IV/SEQ, 1 LEN, 4 PAYLOAD_IN, 4 TAG_IN) remain unchanged, including live decrypt TAG_IN comparison. Normal SW must serialize access and must not attempt to modify any of these while BUSY.

### 25.5 Zeroization: C target, idle-only admission (D05, D06)

`CTRL=0x8` accepted in IDLE must clear all MMIO-visible KEY, NONCE_DIR, SEQ, LEN, PAYLOAD_IN, TAG_IN, PAYLOAD_OUT, TAG_OUT, HDR and held wrapper secrets/core-driving state, reset retained direction and clear status, and assert/release the VHDL core reset through an actual bounded maintenance sequence. Until maintenance completes, `BUSY=1` and `ZEROIZE_ACTIVE=1`, with no new START admission. At completion (`BUSY=0, ZEROIZE_ACTIVE=0`), all specified software-visible sensitive readbacks must be zero and late core events must not expose stale data. CTRL/STATUS readbacks reflect reset/maintenance semantics.

A ZEROIZE request while `BUSY=1` **must be rejected**, leaving the ongoing crypto/maintenance activity and sensitive contents unchanged while setting `ZEROIZE_BUSY_ERR`. It does not abort a hanging core. On timeout/hang, firmware cannot claim immediate key disposal; separate system reset/recovery is needed. Functional neutralization by the core reset port does **not** prove erasure of every physical flip-flop, secure key storage, resistance to side channels or a key vault. No such guarantees are claimed. Reset coverage and pulse width are P13-02/04 verification obligations.

### 25.6 Decrypt trust boundary and output lifetime (D07, D08)

The selected policy is **firmware-only authenticated output release**. The hardware may publish decrypted plaintext into raw `PAYLOAD_OUT` before tag verification and may leave it readable after a wrong-tag outcome. Raw MMIO is therefore **not** an authenticated-plaintext access-control boundary. Only the normal driver API may release bytes to application callers, and only after `DONE=1 && TAG_OK=1 && ERROR=0`. Authentication failure, programming error, overflow, invalid LEN and timeout all prohibit caller-visible plaintext/ciphertext commit. Failure outputs must be zeroed or never committed; the approved normal driver chooses **zero-initialized caller output**.

At every IDLE-accepted START, previous `PAYLOAD_OUT` and `TAG_OUT` are cleared to avoid confusing stale results with the new operation. At invalid LEN, HDR is also cleared. Under successful completion, only the first LEN bytes are valid, and result/tag remain readable until the next START, ZEROIZE or reset. `CLR_STATUS` does not erase output but removes its trusted completion evidence. Caller access assumes one serialized driver owner; competing raw MMIO agents can subvert FW-managed trust and are **not** protected by the selected hardware.

### 25.7 APB/AHB validation boundary (D10)

The **CPU-visible** path is `CPU -> AHB/APB Bridge -> AES slot 4`: the bridge must allow only precisely specified canonical aligned 32-bit offsets and reject noncanonical slot-4 offsets, byte/halfword/misaligned accesses and address aliases **before asserting AES PSEL[4]**, returning the existing two-cycle AHB ERROR. The target AES wrapper additionally must decode exact canonical local offsets using the full APB address width available at the wrapper; acceptance must not truncate to `PADDR[7:2]`. The legal canonical register words remain available; `+0x100` and all other high-bit aliases must not select them. Direct-APB reads of reserved or noncanonical local offsets return zero (RAZ); writes are ignored (WI), with no MMIO state mutation or cryptographic core side effect. Retain `PREADY=1` and no AES `PSLVERR`; local RAZ/WI does not make invalid CPU accesses successful.

Wrong-direction access to a canonical RO or WO register is a separate case from an invalid offset; this revision does not change its existing policy. In particular, a canonical RO write may receive OKAY/no-op because the bridge does not enforce register direction. The current wrapper still has the partial-decode aliases described in Section 19; exact decode and its verification are target work, not an implementation claim. APB-005 is not promoted.

### 25.8 Firmware and security integration (D11, D12)

A trusted driver validates full-width LEN and buffer arguments **before any MMIO side effect**; it enforces one operation owner, programs key/IV/SEQ/payload/tag while idle, explicitly clears stale sticky status, starts exactly one command, and polls at most a caller-specified finite count. Normal success requires `DONE && TAG_OK && !ERROR`; error cause bits determine distinct returns and recovery. `poll_budget=0` causes an immediate timeout with **no MMIO access**, after pure argument validation. For `N>0`, perform no more than N *completed STATUS reads*; a stuck bus transaction or CPU trap is not bounded by this mechanism. Failure does not publish result bytes. Hardware latency and default safe budget are **not specified** by the prior AES-001 report of 12 STATUS polls; measure PCLK START-to-DONE and firmware polling separately in P13-04.

Hardware does **not** allocate nonce/sequence values or enforce replay prevention. Firmware/protocol must ensure `(key, IV)` uniqueness for encryption, sequence persistence and appropriate anti-replay policy. No secure vault, IRQ/PLIC, DMA/streaming, physical erasure, constant-time system guarantee or SoC Health AES enable is added in P13-01. AES SoC Health remains `EXCLUDED_PENDING_CLEANUP` pending later accepted work.

### 25.9 Target acceptance criteria and current status

| AC ID | Requirement | Required observable check | Status now |
|---|---|---|---|
| `AES-AC-01` | AES-002; D01/D02 | 0..16 accepted, 17/65535/65536/65552 rejected at START; full LEN readback, no core activation; terminal DONE and cleared outputs on reject | OPEN |
| `AES-AC-02` | AES-003; D09 | MSW and big-endian-byte pack for KEY/IV/AAD/TAG/PAYLOAD, independent vectors including partial tail invalidity | OPEN (AES-001 KAT only is VERIFIED) |
| `AES-AC-03` | AES-004; D07/D08 | Wrong-tag cause and no caller plaintext; raw-MMIO early plaintext limitation documented | OPEN |
| `AES-AC-04` | AES-005; D05/D06 | All sensitive readbacks zero after completed idle zeroize; reset sequence, no late pulse, busy zeroize reject | OPEN |
| `AES-AC-05` | AES-006; D03/D04/D08 | Busy write no mutation, command encoding/retained direction, sticky causes and simultaneous done/error | OPEN |
| `AES-AC-06` | AES-007; D10 | Verify direct-APB reserved/noncanonical RAZ/WI and no side effects, reject `+0x100`/high-bit aliases, and verify invalid CPU bridge access gives two-cycle ERROR without AES PSEL; preserve separate canonical wrong-direction policy | OPEN |
| `AES-AC-07` | FW-010/FW-002; D11 | Status-returning bounded polling, zero-budget no-MMIO, no plaintext on failure and recovery handling | OPEN |
| `AES-AC-08` | D08/D11 | Overflow terminates as fault; concurrent late success suppressed, independent fault checking | OPEN |
| `AES-AC-09` | D12 | No unsupported crypto-security/vault/nonce/replay/health claims; responsibilities explicit | OPEN |

Requirement `AES-001` remains `VERIFIED` **only** for the previously approved actual-core six-case KAT (encrypt/decrypt LEN 0/7/16). AES-002..007, FW-010 and VER-006 are not promoted by target authoring; APB-005/FW-002 remain independently owned statuses. No simulation, synthesis, board run, or new evidence claim is made in P13-01.

### 25.10 Traceability and pending actions

- Owning companion: [Korean AES specification](kor/14_aes_gcm.ko.md); firmware API/ownership target: [firmware contract](19_firmware_contract.md).
- Cross-owned read-only references: [APB subsystem](05_apb_subsystem.md), [memory map](01_memory_map.md), [SoC Health](22_soc_health_firmware.md), [baseline cleanup tracker](baseline_cleanup.md).
- P13-02 implements wrapper/core integration and the register/terminal behavior; P13-03 implements firmware API; P13-04 provides actual-core independent DV and measured latency; P13-05 provides SoC CPU E2E. Target specification does not constitute implementation acceptance or verification evidence.

### D08 assurance status (non-normative)

Integrated actual-core overflow concurrent with success and late-result suppression remain **NOT_PROVEN / BLOCK_FOR_PROMOTION**, without waiver of §25.4. Legal wrapper tests used the unmodified wrapper and 14 real VHDL units. No natural overflow was observed. The low 32-bit counter reloads one and needs 4,294,967,294 increments in one epoch to reach all ones. Legal integrated transactions normally finish early; no known legal stimulus sustains that epoch and universal liveness/unreachability is unproved. Separate callback fixture and standalone real ICB boundary work do not establish integrated priority. Owner long run was NOT_RUN at #65 completion. See the [D08 runbook](../verification/directed/p13_aes_rtl/P13_08_D08_OWNER_MANUAL_RUN.md).
