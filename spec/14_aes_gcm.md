# Baseline SoC AES-GCM Accelerator Specification

> **Status:** DRAFT — reconstructed from the active FPGA baseline and subject to Developer + ChatGPT Chat final review.
>
> **Canonical language:** English. If this file and `aes_gcm.ko.md` conflict, this file is authoritative.
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

Offsets not listed above return zero unless they alias a listed register because of the current partial decode.

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

The block exposes no `PSLVERR`, and the active AHB/APB subsystem does not propagate peripheral operation errors as CPU bus faults.

Unsupported or unused register offsets read as zero and writes are ignored.

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
| Medium | Tighten register decode and remove `0x100` aliases | current `PADDR[7:2]` decode mirrors register bank |
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
