# 메신저형 Picky/Pickle UX 설계 (2026-10)

상태: 구현됨(2026-10-02). 아래 표의 타입이 제품 경로에 연결되어 있다.
시안 렌더: `./scripts/render-ui-gallery.sh messenger-ux` → `build/render-gallery/messenger-ux/`

시안의 모든 화면은 아래 표의 production 컴포넌트를 그대로 렌더한다. 승인되면 같은 타입을 기존 경로에 연결만 하면 된다.

| 영역 | 새/변경 타입 | 파일 | 연결 지점(승인 후) |
|---|---|---|---|
| 화면 번역 오버레이 | `PickyAnnotationTextOverlayView`, `PickyAnnotationTextLayoutPolicy` | `Picky/Overlay/PickyAnnotationTextOverlayView.swift` | `PickyAgentAnnotationOverlayView` 의 `.text` shape 분기 |
| 메인 활동 칩 간결화 | `PickyMainActivityConcisePolicy`, `PickyMainActivityChipPresentation(models:)` | `Picky/Overlay/PickyMainActivityChipPolicy.swift`, `PickyMainActivityChipView.swift` | `PickyMainActivityChipPresentationCache.update` |
| Pickle 작업 중 표시 | `PickyConversationPresenceRow`, `PickyConversationPresencePresentation` | `Picky/HUD/Conversation/Bubbles/PickyConversationPresenceRow.swift` | `PickyTurnCardView` 의 `PickyToolCallInlineRow` 자리 |
| Pickle 날짜 구분선 | `PickyConversationDateDivider`, `PickyConversationDateDividerPolicy` | `Picky/HUD/Conversation/Bubbles/PickyConversationDateDivider.swift` | 턴 카드의 챕터 머리줄 자리 |
| 이전 답변 펼치기 | `PickyAgentBubbleView` (변경) | `Picky/HUD/Conversation/Bubbles/PickyAgentBubbleView.swift` | 이미 연결됨 |
| Pickle 전송 시각 | `PickyBubbleTimestamp`, `PickyBubbleTimestampAccessory` | `Picky/HUD/Conversation/Bubbles/PickyBubbleTimestamp.swift` (+ 두 버블 surface) | `PickyConversationListView` 에서 버블 `timestamp:` 인자 전달 |

---

## 1. Picky 메인: 도구는 숨기고 결과는 화면에

### 1-1. 활동 칩 노출 규칙

지금 커서 옆 칩(`PickyMainActivityChipStackView`)은 모든 도구를 `도구명 + 인자` 로 보여준다(`bash  rg -n "..."`, `read  Foo.swift`). 메인 에이전트는 대화 상대이므로, 사람이 읽을 문장이 있는 도구만 남긴다.

| 활동 | 표시 | 예시 |
|---|---|---|
| bash / bash_async + `title` | title만, 도구명 없이 | `● 런타임 계약 파일 조사` |
| bash / bash_async, title 없음 | 숨김 | 명령 원문은 노출하지 않는다 |
| recall / vcc_recall | `기억 찾기` + query | `◈ 기억 찾기  메신저 디자인` |
| remember | `기억 저장` + title | `◈ 기억 저장  번역 오버레이 규칙` |
| forget | `기억 삭제` | `◈ 기억 삭제` |
| Pickle 도구(`picky_start_pickle` 등) | 기존 Pickle 칩 유지 | 파란 칩 |
| 생각 중 | `생각 중...` 만, 생각 내용은 표시하지 않음 | `● 생각 중...` |
| 질문 대기 | 기존 waiting 칩 유지 | |
| web_search | `웹 검색` + 검색어 | `● 웹 검색  SwiftUI TimelineView 성능` |
| MCP 도구(직접 `mcp__서버__도구` 또는 codemode 안의 호출) | `{서버} MCP 사용 중` 으로 통일, 인자 없음 | `● creatrip MCP 사용 중` |
| 그 외(read, grep, edit, fetch_content, todo …) | 숨김 | |
| 위 규칙으로 보일 칩이 없지만 이번 응답에서 도구를 쓰는 중 | `작업 중` 한 개, 응답이 끝날 때까지 유지 | 숨김 도구 사이에서 깜빡이지 않게 |

규칙은 `PickyMainActivityConcisePolicy.models(for:)` 한 곳에 둔다. 피클 대화 UI(`PickyToolCallInlineRow`)는 바꾸지 않는다. 사용자가 범위를 Picky 메인으로 한정했다.

### 1-2. 화면 번역/설명 DSL: `TEXT`

번역을 채팅이나 음성으로 길게 읽어 주는 대신, 원문 옆에 말풍선으로 붙인다. 원문을 덮어쓰는 방식(Google Lens식)은 쓰지 않는다.

```text
[TEXT: x=<n> y=<n> w=<n> h=<n> text="번역문"]
```

- `x y w h` 는 원문 텍스트 영역(스크린샷 픽셀, 좌상단 원점). 기존 RECT와 같은 좌표계와 clamp 규칙.
- `text` 는 필수, 최대 500자. `\n` 줄바꿈 허용.
- 원문은 그대로 보이고, 영역 아래 얇은 밑줄과 꼬리 달린 말풍선이 붙는다.
- `spotlight`, `label`, `mode` 는 받지 않는다.

렌더 규칙(`PickyAnnotationTextLayoutPolicy`):

| 항목 | 규칙 | 근거 |
|---|---|---|
| 원문 표시 | 영역 아래 1.5pt, 75% 불투명도 팔레트 색 밑줄(`PickyAnnotationVisualStyle`) | 어느 글자에 대한 말풍선인지 연결 |
| 말풍선 크기 | 최대 폭 280pt, `PickyHUDTypography.bodyCompact`, 최대 8줄 | |
| 말풍선 위치 | 아래 → 위 → 오른쪽 → 왼쪽 순으로, 화면 안에 있고 앞서 놓인 말풍선·다른 밑줄 영역과 겹치지 않는 첫 자리. 모두 겹치면 겹침 면적이 가장 작은 자리 | 여러 문단을 한 번에 번역해도 서로 가리지 않게 |
| 배치 순서 | 태그 순서(읽는 순서) | |
| 수명 | 기존 어노테이션과 동일: 장면이 바뀌거나 사용자가 닫을 때까지 | 새 타이머 없음 |

와이어 변경(승인 후):

- agentd `AnnotationShape` 에 `"text"`, `AnnotationInput` 에 `text?: string`.
- `annotation-dsl.ts` `KNOWN_VERBS` 에 `TEXT`, 허용 키 `x y w h text`.
- Swift `PickyAnnotationOverlayShape.text`, `PickyAnnotationOverlayAnnotation.text`, `PickyAgentAnnotation.text`.
- 앱과 agentd는 함께 배포되므로 별도 버전 게이트는 두지 않는다(확장 변경).

### 1-3. 시스템 프롬프트 초안 (`picky-runtime-contract.ts`)

`buildReplyStyleSection` 의 3번을 아래로 교체하고, 시각 오버레이 섹션에 TEXT 규칙을 추가한다.

```text
3. Keep every reply short: one or two sentences by default, never more than three unless the user asks for detail. Lead with the answer. Do not narrate which tools you used, restate the question, or add closing offers.
5. When the screen already shows the result (translation, labels, highlights), say only what the user needs to know beyond it, e.g. "번역을 화면에 띄웠어요."
```

```text
To translate or explain on-screen text, prefer TEXT over a long spoken answer.
- [TEXT: x=<number> y=<number> w=<number> h=<number> text="translated text"] attaches a bubble with the translation beside the original text box. Use the tight bounds of the original text block.
- Emit one TEXT per text block, in reading order. Do not read the translations aloud again.
```

---

## 2. Pickle: 메신저형 대화

### 2-1. 작업 중 표시 (`PickyConversationPresenceRow`)

지금은 진행 중 턴 안에 `⌨ bash  rg -n ...  ●` 같은 도구 행과 접히는 "생각 과정" 블록이 대화 사이에 끼어든다. 메신저에서는 상대가 무엇을 하는지 마지막 말풍선 아래 한 줄로만 알려 준다.

```text
[ ● ● ● ]  작업 중 · 테스트 실행 중                0:42
```

- 위치: 진행 중 턴의 마지막 버블 아래, 에이전트 쪽(왼쪽) 정렬. 응답 버블이 나오기 시작해도 턴이 끝날 때까지 유지.
- 왼쪽 점 세 개 버블: 에이전트 버블과 같은 모양(`PickyConversationBubbleLayout.bubbleShape(side: .agent)`)의 작은 버전. 실행 중에만 점이 순차로 깜빡이고 Reduce Motion에서는 정지.
- 클릭하면 기존처럼 도구 기록을 연다(`onOpenActiveToolHistory`).

상태와 문구(`PickyConversationPresencePresentation`):

| 상태 | 제목 | 세부(있을 때만) |
|---|---|---|
| 생각 중(thinking 스트리밍, 도구 없음) | 생각 중 | 없음 |
| 도구 실행 중 | 작업 중 | 아래 우선순위. 도구가 끝나면 바로 `생각 중`으로 돌아감 |
| 질문 대기 | 입력 대기 | 없음 (질문 버블이 따로 있음) |

세부 문구 우선순위. 사람이 쓴 설명만 쓰고 명령·경로·JSON은 쓰지 않는다.

1. 진행 중 todo의 `activeForm` (`테스트 실행 중`)
2. bash / bash_async `title`
3. 스킬 이름 (`스킬 · picky-design-guide`)
4. subagent 에이전트 이름 (`worker에게 맡김`)
5. 없음 → `작업 중` 만

경과 시간은 턴 시작 기준 `m:ss`, 기존 턴 헤더 타이머와 같은 값.

### 2-2. 전송 시각 (`PickyBubbleTimestamp`)

- 말풍선 끝 옆, 아래쪽에 맞춰 `오전 10:15` 형식(meta, textTertiary). Pickle 말풍선은 오른쪽 끝 옆, 내 말풍선은 왼쪽 끝 옆(카카오톡 위치).
- 평소에는 숨기고 그 말풍선 행에 포인터를 올렸을 때만 보인다. 모든 말풍선이 각자 시각을 가진다.
- 아직 Pickle에 전달되지 않은 메시지는 호버와 상관없이 시계 아이콘(`clock`)을 계속 보여 준다. 텍스트는 VoiceOver 라벨 `보내는 중` 으로만 둔다.
- 수신·읽음 체크는 넣지 않는다.
- 구현: 버블 surface(AppKit)가 이미 실제 말풍선 폭을 계산하므로 `PickyBubbleTimestampAccessory` 가 그 옆에 라벨을 둔다. 시간이 있는 말풍선은 최대 폭에서 60pt를 비워 두어 라벨이 잘리지 않는다. 호버는 surface의 tracking area로 처리해 SwiftUI 재렌더가 없다.

### 2-3. 날짜 구분선과 지난 요청

- 요청마다 붙던 머리줄(`최근 요청 · 2분 12초`, 접힌 이전 요청)은 없애고, 날짜가 바뀌는 첫 메시지 위에 구분선을 둔다. 제목은 `오늘`, `어제`, 그 외 `10월 1일 (수)`, 다른 해면 연도 포함.
- 끝난 요청의 생각 과정(`PickyTypingBubbleView`)은 숨긴다. 끝난 요청의 활동 요약 칩은 유지한다.
- 이전 답변은 8줄 미리보기로 시작하고 말풍선 안 `더 보기`로 그 자리에서 펼친다. 펼치면 코드 블록도 전부 보인다. 리포트로 열기는 호버 아이콘·우클릭 메뉴에 보조로 남긴다.

### 2-4. 그대로 두는 것

질문 버블, 오류 버블, 결과물 트레이, todo 진행 오버레이, 도구 기록 창. Pickle의 답변 길이 규칙(시스템 프롬프트)은 바꾸지 않는다.

### 2-5. 접근성

시간 라벨은 마우스를 올려야 보이지만 VoiceOver 사용자는 마우스 호버를 하지 않는다. 그래서 VoiceOver가 말풍선을 읽을 때 본문 뒤에 보낸 시각(또는 `보내는 중`)을 함께 읽게 한다.

## 3. 승인 후 구현 순서

1. agentd/Swift 프로토콜에 `text` shape 추가 + DSL 파서 + 계약 프롬프트. Vitest(DSL 파싱·clamp), Swift 디코딩 호환 테스트.
2. `PickyAgentAnnotationOverlayView` 에서 `.text` 를 `PickyAnnotationTextOverlayView` 로 렌더, palette resolver에 배경 샘플 추가.
3. `PickyMainActivityChipPresentationCache` 를 `PickyMainActivityConcisePolicy` 로 전환.
4. `PickyTurnCardView` 의 인라인 도구 행·생각 블록을 `PickyConversationPresenceRow` 로 교체하고 끝난 요청의 생각 블록 숨김, 챕터 머리줄을 날짜 구분선으로 교체, 버블에 `timestamp:` 전달. HUD 성능 signpost 비교(`docs/perf-profiling.md`).

## 4. 결정 사항

- 번역은 원문을 덮지 않고 말풍선으로만 보여 준다(원문 잠깐 보기 기능도 불필요).
- 작업 중 행에 Pickle 이름은 넣지 않는다.
- 생각 과정 보기 단축키(Ctrl+T)와 Pi `hideThinkingBlock` 설정 연동은 제거한다. 피클 대화는 생각 과정을 보여주지 않는다.
