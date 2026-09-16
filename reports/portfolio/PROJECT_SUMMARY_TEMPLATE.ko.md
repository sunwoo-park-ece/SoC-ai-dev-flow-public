# Project Engineering Summary

> 이 문서는 가독성을 위한 한국어 companion template입니다. 기준 template은 영문 원문 [`PROJECT_SUMMARY_TEMPLATE.md`](PROJECT_SUMMARY_TEMPLATE.md)입니다. 실제 authoritative project summary는 영문 `.md`를 우선합니다.

## Project Overview

SoC / FPGA project의 범위, target platform, 주요 목표를 요약합니다.

## Architecture

최종 system architecture와 주요 subsystem을 설명합니다.

## My Contribution

직접 설계, 구현, 검증, 통합, 분석한 범위를 명확히 기록합니다.

## Verification Strategy

Project 전체에서 사용한 verification stack을 요약합니다.

예:
- Verilator lint / directed smoke simulation
- firmware-driven SoC simulation
- UVM regression
- assertions / functional coverage
- FPGA synthesis / implementation / STA

## Key Engineering Challenges

### Challenge 1: <title>

**Problem**

**Design / Decision**

**Verification**

**Quantitative Result**

**Trade-off**

**Evidence**

### Challenge 2: <title>

**Problem**

**Design / Decision**

**Verification**

**Quantitative Result**

**Trade-off**

**Evidence**

## Quantitative Results

검증된 project-level metric만 요약합니다.

| Metric | Baseline | Final / Best | Improvement | Evidence |
|---|---:|---:|---:|---|
| Fmax | N/A | N/A | N/A | |
| WNS | N/A | N/A | N/A | |
| LUT | N/A | N/A | N/A | |
| FF | N/A | N/A | N/A | |
| BRAM | N/A | N/A | N/A | |
| DSP | N/A | N/A | N/A | |
| Throughput | N/A | N/A | N/A | |
| Latency | N/A | N/A | N/A | |

## Lessons Learned

Architecture, RTL, verification, firmware, FPGA integration에서 얻은 핵심 lesson을 정리합니다.

## Resume Bullet Candidates

Milestone 및 tool evidence로 완전히 뒷받침되는 bullet만 작성합니다.

## Interview Story Candidates

각 강한 사례는 다음 구조를 유지합니다.

```text
Problem
 -> Analysis
 -> Design Decision
 -> Verification
 -> Quantitative Result
 -> Trade-off / Lesson
```

## Evidence Index

주요 claim을 milestone report, tool report, commit, SPEC revision 등에 연결합니다.

이 문서는 synthesis layer입니다. 기존 verified project evidence에 없는 새로운 정량 claim을 추가해서는 안 됩니다.
