# 보고서와 근거

엔지니어링 보고서는 WSL Ubuntu에서 생성한 실행 근거를 기준으로 작성한다. Codex가 Verilator, ModelSim, XSim, 벤더 CLI를 실행·분석하고, 원본 로그·파형·DB·생성 리포트는 `$RUN_ROOT`에 보관한다.

이 디렉터리에는 다음처럼 검토와 비식별화를 마친 자료만 둔다.

- 정규화한 빌드 지표와 간결한 pass/fail 요약
- 명령, 소스 revision, 툴 버전, 근거 식별자를 기록한 마일스톤 보고서
- 개인 경로, 호스트 정보, 라이선스 정보를 제거한 보드 테스트 결과
- 확인된 엔지니어링 근거에 기반한 포트폴리오 요약

Windows Work는 검토 완료 자료를 포트폴리오 문서, PDF, 발표 자료, 면접 설명으로 편집할 수 있다. 지표를 새로 만들어 내거나, 표준 엔지니어링 보고서를 대체하거나, 검토 전 원본을 최종 주장에 사용하면 안 된다.

[마일스톤 템플릿](milestones/MILESTONE_TEMPLATE.ko.md)과 [포트폴리오 요약 템플릿](portfolio/PROJECT_SUMMARY_TEMPLATE.ko.md)을 시작점으로 사용한다.
