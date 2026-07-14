# Picky Component System

이 문서는 Picky UI 컴포넌트의 분류와 상태 계약을 정의한다. 현재는 foundation 단계이므로 완성된 시각 명세가 아니라 감사와 점진적 표준화를 위한 인벤토리다.

## Component contract

모든 공용 컴포넌트는 다음 항목을 문서화한다.

1. 사용자 목적
2. 정보 우선순위
3. 지원 상태
4. 사용 token
5. 키보드와 포인터 동작
6. 접근성 label/value
7. light/dark 및 accessibility appearance
8. 허용되는 variant
9. 사용하면 안 되는 사례
10. 관련 구현과 테스트

## Foundations

| 영역 | 현재 구현 | 목표 |
|---|---|---|
| Color / spacing / shape / motion | `Picky/DesignSystem.swift` | semantic token 중심으로 정리 |
| HUD typography | `Picky/HUD/PickyHUDTypography.swift` | 역할 기반 타입 체계 유지 |
| Appearance | `Picky/App/Settings/PickyAppearanceStore.swift` | panel chrome과 SwiftUI appearance 일치 |
| HUD geometry | `Picky/HUD/PickyHUDLayoutPolicy.swift` | 제품 동작에 필요한 component metrics로 유지 |

## Controls

### Primary action

- 화면이나 context에서 가장 중요한 다음 행동
- 한 surface에 과도하게 반복하지 않는다.
- Action Blue fill + on-action text
- Rest, hover, pressed, focus, disabled 상태 필수
- 장식용 glow와 breathing animation은 사용하지 않는다.

현재 후보: `DSPrimaryButtonStyle`

### Secondary action

- primary를 보조하는 가역적 행동
- neutral surface 또는 outline 사용
- primary와 같은 시각 강도를 갖지 않는다.

현재 후보: `DSSecondaryButtonStyle`, `DSOutlinedButtonStyle`

### Ghost / text action

- toolbar, menu-adjacent, inline action
- rest 상태에서는 chrome을 최소화한다.
- hover와 keyboard focus는 명확히 구분한다.

현재 후보: `DSTertiaryButtonStyle`, `DSTextButtonStyle`

### Icon action

- close, send, archive, copy 같은 compact utility action
- tooltip과 accessibility label이 필수다.
- destructive action은 hover뿐 아니라 의미와 confirmation 정책으로 구분한다.

현재 후보: `DSIconButtonStyle`

### Chip / badge

- 짧은 상태, selection, filter, attachment, shortcut 표시
- action chip과 status badge를 시각적으로 구분한다.
- 긴 문장이나 primary CTA를 chip에 넣지 않는다.

## Shells and surfaces

### HUD Dock

주요 구현:

- `Picky/HUD/PickyHUDDockRailView.swift`
- `Picky/HUD/PickyHUDDockIconView.swift`
- `Picky/HUD/PickyHUDLayoutPolicy.swift`

역할:

- 여러 Pickle의 존재와 상태를 ambient하게 보여준다.
- 선택, hover preview, drag/grouping, 새 Pickle 생성을 지원한다.
- material과 elevation을 사용할 수 있는 대표 floating layer다.

### Session tile

- title보다 상태와 식별 가능성이 우선한다.
- selected, running, waiting, completed, failed, archived-progress 상태를 구분한다.
- 지속적인 glow보다 dot, ring, icon, label을 우선한다.

### Conversation Card

주요 구현:

- `Picky/HUD/Conversation/PickyConversationCardView.swift`
- `Picky/HUD/Conversation/PickyConversationHeaderView.swift`
- `Picky/HUD/Conversation/PickyConversationListView.swift`

역할:

- 선택한 Pickle의 현재 상태, 대화, 도구 활동, 다음 행동을 하나의 계층으로 제공한다.
- Dock와 분리된 floating surface이므로 제한된 elevation을 허용한다.
- status border는 의미를 보조하되 콘텐츠보다 강하지 않아야 한다.

### Composer

주요 구현:

- `Picky/HUD/Conversation/PickyConversationComposerView.swift`

필수 상태:

- Empty / typing / focused / disabled
- Follow-up / steer
- Bash visible / Bash private
- File drop target
- Slash command autocomplete
- File mention autocomplete
- Attachment present
- Waiting/running session constraints

Composer는 첫 디자인 시스템 파일럿 대상으로 삼는다.

### Quick Input

주요 구현: `Picky/QuickInput/QuickInputPanelView.swift`

- 매우 짧은 시간 동안 나타나는 keyboard-first surface다.
- Picky Action Blue, typography, material 규칙을 HUD와 공유한다.
- conversation 전체 chrome을 복제하지 않는다.

### Companion and Settings

주요 구현:

- `Picky/Companion/`
- `Picky/App/Settings/`
- `Picky/Shortcuts/`

- 설정은 native macOS control과 읽기 흐름을 우선한다.
- HUD의 상태 강조 문법을 장식적으로 가져오지 않는다.

### Auxiliary panels

- Terminal
- Report viewer
- Tool history
- Rewind picker
- Archived sessions

이들은 panel chrome과 typography를 공유하되, terminal/code surface에는 monospace와 별도 밀도 예외를 허용한다.

## Conversation content

### User bubble

- 사용자가 보낸 원문과 attachment/origin을 보존한다.
- agent/system message와 확실히 구분하되 과도한 brand fill은 피한다.

### Agent response

- 긴 읽기 흐름을 방해하지 않는 neutral surface를 우선한다.
- markdown heading, code, table이 type token과 일치해야 한다.

### Tool activity

- category, status, duration, summary를 compact하게 보여준다.
- 색상은 category 장식보다 실행 상태 전달을 우선한다.
- monospace는 구조화된 데이터에만 사용한다.

### Question / confirmation

- 사용자의 입력이 필요함을 warning과 혼동하지 않게 한다.
- 선택지, selected state, submit 가능 여부, keyboard 이동을 명시한다.

### Error

- 오류 요약, 영향, 가능한 다음 행동을 구분한다.
- red surface 전체 채우기보다 symbol, heading, subtle tint로 위계를 만든다.

### Progress / todo

- 진행 중 항목과 완료 항목을 빠르게 비교할 수 있어야 한다.
- 실제 진행이 없는데 animation으로 활동감을 만들지 않는다.

## Initial standardization order

1. Conversation Card + Composer
2. Conversation bubbles and status views
3. HUD Dock + Session tile
4. Quick Input
5. Companion + Settings
6. Terminal, Report, Tool History, overlays

각 단계는 [AUDIT.md](./AUDIT.md)의 기준으로 검수한다.
