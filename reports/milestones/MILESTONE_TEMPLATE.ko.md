# Milestone: <title>

> 이 문서는 가독성을 위한 한국어 companion template입니다. 기준 template은 영문 원문 [`MILESTONE_TEMPLATE.md`](MILESTONE_TEMPLATE.md)입니다. 실제 authoritative milestone record는 영문 `.md`를 우선합니다.

## 1. Objective

이번 milestone의 engineering 목표를 설명합니다.

## 2. Baseline / Initial Architecture

시작 시점의 설계 구조와 관련 constraint를 기록합니다.

## 3. Problem / Limitation

관측된 issue, bottleneck, failure mode, limitation을 설명합니다.

## 4. Design Decision

선택한 변경사항과 다른 대안 대신 해당 방식을 선택한 이유를 설명합니다.

## 5. Implementation

결정을 실제로 반영한 RTL / firmware / verification 변경사항을 요약합니다.

## 6. Verification Strategy

정확성을 어떤 방식으로 검증했는지 기록합니다.

예:
- Verilator lint / smoke simulation
- firmware-driven SoC simulation
- UVM regression
- assertion / coverage result
- FPGA synthesis / implementation
- timing analysis

## 7. Quantitative Results

실제로 측정된 값만 기록합니다.

| Metric | Before | After | Delta | Evidence |
|---|---:|---:|---:|---|
| Fmax | N/A | N/A | N/A | |
| WNS | N/A | N/A | N/A | |
| TNS | N/A | N/A | N/A | |
| LUT | N/A | N/A | N/A | |
| FF | N/A | N/A | N/A | |
| BRAM | N/A | N/A | N/A | |
| DSP | N/A | N/A | N/A | |
| Throughput | N/A | N/A | N/A | |
| Latency | N/A | N/A | N/A | |

해당하지 않는 metric은 제거하고 필요한 project-specific metric을 추가합니다.

## 8. Before vs After

변경 전/후의 architecture 및 behavior 차이를 간결하게 요약합니다.

## 9. Trade-offs

개선을 위해 받아들인 비용을 기록합니다.

예:
- CPI increase
- additional latency
- additional area
- more control complexity
- corner case에서의 peak throughput 감소

## 10. Lessons Learned

이후 설계 판단에 재사용할 engineering insight를 기록합니다.

## 11. Resume / Interview Key Points

위 evidence에서 직접 도출되는, 기술적으로 방어 가능한 핵심 포인트를 작성합니다.

범위를 과장하거나 검증되지 않은 결과를 주장하지 않습니다.

## 12. Evidence References

다음처럼 추적 가능한 source를 기록합니다.
- SPEC path / revision
- Git commit / PR / diff
- simulation report
- regression report
- Quartus / Vivado timing report
- utilization report
- script output

## Evidence Classification

필요할 때 다음 label을 사용합니다.

- **Measured Fact** — simulator / FPGA tool output이 직접 뒷받침
- **Design Interpretation** — 측정 결과에 대한 engineering 해석
- **Trade-off** — 개선을 위해 받아들인 비용

값을 검증할 수 없으면 추정하지 말고 **N/A / unavailable**로 기록합니다.
