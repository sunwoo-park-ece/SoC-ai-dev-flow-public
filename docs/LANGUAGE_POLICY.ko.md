# 문서 언어 정책

> 이 문서는 가독성을 위한 한국어 번역본입니다. 설계·구현·검증의 기준이 되는 authoritative document는 영문 원문 [`LANGUAGE_POLICY.md`](LANGUAGE_POLICY.md)입니다.

## 기본 / 기준 언어

이 저장소의 기본이자 canonical engineering language는 **영어**입니다.

별도 명시가 없는 한 다음 규칙을 따릅니다.

```text
*.md       = canonical / authoritative
*.ko.md    = 사람이 읽기 위한 한국어 companion 번역본
```

`spec/` 트리는 보다 엄격한 배치 규칙을 사용합니다.

```text
spec/NN_name.md          = canonical / authoritative 영문 specification
spec/kor/NN_name.ko.md   = 한국어 companion specification
```

숫자 prefix는 specification의 읽기/의존 순서를 보여주기 위한 것이며 authority model을 바꾸지 않습니다.

영문과 한국어 문서의 내용이 충돌하면 **영문 문서가 기준**입니다.

## 영어를 Canonical로 사용하는 이유

이 저장소에는 RTL, firmware, protocol terminology, register semantics, assertion, verification artifact, tool output, AI-agent instruction이 함께 존재합니다. 기술 contract를 영어 하나로 유지하면 전문 용어의 해석 차이를 줄이고, 영문/국문 스펙이 서로 다른 두 개의 source of truth로 갈라지는 것을 방지할 수 있습니다.

모든 agent는 의사결정과 구현 시 먼저 영문 canonical document를 기준으로 사용해야 합니다.

## 한국어 Companion 문서

한국어 companion 문서는 다음 목적을 위해 사용합니다.
- 개발자 가독성
- 설계 리뷰
- 포트폴리오 정리
- 국내 취업 / 기술 면접 준비
- 주요 engineering milestone과 설계 의사결정 설명

한국어 문서는 영문 원문의 의미를 보존해야 하며 새로운 requirement, register semantics, 측정값, architecture decision을 추가해서는 안 됩니다.

Specification의 경우 한국어 companion은 `spec/kor/` 아래에 두고 영문 원문과 동일한 숫자 prefix 및 logical basename을 사용합니다.

## 번역 대상 선정 원칙

다음과 같이 사람이 읽을 가치가 큰 문서는 `.ko.md` companion을 생성합니다.
- 저장소 전체 README / overview
- agent 역할과 workflow 규칙
- architecture overview
- 주요 milestone engineering report
- portfolio / interview summary
- 국내 리뷰 가치가 큰 주요 설계 의사결정 문서

반대로 다음 문서는 일반적으로 번역하지 않아도 됩니다.
- register-level protocol contract
- assertion definition
- generated tool report
- raw build / regression log
- 단순 directory 안내용 짧은 README
- script-specific implementation note
- machine-generated metric

모든 Markdown 파일을 기계적으로 bilingual로 만들지는 않습니다.

## Agent 준수 규칙

1. architecture, implementation, verification, integration, reporting 의사결정에는 영문 canonical document를 사용합니다.
2. Specification 작업에서는 `spec/NN_*.md`를 authoritative source로, `spec/kor/NN_*.ko.md`를 설명용 companion으로 사용합니다.
3. `.ko.md` 내용을 근거로 영문 원문을 덮어쓰거나 우선해서는 안 됩니다.
4. 한국어 companion이 존재하는 영문 문서를 수정했다면 가능하면 같은 작업에서 `.ko.md`도 동기화합니다.
5. 번역 상태가 불확실하면 영문 원문의 정확성을 우선하고, 추측하지 말고 한국어 문서에 sync 필요 상태를 명시합니다.
6. generated/raw tool evidence는 사람의 검토 가치가 분명한 경우가 아니면 번역하지 않습니다.
7. 정량 수치, 단위, commit reference, evidence link는 언어 버전 간 동일해야 합니다.
8. signal name, register name, path, command, code 등의 기술 식별자는 한국어 문서에서도 일반적으로 그대로 유지합니다.
9. 새로운 authoritative requirement는 항상 영문 canonical document에 먼저 반영합니다.
10. Specification file을 renumbering하면 같은 구조 변경에서 repository link와 companion filename도 함께 갱신합니다.

## 핵심 원칙

```text
English defines the contract.
Korean improves human readability.
One engineering truth, two reading surfaces.
```
