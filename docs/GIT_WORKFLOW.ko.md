# Git 작업 흐름

공개 저장소를 공개 가능한 엔지니어링 내용의 source of truth로 사용한다. 기능 단위 변경마다 승인된 기준 브랜치에서 feature branch와 worktree를 만든다.

```bash
export SOC_ROOT=/path/to/soc
export PUBLIC_REPO="$SOC_ROOT/repos/SoC-ai-dev-flow-public"
git -C "$PUBLIC_REPO" worktree add "$SOC_ROOT/worktrees/feature-name" -b feature/feature-name
```

작업 순서는 다음과 같다.

1. 개발자와 Chat이 사양을 확정한다.
2. Codex가 feature worktree에서 RTL/FW를 구현하고 공개 도구 검사를 수행한다.
3. Antigravity가 같은 사양에서 독립 DV를 작성한다.
4. 필요한 경우 Codex가 공개 소스와 비공개 binding을 조합해 ModelSim/XSim 또는 벤더 CLI 작업을 실행한다.
5. 원본 산출물은 `$RUN_ROOT`, 검토·정제·비식별화한 근거와 보고서는 공개 저장소에 둔다.
6. merge 전 소스, 테스트, 출처, 생성물 제외, 근거를 함께 리뷰한다.

완전한 벤더 프로젝트, 생성 IP HDL, 원본 run 디렉터리, 개인 경로, 자격 증명, 호스트 식별자, 라이선스 서버 정보는 커밋하지 않는다. 마일스톤 벤더 프로젝트 원본은 비공개 vault에 별도로 보관하며 공개 Git 이력을 대신하지 않는다.
