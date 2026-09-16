# RTL

Synthesizable RTL source lives here.

Primary owner: **WSL Codex (RTL / Firmware Implementation Engineer)**.

Typical contents:

```text
rtl/
├─ core/
├─ bus/
├─ dma/
├─ cache/
├─ peripherals/
├─ pkg/
└─ include/
```

## Implementation Unit Principle

RTL should not be treated as isolated from software-visible behavior.

Whenever practical, one SoC IP should be completed as:

```text
RTL
 -> register map
 -> C header / driver
 -> bare-metal test
```

For example:

```text
rtl/dma/**
firmware/include/axi_dma.h
firmware/drivers/axi_dma.c
firmware/tests/axi_dma_smoke_test.c
```

The RTL and firmware must implement the same authoritative behavior defined under `spec/`.

Directory details should evolve with the actual SoC architecture rather than being fixed prematurely.
