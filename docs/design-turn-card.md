# Design — turn-grouped conversation cards

## Problem

한 턴 안에서 LLM이 짧은 narration("이제 X합니다:" 류)을 10개 넘게 쏟아내면 HUD가 progress log로 도배되어 사용자가 "지금 뭐하는 중"과 "최종 결과"를 빠르게 파악하기 어렵다.

## Goal

`PickyConversationListView` 의 flat ForEach 렌더링을 **turn 단위 그룹 렌더링**으로 바꿔, user 입력 한 개에 매달린 모든 agent activity를 하나의 expandable 카드로 묶는다. 완료된 과거 turn은 자동 collapse되어 최종 답변만 노출되고, 현재 진행 중인 turn은 expanded로 고정된다.

picky 의 thin 원칙(AGENTS.md)을 지키기 위해 이 변경은 **순수 렌더링 레이어 한정**이다. agentd, 메시지 모델, 저장 포맷, 스킬/툴 분류 어디도 건드리지 않는다.

## Non-goals

- 메시지 자체를 묶거나 축약하지 않는다 (요약은 Pi 영역).
- agentd 의 `session-message-builder` 변경 없음.
- "narration vs answer 휴리스틱 분류"(아이디어 #4) 는 이번 작업에 포함하지 않는다 — turn 그룹화의 효과를 먼저 측정한다.
- expand 상태의 영구 저장 없음 (세션 재진입 시 정책 기본값으로 복원).

## Design

### 1. Turn boundary 정의

- **Turn**: `userText` 메시지에서 시작해 다음 `userText` 직전까지의 슬라이스.
- **Turn ID**: 시작 `userText` 메시지의 `id` (안정적, 유니크, 이미 존재).
- `userText` 가 0개일 때(세션 시작 직후 등): 단일 "pre-turn" 그룹으로 처리하되 헤더 없이 평이하게 렌더.

### 2. Turn 상태 정의

`PickyTurnCardView` 가 자신의 turn 상태를 다음 파생 값으로 결정한다:

| 상태 | 조건 | 기본 expansion |
|---|---|---|
| `current` | 그룹이 `visibleMessages` 의 마지막 turn이고 session.status ∈ {running, queued, waiting_for_input} | **expanded (lock)** |
| `completed` | session 이 위 진행 상태가 아니거나, 더 뒤에 다른 turn이 존재 | **collapsed** |

추가로 `cancelled`, `failed` 도 collapsed 로 간주한다(완료된 종결 상태로 본다). `compact completion` system 메시지는 turn에 속하지 않고 별도 행으로 그대로 둔다.

### 3. 사용자 토글

- chevron 클릭으로 expand/collapse 수동 토글.
- 수동 토글은 그 turn이 종료(=다음 user 입력 발생)되기 전까지 유지.
- 수동 collapse 한 current turn은 사용자 의도를 존중해 collapsed 유지.
- 다음 user 입력으로 새 turn이 시작되면 직전 turn은 자동 collapsed 로 떨어진다 (사용자가 명시적으로 expand 해둔 경우엔 그 상태 유지).

### 4. Collapsed 상태 콘텐츠 (1a)

collapsed turn 카드 본문에는 다음 두 요소만 노출한다:

1. **Final agent text** — 그 turn 안의 마지막 `agentText`(또는 `system` markdown). 없으면 마지막 `agentError` 의 메시지.  존재하지 않으면 placeholder 없이 생략.
2. **Summary chip** — 한 줄: `N steps · M tools · Ts` 형태.
   - `N steps`: turn 내 visibleToolCallItems 수 또는 agent message 수 중 큰 값
   - `M tools`: turn 내 `agentActivity` snapshot 의 visibleToolCallItems 누계
   - `Ts`: 첫 메시지 ~ 마지막 메시지 createdAt 차이 (정수 초, ≥60초면 분 단위)

chip 우측에 chevron, 좌측에 `⌁ 완료` 류 상태 도트 (DS.Colors.success / info) 한 개.

### 5. Expanded 상태 콘텐츠

기존 `PickyConversationListView.messageView(_:)` 의 switch 결과를 그대로 turn 카드 본문에 stack 한다. 즉 **버블 뷰 자체는 재사용**하고, 단지 부모 컨테이너만 turn 카드가 된다.

current turn은 chevron 자리에 진행 중 인디케이터(작은 spinner 또는 thinking dot 3개) 를 보이고 toggle disabled.

### 6. 시각 디자인

기존 디자인 토큰(`DS.Colors.surface3`, `borderSubtle` 등) 만 사용한다. Picky HUD 와 이질감 없도록.

- turn 카드 외곽: `RoundedRectangle(cornerRadius: 12)`, `surface2.opacity(0.42)` fill, `borderSubtle.opacity(0.5)` stroke 0.5pt
- 카드 padding: horizontal 8, vertical 6
- collapsed 헤더 높이 약 22pt
- expanded 시 본문 spacing 은 기존 `LazyVStack(spacing: 8)` 를 그대로 카드 안으로 옮김
- 카드와 user 버블 사이 spacing: 8pt (현재 list spacing 과 동일)
- chevron rotation 애니메이션 0.18s easeOut (scrollToLatest 와 동일 곡선)

### 7. visibleMessages / earlier-history 정책

기존 정책 유지. `visibleMessages` 는 마지막 두 user_text 부터 끝까지를 그대로 반환하고, 이 슬라이스를 turn 단위로 그룹화해 카드 2개 + (있다면) pre-turn 행으로 렌더한다. "Earlier history" 버튼, time separator(60초 갭), queue/activity summary 영역 모두 그대로.

### 8. 자동 스크롤

`scrollToLatest(proxy:animated:)` 는 `session.messages.last?.id` 를 anchor 로 쓴다. turn 카드 안에 있어도 SwiftUI scrollTo 는 hierarchy 깊이와 무관하게 작동하므로 변경 불필요. 다만 collapsed 카드 안에 anchor 메시지가 들어 있을 수 있어, **collapsed 상태일 때 카드 자체에도 turn id 를 ScrollView ID 로 부여** 해 fallback 한다.

### 9. RenderSnapshot

`PickyConversationListRenderSnapshot` 에 다음 필드 추가:

```swift
var turnCardCount = 0
```

기존 카운트(`typingBubbleCount`, `errorBubbleCount`, `activitySummaryCount`, `compactCompletionBubbleCount` 등)는 "visible 윈도우에 들어온 메시지"의 구조적 특성을 나타내는 첩도로, **turn 확장 여부와 무관하게 `visibleMessages` 전체 기준으로 계산**한다. 황 확장/접기는 뷰의 상태일 뿐, 렌더링 의도(messages 우에 차 렌더될 대상)는 변하지 않는다. 더분에 기존 어서션은 수정 없이 통과.

## Architecture / Files

### 신규

- `Picky/HUD/Conversation/PickyTurnCardView.swift` (~150–200줄)
  - `struct PickyTurnCardView: View`
  - `struct PickyTurnGroup`: turn id, messages, isCurrent, autoCollapsed 계산
  - `enum PickyTurnExpansionMode { case currentLocked, autoCollapsed, userExpanded, userCollapsed }`
  - 헤더 / collapsed body / expanded body 분리

### 수정

- `Picky/HUD/Conversation/PickyConversationListView.swift`
  - `visibleMessages` 결과를 `groupByTurn(_:)` 로 turn 그룹 배열로 변환
  - 기존 `ForEach(visibleMessages)` 를 `ForEach(turnGroups)` + `PickyTurnCardView(group:)` 로 교체
  - `messageView(_:)` 는 그대로 유지하고 `PickyTurnCardView` 가 콜백 파라미터로 받아 호출
  - `renderSnapshot` 에 turn 카드 카운트 추가, expanded 그룹의 자식만 카운트
  - `currentTurnMessages`, `hasAgentProgressInVisibleTurn`, `hasVisibleActivitySnapshot` 등은 그대로 유지 (어차피 marker policy 는 동일)

### 손 댈 필요 없는 곳

- 모든 `Bubbles/*` 뷰
- `PickyConversationCardView`, `PickyConversationHeaderView`, `PickyConversationComposerView`
- `PickySessionMessage`, `PickySessionListViewModel`
- agentd 전체

## Edge cases

- **빈 turn (user 메시지만 있고 agent 응답 0개)**: 카드는 표시하되 collapsed body 가 비어 보이지 않도록 summary chip 만 노출 (`0 steps`).
- **agent 메시지가 단 1개인 turn**: collapsed 상태에서 그 1개 메시지가 곧 final answer. expanded 와 시각적으로 거의 동일하지만 토글은 그대로 노출 (일관성).
- **agentQuestion 이 turn 의 마지막**: collapsed 시 final answer 자리에 question prompt 한 줄을 그대로 보임. 사용자가 펼쳐서 form 응답 가능. current turn 은 어차피 expanded 라 일반 케이스에서는 영향 없음.
- **compact 진행 중**: 기존 `PickyCompactingOverlayView` 가 ZStack 위에 그대로 깔리므로 영향 없음.
- **session 이 cancelled 인 채로 새 user 입력 없음**: 마지막 turn 이 `current` 정의에서 제외되므로 collapsed. 사용자가 펼쳐 보기 가능.
- **time separator 가 turn 경계와 겹칠 때**: separator 는 turn 카드 사이에 두고, 카드 내부로 들어가지 않는다. turn 내부 메시지 간 60초 갭은 expanded 본문 안에 separator 로 그대로 표시.

## Testing

### 기존 테스트 영향

`PickyTests/PickyConversationCardViewTests.swift` 의 `renderSnapshot.*Count` 어서션:
- expanded current turn 의 자식 카운트 → 변화 없음 (대부분의 기존 테스트)
- 과거 turn(자동 collapse)이 있는 fixture 는 자식 카운트가 0 으로 떨어짐 → 해당 케이스만 어서션 업데이트
- `visibleMessages*` 테스트 → 정책 미변경, 그대로 통과

### 신규 테스트 (PickyConversationCardViewTests 동일 파일에 추가)

1. `turnGroupingSplitsByUserText` — 메시지 시퀀스 입력 → group 경계 검증
2. `currentTurnIsExpandedLocked` — running 상태에서 마지막 turn isExpanded == true, toggle disabled
3. `pastTurnIsCollapsedByDefault` — running 상태라도 직전 turn 은 collapsed
4. `completedSessionLastTurnIsCollapsed` — session.status == completed 면 마지막 turn 도 collapsed
5. `manualToggleOnCurrentTurnPersistsUntilNextUserText` — current turn 수동 collapse → 다음 userText 도착까지 유지, 도착 시 새 turn 이 current 가 되면 자연스럽게 정책 기본값으로 전환
6. `summaryChipReportsStepsToolsElapsed` — `N steps · M tools · Ts` 문자열 포맷 검증
7. `collapsedTurnShowsLastAgentTextOnly` — fixture 에 narration 6개 + final agent_text 1개 → collapsed body 에 final 만 노출
8. `renderSnapshotCountsExpandedTurnOnly` — collapsed turn 의 자식 typing/error/activity 는 카운트되지 않음

## Out of scope (다음 작업 후보)

- 아이디어 #4 (narration 휴리스틱 시각 위계 분리)
- 아이디어 #2 (colon-prelude → tool card 흡수)
- 아이디어 #6 (tool spine timeline)
- expand 상태 영구 저장
- turn 단위 즐겨찾기 / 공유 / 보고서 익스포트

## Decision log

| 결정 | 선택 | 이유 |
|---|---|---|
| Collapsed body 콘텐츠 | (1a) final answer + summary chip | 사용자가 가장 보고 싶어 하는 정보 우선 노출 |
| 자동 collapse 트리거 | session 진행 상태 종료 또는 더 뒤 turn 존재 | "completed" 의미를 명확화, 진행 중에는 시각적 변화로 사용자를 놀라게 하지 않음 |
| 현재 turn | expanded lock | 진행을 가리지 않음, 사용자 의도와 일치 |
| Turn ID | 첫 user_text 의 id | 이미 안정적/유니크, 추가 모델 변경 없음 |
| visibleMessages 정책 | 변경 없음 (마지막 2 user_text) | turn 그룹화와 직교, 기존 동작/테스트 유지 |
| 변경 격리 | 렌더링 레이어 한정 | AGENTS.md "thin picky" 원칙, agentd 무변경 |
