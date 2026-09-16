# P08B Gate 0 Evidence Summary

Status: **STOP — architecture/firmware decision required**

Verified source snapshot: `2e681084c6e58578354734b1c88afb65aa5937c5` (Source Commit 1). This evidence/status layer documents that exact source snapshot; its own follow-on commit identity is not the verified source revision.

The focused Icarus/vvp detector reproduced the incompatibility at that verified source identity. CPU precise store-access-fault handling is **PASS**: the faulting store raises `mcause = 7` with `mepc = 0x00000008`; the faulting instruction does not retire normally, and no younger `x3` commit occurs. Control then redirects to the firmware default `mtvec = 0x00006d60`. With the tested 16 KiB instruction-memory alias model, that address selects word `0x0b58`, which contains zero, causing a second illegal-instruction trap (cause 2) and a trap loop. The firmware safe trap endpoint is therefore **BLOCKED**.

Detector result: `PASS_INCOMPATIBILITY_REPRODUCED` with exit code 0. Here, PASS means the detector behaved as intended; it does not mean the SoC trap endpoint is safe or that P08B may proceed.

P08B VGA production is **NOT STARTED**, and Clean Baseline v1 is **NOT RELEASED**. No VGA production implementation, Quartus/vendor build, TimeQuest analysis, or board test is represented by this evidence. Exact source, testbench, and runner identities are listed in `source_hashes.sha256`.
