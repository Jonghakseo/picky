# 비동기 작업 막대 시안 예제

[공통 런북](../../../../../runbook/swift-ui-mockup.md)을 따른다. 이 폴더는 화면별 fixture와 레이아웃 예제만 보관하며 앱 구현의 정본이 아니다.

## 파일

- [AsyncWorkMockup.swift](AsyncWorkMockup.swift): proposal 작업 막대와 production 주변 컴포넌트를 조합한 SwiftUI 하네스.
- 공통 실행 도구: [render-mockup.sh](../../scripts/render-mockup.sh), [make-gallery.py](../../scripts/make-gallery.py).

## 시안의 표시 규칙

- 접힌 제목은 `백그라운드 작업 · 실행 중` 등 현재 상태를 표시한다. batch 개수를 에이전트 개수처럼 표시하지 않는다.
- 펼치면 batch별 상태 개수와 전체 에이전트를 표시한다. 먼저 완료된 에이전트도 묶음이 진행 중이면 남긴다.
- 다른 비동기 작업은 제목·상태·시간을 별도 행에 표시한다. 에이전트 수와 비동기 명령 수를 합산하지 않는다.
- 에이전트 개수는 `개`로 표기한다.
- 실패·확인 불가가 있으면 실행 중인 다른 작업이 있어도 확인 필요를 상단에 알린다.
- 실행 완료와 결과 처리를 구분한다. 결과 처리까지 끝나면 막대와 여백을 없앤다.
- `결과 전달 실패` 장면은 **확정된 실패**를 가정한다. 상태를 알 수 없는 장면은 `상태 확인 불가`로 표시한다. 실제 적용 때 모델의 `failed`와 `unknown`을 구분해야 한다.

이 정책들은 검토용 제안이다. 앱에서 상태를 계산하고 숨기거나 복구하는 동작을 구현한 것이 아니다.

## 1:1 치수와 재사용

| 항목 | 값·구현 |
|---|---|
| 카드 폭 | `PickyHUDDockLayout.detailWidth`의 현재 기준 446pt |
| 가로 padding / 내부 폭 | 12pt / 422pt |
| 작업 행 최소 높이 | 현재 footer 기준 28pt |
| 라벨 | `PickyHUDTypography.labelSemiboldNSFont(fontScale: 1)`의 11.5pt 기준, env 배율 적용 |
| 색상·spacing·radius | 실제 `DS` 토큰 |
| 도구 기록 / 입력창 | 실제 `PickyActivitySummaryView` / `PickyConversationComposerView` |
| 바뀌는 영역 | 예제의 `ProposalFooter` |
| 작업 목록 높이 제한 | 180pt. short card의 popover 동작은 이 예제 범위 밖 |
| 좁은 폭 장면 | 카드 380pt / env 글자 배율 130% |

행 높이와 기본 폭은 현재 UI를 기준으로 고정한 예제 치수다. 실제 component policy가 바뀌면 예제도 대조해 갱신한다. 폰트 env 배율은 proposal 라벨에 적용하지만, 일부 production static font는 env만으로 커지지 않을 수 있다. 렌더를 보고 실제 적용 범위를 판단한다.

## 상태 행렬

1. 에이전트 3개 병렬 실행
2. 1개 실행 중, 2개 완료
3. 서브에이전트 + 독립 테스트·로그 수집
4. 혼합 작업, 접힌 막대
5. 실행 대기
6. 중지 확인 중
7. 실행 완료, 결과 처리 대기
8. 결과 처리 중
9. 실행 실패 + 다른 작업 실행
10. 실행 상태 확인 불가
11. 취소와 중단
12. 실행 성공, 결과 전달 실패
13. 모든 작업·결과 처리 완료, 막대 없음
14. 두 batch의 bounded 목록
15. 긴 CJK 작업 제목
16. 두 batch 전체 문서(높이 제한 해제, 실제 막대와 다름)

16개 상황 × dark/light 32개, 혼합·실패의 좁은 폭/130% 2개를 합쳐 34개 PNG를 생성한다. 시간은 정적 fixture이다. 실제 타이머·상태 전이·결과 전달·스크롤을 검증하지 않는다.

## 재현

저장소 루트에서 실행한다. 기존 Debug 빌드 준비와 안전 조건은 런북을 따른다.

```bash
SKILL=.agents/skills/picky-swift-ui-mockup
bash "$SKILL/scripts/render-mockup.sh" \
  "$SKILL/references/async-work/AsyncWorkMockup.swift" \
  build/render-gallery/async-work-proposal
```

출력에는 PNG, `manifest.json`, 소스 사본, 해당 실행의 `README.md`, `render-provenance.json`, `index.html`이 남는다. 공통 스크립트가 임시 실행 하네스를 정리한다. 사용자가 열기를 요청했을 때만 갤러리를 연다.

## 검수 지점

- 혼합 장면에서 verifier/reviewer/challenger와 테스트·로그 수집이 모두 보이는지 확인한다.
- 정상 종료한 둘의 시간을 확정 소요 시간으로 표시한다. 실패를 완료 개수에 더하지 않는다.
- 180pt를 넘는 두 batch 장면에서는 목록이 잘리는 것이 아니라 스크롤 문서의 일부만 보인다는 점을 전체 문서 장면과 대조한다. PNG만으로 실제 스크롤 성공을 주장하지 않는다.
- 좁은 폭·130%에서 상태·시간과 입력창이 보이는지, 제목 생략이 상태를 밀어내지 않는지 확인한다.
- light의 상태색 대비를 별도로 검수한다. 토큰 재사용 자체가 충분한 대비의 증거는 아니다.
- OCR은 누락·번역 키 노출·사람 단위 표기를 찾는 보조 검사이며 직접 이미지 검수를 대체하지 않는다.

공통 rasterizer의 pixel grid·material·글리프·interaction 한계는 [렌더 갤러리 문서](../../../../../docs/render-gallery.md#review-limits)를 참고한다.
