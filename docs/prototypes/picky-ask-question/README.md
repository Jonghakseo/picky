# ask_user_question 렌더링 개선 시안

상태: 검수용 제안 시안이다. 앱과 PWA에 연결되지 않는다. 열기: `open docs/prototypes/picky-ask-question/index.html`

토큰과 페이지 틀은 `../picky-remote-pwa/`의 `tokens.css`, `base.css`, `theme.js`, `board.*`를 그대로 쓴다. `?theme=light|dark`, `?scale=1.3`이 동작한다.

| 파일 | 내용 |
|---|---|
| `index.html` | 문제 → 개선 표와 세 열(현재 / Mac SwiftUI 렌더 / 폰) 보드 |
| `before.html` | 현재 구현의 PWA 이식본. `picky-remote-pwa/question.html`의 폼·접힘 상태 |
| `swift/AskQuestionMockup.swift` | Mac 피클 버블과 메인 Picky 패널의 SwiftUI 제안 목업. "현재" 장면은 production `PickyQuestionBubbleView`, `PickyMainQuestionPanelView`를 그대로 렌더한다 |
| `pwa.html` | 폰 PWA 상태 P1–P4 (HTML) |
| `ask.css` | PWA 시안 컴포넌트. `.is-touch`만 터치 밀도로 바꾼다 |

Mac 렌더(14개 상황 × 라이트/다크 = 28장):

```bash
bash .agents/skills/picky-swift-ui-mockup/scripts/render-mockup.sh \
  docs/prototypes/picky-ask-question/swift/AskQuestionMockup.swift \
  build/render-gallery/ask-question-swift
open build/render-gallery/ask-question-swift/index.html
```

하네스는 `/private/tmp/PickyAgentDD`의 Debug 모듈에 링크하고 앱·데몬에 연결하지 않는다. 절차는 `runbook/swift-ui-mockup.md`. 렌더는 정적 모양만 보여 준다. hover·포커스 링은 고정 상태로 그린 것이고 키 입력·IME·스크롤은 검증하지 않는다. `PickyHUDTypography` 정적 폰트는 `pickyAppFontScale` 환경값을 받지 않아 130% 장면을 넣지 않았다.

## 결정 카드

- 첫 시선: 질문 제목과 선택지. 상태 머리줄은 아이콘 + "입력이 필요해요"만 남기고 method 이름을 지운다.
- 색: 입력 대기는 warning이 아니다(`design/COMPONENTS.md` Question 절). 중립 바탕에 Action Blue 테두리, 제출 버튼도 파랑. 답변 완료는 success 체크, 건너뜀은 회색.
- 주 행동: 제출(마지막 단계) 또는 다음. 보조: 이전, 건너뛰기.
- 선택 모양: radio는 원, checkbox는 네모. checkbox 질문에는 "여러 개 고를 수 있어요"를 붙인다.
- 기타: 선택지 끝의 "직접 입력" 행 하나. 고르면 행 안에 입력칸이 열리고 포커스가 간다.
- 질문 여러 개: 2개 이상이면 단계 진행. `PickyMainQuestionPanelViewModel.usesSteps`와 같은 규칙이라 메인 질문 패널과 피클 버블이 같은 문법이 된다. 앞 단계 답은 칩으로 보이고 누르면 돌아간다.
- 답변 뒤: 접힌 줄에 답 요약, 펼치면 질문 라벨·답 두 열. 컨트롤을 다시 그리지 않는다.
- Mac 키보드: 질문에 포커스가 있을 때 1–9 선택, ↩ 다음·제출. 입력칸에 포커스가 있으면 숫자 키는 글자로 들어간다. 피클 버블에서 esc는 HUD의 기존 의미와 겹치므로 건너뛰기에 붙이지 않고, 메인 패널은 지금처럼 esc가 건너뛰기다.
- 폰: 행 높이 44pt, 제출 버튼 넓게, 키 힌트 숨김. 질문 버블이 화면 밖일 때만 입력창 위 고정 바를 띄운다.

검토했지만 고르지 않은 안: 질문 여러 개를 지금처럼 한 버블에 모두 펼치고 번호만 붙이는 안. 질문 2개짜리 짧은 폼에는 더 빠르지만, HUD 카드 높이가 크게 바뀌고 메인 질문 패널과 문법이 갈린다. 검수에서 짧은 폼이 더 낫다고 보면 "질문 2개 이하이고 모두 radio일 때만 펼침" 같은 예외 규칙을 따로 정한다.

## 메인 Picky 질문 패널

현재 `PickyMainQuestionPanelView`(커서 옆 360pt 패널)는 원/네모 표시와 단계 진행을 이미 갖고 있다. 피클 버블보다 앞서 있는 부분이라, 개선안은 이 패널의 문법을 피클로 옮기고 패널에는 아래만 더한다.

- 출처: 커서 옆에 갑자기 뜨는데 누가 묻는지 표시가 없다. 머리줄에 "Picky가 물어봐요"와 단계 `2 / 3`.
- 본문: 피클 버블과 같은 `ProposalQuestionBody`. 단계 막대, 앞 답 칩, 직접 입력 행, 숫자 키.
- 색: 필수 `*`와 필수 안내가 warning 색이다. "필수" 글자와 destructiveText 한 줄로 바꾼다. 패널 테두리는 옅은 파랑.
- 건너뛰기: 흐린 "esc 취소" 글자 대신 "건너뛰기 [esc]" 버튼.
- 음성: 질문 대기 중 새 입력이 들어오면 질문을 닫고 그 입력을 답으로 해석하라고 모델에 알린다(`CompanionManager`, 메인 세션 질문 불변식). 그래서 "말로 답해도 돼요"는 실제 동작이다. 문구만 더하고 동작은 바꾸지 않는다.
- 보내기 실패: 지금처럼 패널을 닫지 않고 다시 시도.

## 새 문구 (UX writing 검수 대상)

| 키 | ko | en | 바꾸는 것 |
|---|---|---|---|
| `hud.question.otherInput` | 직접 입력 | Type your own | `hud.question.other` "기타…" |
| `hud.question.skip` | 건너뛰기 | Skip | askUserQuestion/select의 `common.cancel` "취소" |
| `hud.question.skipped` | 건너뜀 | Skipped | `hud.question.cancelled` "취소됨" |
| `hud.question.hint.multiple` | 여러 개 고를 수 있어요 | Choose any | 없음 |
| `hud.question.hint.required` | 필수 | Required | 없음 |
| `hud.question.answerAction` | 답하기 | Answer | 없음(폰 고정 바) |
| `hud.question.mainAsks` | Picky가 물어봐요 | Picky is asking | 메인 패널 머리줄(지금은 없음) |
| `hud.question.voiceHint` | 말로 답해도 돼요 | You can answer by voice | 없음(메인 패널) |

"취소 → 건너뛰기" 근거: 취소하면 `agentd/src/runtime/ask-user-question-tool.ts`가 "답 없이 닫혔으니 판단대로 계속하라"는 결과를 Pi에 돌려준다. 작업이 멈추는 게 아니라 질문만 넘어가므로 "건너뛰기"가 실제 동작과 맞다. confirm은 거절 의미가 있어 "취소"를 유지한다.

재사용 문구: `hud.question.needed`, `hud.question.answered`, `hud.question.submit`, `hud.question.previous`, `hud.question.next`, `hud.question.required`, `hud.question.sendFailed`, `hud.error.retry`, `hud.question.allow`.

## 구현할 때 필요한 것

- 답 요약(M6, P4)은 지금 데이터로는 그릴 수 없다. `PickyExtensionUiRequest`에 답이 남지 않고 버블은 `isActiveRequest`만 안다. agentd가 답을 받을 때 요청 기록에 `answer`(질문 키 → 표시용 문자열)를 남기고 Swift·TS 모델에 필드를 추가해야 한다. 프로토콜 변경이므로 Swift/TS 호환 검사가 필요하다.
- 단계 상태와 키 처리: `PickyMainQuestionPanelViewModel`의 단계 로직을 버블도 쓰도록 꺼내고, 질문 본문 View도 하나로 합친다(목업의 `ProposalQuestionBody`). 지금은 `PickyQuestionBubbleView`와 `PickyMainQuestionPanelView`가 선택지 행을 따로 그려서 모양이 이미 갈라져 있다. PWA는 `agentd/web/src/room/policy/question.ts`에 같은 규칙을 둔다.
- 폰 고정 바: 질문 버블의 화면 노출 여부(IntersectionObserver)로만 띄운다. 바에서 직접 답하는 UI는 만들지 않는다.
- 선택지 설명(`description`)은 지금도 데이터가 있으므로 바로 쓸 수 있다.
