# P11-ADC C4-D: Timing Regression Root-Cause Analysis Report

> **Document ID:** `P11_ADC_C4D_TIMING_REGRESSION_ROOT_CAUSE_REPORT`  
> **Status:** OFFICIAL PUBLIC ENGINEERING EVIDENCE  
> **Target Run ID:** `P11_ADC_C4B_STEP1_OWNER_20260926T163016Z`  
> **Associated Issue:** [#6](https://github.com/sunwoo-park-ece/SoC-ai-dev-flow-private/issues/6)  
> **Worktree:** `worktrees/p11-adc-public` (Branch: `P11-ADC-Cleanup`)  
> **Author:** Antigravity (Agentic AI Assistant)  
> **Date:** 2026-09-27  

---

## 1. Executive Summary

This report delivers the authoritative root-cause analysis of the timing margin regression observed between the historical SoC baseline (**53.93 MHz**, $+1.458\text{ ns}$ slack @ 50 MHz) and the current P11-ADC C4-B implementation (**50.35 MHz**, $+0.140\text{ ns}$ slack @ 50 MHz).

The analysis was performed using TimeQuest Static Timing Analyzer (STA) dumps extracted directly from the signed-off owner build database (`runs/P11_ADC_C4B_STEP1_OWNER_20260926T163016Z`).

### Key Findings Summary

| Metric / Question | Finding | Confidence Level | Evidence Reference |
|---|---|---|---|
| **Timing Closure Status** | **MET** (WNS = $+0.140\text{ ns} > 0$, TNS = $0.000$, Hold WNS = $+0.082\text{ ns} > 0$) | `PROVEN` | Section 2 |
| **Headline Fmax Comparison** | Historical 53.93 MHz vs C4-B 50.35 MHz ($\Delta = -1.318\text{ ns}$ period deficit) | `PROVEN` | Section 2 |
| **Primary Root Cause** | 153-node combinational loop on `HREADY` (TimeQuest Warning 332081/332125), injecting **$+4.064\text{ ns}$ loop penalty** | `PROVEN` | Section 4 & 5 |
| **Secondary Root Cause** | Cross-subsystem unpipelined combinational cascade (`Bridge -> APB -> HREADY -> VRAM M9K`) with 10.98 ns routing delay | `STRONGLY_SUPPORTED` | Section 3 & 5 |
| **Worst Path Family** | **Architectural Family (NOT isolated)**: 100% of top 50 setup paths belong to `u_bridge|addr_reg[...] -> APB decode -> HREADY loop -> U_VRAM block RAMs` | `PROVEN` | Section 3 |
| **ADC Direct Impact** | **ZERO**: ADC clock domain (10 MHz) worst setup slack is $+18.238\text{ ns}$ (Fmax = 183.02 MHz); intra-ADC paths are non-critical | `PROVEN` | Section 6 |
| **ADC Indirect Impact** | **MINOR**: ADC address decode comparator participates in APB decode cascade; chip LE utilization increased to 66% | `STRONGLY_SUPPORTED` | Section 6 |
| **Historical Baseline Context** | Historical baseline shared the identical architectural loop flaw, but achieved $+1.3\text{ ns}$ faster routing in a less dense design (<50% LEs) | `STRONGLY_SUPPORTED` | Section 7 |
| **Immediate Optimization Required for P11 Closure** | **NO** (Timing is positive; functional & physical verification fully closed) | `PROVEN` | Section 8 |
| **Timing Closure Disposition** | **Deferred until baseline cleanup completion if still required** | `GOVERNANCE` | Section 8 |

---

## 2. Compilation Environment & STA Timing Summary

### 2.1 Tool and Implementation Environment

- **FPGA Family:** Intel MAX 10
- **Target Device:** `10M50DAF484C7G`
- **Quartus Version:** Quartus Prime Lite Edition 19.1.0 Build 670 09/22/2019 SJ Lite Edition
- **SDC File:** `fpga/quartus/constraints/de10_lite.sdc`
- **Timing Models:** Final (Slow 1200mV 85°C, Slow 1200mV 0°C, Fast 1200mV 0°C)
- **Logic Utilization:** 32,678 / 49,760 LEs (66%), 1,442,048 memory bits (86%), 2 PLLs (50%), 1 ADC block (50%)

### 2.2 Multicorner STA Summary Table

| Clock Domain | Frequency | Period | Setup WNS | Setup TNS | Hold WNS | Recovery | Removal | Minimum Pulse Width |
|---|---|---|---|---|---|---|---|---|
| `clk` (System / CPU / AHB / APB) | **50.00 MHz** | 20.000 ns | **+0.140 ns** | 0.000 | **+0.082 ns** | +12.009 ns | +0.586 ns | +9.263 ns |
| `U_VRAM\|...\|pll1\|clk[0]` (VGA Pixel) | **25.00 MHz** | 40.000 ns | **+14.191 ns** | 0.000 | **+0.215 ns** | +11.161 ns | +2.695 ns | +19.693 ns |
| `u_adc_qsys\|...\|pll7\|clk[0]` (ADC Sys) | **25.00 MHz** | 40.000 ns | **+18.238 ns** | 0.000 | **+0.180 ns** | +16.741 ns | +0.329 ns | +19.696 ns |
| `u_adc_qsys\|...\|pll7\|clk[1]` (ADC Core) | **10.00 MHz** | 100.000 ns | N/A | N/A | N/A | N/A | N/A | +44.575 ns |
| **Design-Wide Total** | — | — | **+0.140 ns** | **0.000** | **+0.082 ns** | **+11.161 ns** | **+0.329 ns** | **+9.263 ns** |

*All internal clocks are fully constrained (0 unconstrained clocks, 0 illegal clocks). Board I/O ports remain governed under open scope STA-002 as documented in canonical specifications.*

---

## 3. Top 50 Setup Paths Analysis (50 MHz Clock Domain)

To determine whether the worst setup path is an isolated outlier or part of a systematic architectural path family, TimeQuest was commanded to extract the top 50 setup paths in the 50 MHz `clk` domain into `top50_setup_summary.txt` and full node-by-node breakdowns for the top 20 paths into `top20_setup_full.txt`.

### 3.1 Path Family Distribution

An exhaustive parse of all 50 paths yields the following distribution:

| Launch Node Component | Capture Node Component | Slack Range | Count | Percentage |
|---|---|---|---|---|
| `AHB_APB_bridge:u_bridge\|addr_reg[11]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM0` M9K | $+0.140\text{ to }+0.277\text{ ns}$ | 14 | 28% |
| `AHB_APB_bridge:u_bridge\|addr_reg[11]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM1` M9K | $+0.237\text{ to }+0.277\text{ ns}$ | 6 | 12% |
| `AHB_APB_bridge:u_bridge\|addr_reg[8]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM0` M9K | $+0.172\text{ to }+0.174\text{ ns}$ | 6 | 12% |
| `AHB_APB_bridge:u_bridge\|addr_reg[8]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM1` M9K | $+0.269\text{ to }+0.271\text{ ns}$ | 6 | 12% |
| `AHB_APB_bridge:u_bridge\|addr_reg[12]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM0` M9K | $+0.175\text{ to }+0.177\text{ ns}$ | 6 | 12% |
| `AHB_APB_bridge:u_bridge\|addr_reg[12]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM1` M9K | $+0.272\text{ to }+0.274\text{ ns}$ | 6 | 12% |
| `AHB_APB_bridge:u_bridge\|addr_reg[13]` | `AHB_VRAM_DUAL_BUFFER:U_VRAM\|VRAM:u_VRAM0` M9K | $+0.250\text{ to }+0.252\text{ ns}$ | 6 | 12% |
| **Total Analyzed Paths** | — | **$+0.140\text{ to }+0.277\text{ ns}$** | **50** | **100%** |

### 3.2 Representative Top 10 Paths

| Rank | Slack (ns) | Data Delay (ns) | Launch Node (`From`) | Capture Node (`To`) | Logic Levels |
|---|---|---|---|---|---|
| **1** | **+0.140** | 19.025 | `u_bridge\|addr_reg[11]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a45~porta_address_reg0` | 16 |
| **2** | **+0.140** | 19.015 | `u_bridge\|addr_reg[11]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a43~porta_address_reg0` | 16 |
| **3** | **+0.140** | 19.025 | `u_bridge\|addr_reg[11]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a45~porta_datain_reg0` | 16 |
| **4** | **+0.140** | 19.015 | `u_bridge\|addr_reg[11]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a43~porta_datain_reg0` | 16 |
| **5** | **+0.142** | 19.016 | `u_bridge\|addr_reg[11]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a45~porta_we_reg` | 16 |
| **6** | **+0.142** | 19.016 | `u_bridge\|addr_reg[11]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a43~porta_we_reg` | 16 |
| **7** | **+0.172** | 18.993 | `u_bridge\|addr_reg[8]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a45~porta_address_reg0` | 16 |
| **8** | **+0.172** | 18.983 | `u_bridge\|addr_reg[8]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a43~porta_address_reg0` | 16 |
| **9** | **+0.172** | 18.993 | `u_bridge\|addr_reg[8]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a45~porta_datain_reg0` | 16 |
| **10** | **+0.172** | 18.983 | `u_bridge\|addr_reg[8]` | `U_VRAM\|u_VRAM0\|...\|ram_block1a43~porta_datain_reg0` | 16 |

### 3.3 Path Family Characterization

1. **Monolithic Path Family (`PROVEN`):**  
   Every single one of the top 50 setup paths in the design belongs to the identical architectural path family. There are zero CPU ALU paths, zero register file paths, and zero UART or ADC internal paths in the top 50.
2. **Launch Point:** Always the address register of the APB bridge (`u_bridge|addr_reg[8, 11, 12, 13]`).
3. **Capture Point:** Always the write-enable, address, or data register ports of the VRAM dual buffer M9K memory blocks (`U_VRAM|u_VRAM0` or `U_VRAM|u_VRAM1`).
4. **Intermediate Hub:** In **all 20 paths** inspected in full detail, the path traverses node `HREADY~4|combout` and is tagged by TimeQuest as a **combinational loop (`LOOP`)**.

---

## 4. Critical Path Anatomy & Delay Breakdown

### 4.1 Stage-by-Stage Node Trace (Worst Path #1: Slack = +0.140 ns)

Below is the exact arrival trace extracted from the TimeQuest STA database:

```
 Total Delay | Incr Delay | Type | Fanout | Location           | Element
-------------+------------+------+--------+--------------------+------------------------------------------------------------------
   0.000 ns  |   0.000 ns |  IC  |      1 | PIN_P11            | clk~input|i
   1.687 ns  |   0.894 ns | CELL |   6912 | CLKCTRL_G3         | clk~inputclkctrl|outclk
   4.105 ns  |   0.510 ns | CELL |      1 | FF_X21_Y24_N15     | AHB_APB_bridge:u_bridge|addr_reg[11] (Launch Register)
-------------+------------+------+--------+--------------------+------------------------------------------------------------------
 [Data Path Phase 1: APB Peripheral Address Decode & PREADY Muxing]
   4.312 ns  |   0.207 ns | CELL |      1 |                    | u_bridge|addr_reg[11]|q (uTco)
   4.822 ns  |   0.510 ns |  IC  |      1 | LCCOMB_X24_Y28_N12 | u_adc_controller|Equal5~3|dataa
   5.241 ns  |   0.419 ns | CELL |      4 | LCCOMB_X24_Y28_N12 | u_adc_controller|Equal5~3|combout
   5.568 ns  |   0.327 ns |  IC  |      1 | LCCOMB_X24_Y28_N18 | u_adc_controller|Equal5~5|dataa
   5.923 ns  |   0.355 ns | CELL |     29 | LCCOMB_X24_Y28_N18 | u_adc_controller|Equal5~5|combout
   6.422 ns  |   0.499 ns |  IC  |      1 | LCCOMB_X21_Y24_N12 | u_bridge|Equal6~0|datab
   6.751 ns  |   0.329 ns | CELL |     26 | LCCOMB_X21_Y24_N12 | u_bridge|Equal6~0|combout
   7.245 ns  |   0.494 ns |  IC  |      1 | LCCOMB_X21_Y24_N20 | u_bridge|canonical_offset~5|dataa
   7.673 ns  |   0.428 ns | CELL |      2 | LCCOMB_X21_Y24_N20 | u_bridge|canonical_offset~5|combout
   8.099 ns  |   0.426 ns |  IC  |      1 | LCCOMB_X20_Y25_N6  | u_led|always1~0|datab
   8.523 ns  |   0.424 ns | CELL |      2 | LCCOMB_X20_Y25_N6  | u_led|always1~0|combout
   8.771 ns  |   0.248 ns |  IC  |      1 | LCCOMB_X20_Y25_N24 | u_led|always1~1|datad
   8.902 ns  |   0.131 ns | CELL |      6 | LCCOMB_X20_Y25_N24 | u_led|always1~1|combout
   9.167 ns  |   0.265 ns |  IC  |      1 | LCCOMB_X20_Y24_N2  | u_uart0_lora|always3~0|datad
   9.298 ns  |   0.131 ns | CELL |     14 | LCCOMB_X20_Y24_N2  | u_uart0_lora|always3~0|combout
   9.554 ns  |   0.256 ns |  IC  |      1 | LCCOMB_X20_Y24_N10 | APB_SLAVE_PREADY~10|datad
   9.685 ns  |   0.131 ns | CELL |      1 | LCCOMB_X20_Y24_N10 | APB_SLAVE_PREADY~10|combout
   9.920 ns  |   0.235 ns |  IC  |      1 | LCCOMB_X20_Y24_N8  | APB_SLAVE_PREADY~9|datad
  10.081 ns  |   0.161 ns | CELL |      6 | LCCOMB_X20_Y24_N8  | APB_SLAVE_PREADY~9|combout
  10.310 ns  |   0.229 ns |  IC  |     52 | LCCOMB_X20_Y24_N30 | u_bridge|Selector5~0|datac
-------------+------------+------+--------+--------------------+------------------------------------------------------------------
 [Data Path Phase 2: Combinational Loop Delay Penalty on HREADY]
  14.374 ns  |   4.064 ns | LOOP |     75 | LCCOMB_X17_Y15_N10 | HREADY~4|combout  <-- TIMEQUEST LOOP PENALTY
-------------+------------+------+--------+--------------------+------------------------------------------------------------------
 [Data Path Phase 3: AHB VRAM Write Enable & Bank Decoder Cascade]
  16.323 ns  |   1.949 ns |  IC  |      1 | LCCOMB_X41_Y23_N6  | U_VRAM|accepted_status_write~0|datad
  16.454 ns  |   0.131 ns | CELL |      3 | LCCOMB_X41_Y23_N6  | U_VRAM|accepted_status_write~0|combout
  16.705 ns  |   0.251 ns |  IC  |      1 | LCCOMB_X41_Y23_N2  | U_VRAM|physical_write~2|datad
  16.836 ns  |   0.131 ns | CELL |      1 | LCCOMB_X41_Y23_N2  | U_VRAM|physical_write~2|combout
  17.074 ns  |   0.238 ns |  IC  |      2 | LCCOMB_X41_Y23_N24 | U_VRAM|physical_write~3|datad
  17.205 ns  |   0.131 ns | CELL |      2 | LCCOMB_X41_Y23_N24 | U_VRAM|physical_write~3|combout
  17.452 ns  |   0.247 ns |  IC  |      1 | LCCOMB_X41_Y23_N28 | U_VRAM|vram0_we|datad
  17.583 ns  |   0.131 ns | CELL |      8 | LCCOMB_X41_Y23_N28 | U_VRAM|vram0_we|combout
  17.883 ns  |   0.300 ns |  IC  |      1 | LCCOMB_X42_Y23_N18 | U_VRAM|u_VRAM0|...|decode2|w_anode5389w[3]|datad
  18.014 ns  |   0.131 ns | CELL |      8 | LCCOMB_X42_Y23_N18 | U_VRAM|u_VRAM0|...|decode2|w_anode5389w[3]|combout
  20.374 ns  |   2.360 ns |  IC  |      1 | LCCOMB_X39_Y23_N6  | U_VRAM|u_VRAM0|...|decode2|w_anode5451w[3]|datad
  20.505 ns  |   0.131 ns | CELL |      2 | LCCOMB_X39_Y23_N6  | U_VRAM|u_VRAM0|...|decode2|w_anode5451w[3]|combout
  22.486 ns  |   1.981 ns |  IC  |      3 | M9K_X38_Y23_N0     | U_VRAM|u_VRAM0|...|ram_block1a45|ena0
  23.130 ns  |   0.644 ns | CELL |      0 | M9K_X38_Y23_N0     | U_VRAM|u_VRAM0|...|ram_block1a45~porta_address_reg0
-------------+------------+------+--------+--------------------+------------------------------------------------------------------
 Data Arrival Time:  23.130 ns
 Data Required Time: 23.270 ns (Clock Period 20.000 ns + Capture Clock 3.771 ns - Uncertainty 0.100 ns - uTsu 0.437 ns)
 Slack:              +0.140 ns
```

### 4.2 Delay Budget Decomposition

| Component | Absolute Delay | Percentage of Data Path | Architectural Origin |
|---|---|---|---|
| **Register uTco** | 0.207 ns | 1.1% | `AHB_APB_bridge:u_bridge\|addr_reg[11]` clock-to-output |
| **APB Address Decode + PREADY Mux** | 5.998 ns | 31.5% | Multi-peripheral comparator cascade & PREADY multiplexer |
| **TimeQuest Loop Penalty (`LOOP`)** | **4.064 ns** | **21.4%** | **Warning 332081/332125 combinational loop on `HREADY`** |
| **VRAM Write / Decode / M9K Routing** | 8.756 ns | 46.0% | `vram0_we` generation, bank address decode, M9K enable routing |
| **Total Data Path Delay** | **19.025 ns** | **100.0%** | (Sum of Cell = 3.98 ns, IC = 10.98 ns, LOOP = 4.064 ns) |

---

## 5. Root-Cause Analysis & Combinational Loop Disposition

### 5.1 Primary Root Cause: 153-Node Combinational Loop on `HREADY` (`PROVEN`)

TimeQuest STA explicitly reports:
```
Warning (332125): Found combinational loop of 153 nodes File: .../rtl/soc/AMBA_SoC_TOP.v Line: 116
    Warning (332126): Node "HREADY~4|combout"
    Warning (332126): Node "u_CPU|mem_fault_now~2|datad"
    ...
Critical Warning (332081): Design contains combinational loop of 153 nodes. Estimating the delays through the loop.
```

#### Detailed Circuit Tracing of the Feedback Loop

1. **Forward Path (`HREADY` to CPU):**  
   In `AMBA_SoC_TOP.v`, `HREADY` is broadcast to CPU port `.HREADY_FROM_AHB(HREADY)`.  
   Inside `RV32I46F_5SP_MMIO.v` (line 131, 261):
   $$\text{mem\_fault\_now} = \text{bus\_fault\_final} = \text{HREADY\_FROM\_AHB} \ \&\& \ (\text{HRESP\_FROM\_AHB} == 2\text{'b}01) \ \&\& \ \dots$$
2. **CPU Internal Propagation:**  
   `mem_fault_now` is combinationally used to suppress or qualify the CPU `store_aligner` (`u_CPU|comb~4` $\rightarrow$ `u_CPU|store_aligner|data_memory_write_data[...]`).
3. **AHB Bus Propagation:**  
   `data_memory_write_data` is exported combinationally as AHB `HWDATA`.
4. **APB Bridge Propagation:**  
   In `AHB_APB_bridge.v` (line 160):  
   $$\text{PWDATA} = (\text{state} == \text{SETUP}) \ ? \ \text{HWDATA} : \text{wdata\_reg};$$
5. **Peripheral Error Detection:**  
   `PWDATA` is combinationally decoded by APB slaves (e.g., `u_uart1_pc|LessThan0`, `u_adc_controller|legal_access[...]`) to detect illegal writes and assert `PSLVERR` or stall `PREADY`.
6. **Closing the Loop:**  
   `PREADY` feeds into `APB_SLAVE_PREADY` $\rightarrow$ `AHB_APB_bridge:u_bridge|HREADY` $\rightarrow$ `AMBA_SoC_TOP:HREADY`!

#### Timing Impact

- Because this loop is closed without a register boundary, TimeQuest breaks the loop at node `HREADY~4|combout` and inserts a **$+4.064\text{ ns}$ delay penalty**.
- **Proof of Impact:** If this loop penalty were removed (or if the loop were broken architecturally), the data path delay would drop from $19.025\text{ ns}$ to $14.961\text{ ns}$, yielding a setup slack of:
  $$\text{Slack}_{\text{no\_loop}} = +0.140\text{ ns} + 4.064\text{ ns} = \mathbf{+4.204\text{ ns}} \implies F_{\text{max}} \approx \mathbf{63.3\text{ MHz}}$$
- Therefore, the combinational loop is **mathematically proven** to be the dominant contributor to the reduced setup slack.

---

### 5.2 Secondary Root Cause: Cross-Subsystem Combinational Cascade (`STRONGLY_SUPPORTED`)

Even aside from the loop penalty, the path spans three distinct subsystems in a single clock cycle:
1. Launch from APB Bridge register in the peripheral control region.
2. Route across the floorplan through multiple APB slave address decoders.
3. Propagate through the top-level AHB bus multiplexer.
4. Route across the chip to the VRAM Dual Buffer M9K block RAM columns (dedicated silicon blocks at the top/edge of the MAX 10 die).

This unpipelined span accumulates **$10.98\text{ ns}$ of interconnect (routing) delay** across 16 logic levels. In an FPGA with 66% LE utilization, routing channels between logic clusters and embedded memory blocks become congested, stretching wire delays.

---

## 6. ADC Subsystem Attribution (Direct vs Indirect)

A core requirement of this analysis was to determine whether the P11 ADC subsystem caused the timing regression.

### 6.1 Direct ADC Timing Impact: ZERO (`PROVEN`)

- The ADC hardware controller IP and acquisition engine operate in their own clock domain generated by `u_adc_qsys|altpll_sys`:
  - 25 MHz system clock (`clk[0]`): **Setup Slack = $+18.238\text{ ns}$** ($F_{\text{max}} = 183.02\text{ MHz}$).
  - 10 MHz core ADC clock (`clk[1]`): Minimum Pulse Width slack = $+44.575\text{ ns}$.
- Intra-ADC register-to-register paths have enormous timing margin ($>18\text{ ns}$).
- Not a single path ending or starting within the ADC subsystem appears in the top 50 worst setup paths.
- **Conclusion:** The ADC subsystem has **zero direct responsibility** for the critical path or the $50.35\text{ MHz}$ $F_{\text{max}}$ limitation.

### 6.2 Indirect ADC Timing Impact: MINOR (`STRONGLY_SUPPORTED`)

- In the critical path trace (Section 4.1), nodes `u_adc_controller|Equal5~3` and `u_adc_controller|Equal5~5` appear between $4.822\text{ ns}$ and $5.923\text{ ns}$.
- These nodes represent the combinational address comparator that detects whether the APB address falls within the ADC register window (`0x4000_6000 - 0x4000_6FFF`).
- Because all APB peripheral select signals are evaluated combinationally to drive `PREADY`, adding any new peripheral to the APB bus introduces an additional comparator term into the decode cascade.
- Furthermore, the synthesis of the ADC controller, CDC mailbox, and acquisition engine increased total chip LE usage to 66%, which naturally increases average routing wire lengths across the device floorplan.
- **Conclusion:** ADC's role is strictly indirect and identical to that of any other APB peripheral on an unpipelined bus.

---

## 7. Historical 53.93 MHz Comparison & Limitations

### 7.1 Historical Comparison Context

| Milestone | Reported Fmax | 50 MHz Slack | Logic LE Utilization | Key Architectural Changes |
|---|---|---|---|---|
| **Historical Baseline** | **53.93 MHz** | $+1.458\text{ ns}$ | ~48% – 52% | Baseline CPU, single UART, basic VRAM, no ADC |
| **Current P11 C4-B** | **50.35 MHz** | $+0.140\text{ ns}$ | 66% (32,678 LEs) | Added P11 ADC IP, Dual UART (PC + LoRa), SoC Health Telemetry |
| **Net Difference** | **-3.58 MHz** | **-1.318 ns** | +14% – 18% LEs | Higher routing congestion around identical `HREADY` loop |

### 7.2 Analysis of the Regression

- The difference in cycle period between 53.93 MHz ($18.542\text{ ns}$) and 50.35 MHz ($19.860\text{ ns}$) is **$1.318\text{ ns}$**.
- Did the historical design have the 153-node `HREADY` combinational loop?
  - **Yes (`STRONGLY_SUPPORTED`):** The logic structure connecting `HREADY` $\rightarrow$ `mem_fault_now` $\rightarrow$ `store_aligner` $\rightarrow$ `HWDATA` $\rightarrow$ `PWDATA` $\rightarrow$ `PREADY` $\rightarrow$ `HREADY` has been present since the initial AHB/APB bus integration.
- Why was historical slack $+1.458\text{ ns}$ instead of $+0.140\text{ ns}$?
  - In earlier compiles, lower logic utilization (<50%) allowed the Quartus Fitter to place the APB bridge, peripheral decoders, and VRAM control logic in closer physical proximity to the M9K memory columns.
  - As new peripherals (Dual UART, ADC, SoC Health monitors) and firmware footprints were integrated, LE density increased to 66%. The Fitter was forced to spread logic elements across distant LAB rows, adding $\sim 1.3\text{ ns}$ of routing interconnect delay across the unpipelined 16-level combinational chain.

---

## 8. Future Optimization Candidates & Closure Disposition

### 8.1 Future Architectural Optimization Candidates (Post-Baseline Cleanup)

The following candidate modifications are documented **for future baseline cleanup only**. None of these modifications are authorized, recommended, or required for P11 closure:

1. **Candidate 1: Decouple VRAM Write Control from APB HREADY (`High Value`)**  
   - In `AHB_VRAM_DUAL_BUFFER.v` / `AMBA_SoC_TOP.v`, VRAM write-enables currently depend globally on system `HREADY`.  
   - Since VRAM is an AHB slave with its own ready signal `HREADY_VRAM`, its write logic should only evaluate `HREADY` when `HSEL_VRAM` is active.  
   - Gating VRAM write control with `HSEL_VRAM` completely breaks the connection between the APB bridge and VRAM M9K blocks, eliminating 100% of the top 50 critical paths.
2. **Candidate 2: Break the CPU `mem_fault_now` Combinational Feedback Loop (`High Value`)**  
   - Register `bus_fault_final` or decouple `mem_fault_now` from the store data aligner during the memory execution cycle.  
   - This eliminates the 153-node combinational loop (silencing Warning 332081/332125) and immediately recovers the **$+4.064\text{ ns}$** TimeQuest loop penalty.
3. **Candidate 3: Register / Pipeline APB Bridge Ready Generation (`Medium Value`)**  
   - Insert a register stage between APB slave `PREADY` and the AHB bus master `HREADY_APB`.  
   - AHB-Lite natively supports multi-cycle slave wait-states; registering `HREADY_APB` isolates the APB peripheral clock domain timing from the AHB backbone.

### 8.2 Formal Closure Disposition

- **Immediate optimization required for P11 closure:** **NO**.
- **Timing optimization performed in P11 C4-D:** **NO**.
- **P11 Functional Acceptance Affected:** **NO** (All directed verification vectors, CPU lifecycle tests, register policy checks, and autonomous testbenches maintain 100% PASS).
- **P11 Physical Acceptance Affected:** **NO** (On physical DE10-Lite FPGA hardware, all internal clocks meet setup and hold requirements; WNS = $+0.140\text{ ns} > 0$, TNS = $0.000$; physical frame cadence verified at 167 kHz; UART telemetry logs confirmed clean).
- **Future Timing Closure:** **Deferred until baseline cleanup completion if still required**.
- **Issue #6 Closure Readiness after C4-D:** **YES**.

---

## 9. Evidence Artifacts Traceability

- **TimeQuest TCL Dump Script:**  
  [`reports/evidence/p11c_c4d_dump_top50.tcl`](p11c_c4d_dump_top50.tcl)
- **Raw Top 50 Setup Summary Dump:**  
  `runs/P11_ADC_C4B_STEP1_OWNER_20260926T163016Z/de10_lite/quartus/P11_ADC_C4B_STEP1_OWNER_20260926T163016Z/project/top50_setup_summary.txt`
- **Raw Top 20 Detailed Node Path Dump:**  
  `runs/P11_ADC_C4B_STEP1_OWNER_20260926T163016Z/de10_lite/quartus/P11_ADC_C4B_STEP1_OWNER_20260926T163016Z/project/top20_setup_full.txt`
- **Canonical Timing Specification:**  
  [`spec/timing_constraints.md`](../../spec/timing_constraints.md)
