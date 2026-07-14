# Picky Design Guide Document Map

canonical 문서는 스킬 디렉터리에 복제하지 않는다. 저장소 루트를 확인한 뒤 아래 repository-relative 경로를 직접 읽는다.

```bash
git rev-parse --show-toplevel
```

아래 `<repo-root>`는 위 명령 결과다.

## Always start here

| 문서 | 언제 읽나 | 핵심 질문 |
|---|---|---|
| `<repo-root>/AGENTS.md` | 모든 작업 | 제품·아키텍처·실행 제약은 무엇인가? |
| `<repo-root>/design/DESIGN.md` | 모든 디자인 작업 | Picky의 최상위 디자인 방향과 우선순위는 무엇인가? |
| `<repo-root>/design/PRINCIPLES.md` | 구현·리뷰 | 이 결정이 Picky 원칙에 부합하는가? |

## Load by task

| 문서 | 트리거 |
|---|---|
| `<repo-root>/design/TOKENS.md` | color, typography, spacing, radius, material, shadow, motion, appearance |
| `<repo-root>/design/COMPONENTS.md` | button, chip, card, Dock, Composer, bubble, panel, overlay 생성·변경 |
| `<repo-root>/design/AUDIT.md` | 디자인 리뷰, 전체 검수, 일관성 점검, 우선순위 산정 |
| `<repo-root>/design/references/APPLE-HIG.md` | macOS platform behavior, accessibility, material, control 가정 확인 |
| `<repo-root>/design/references/DESIGN-apple.md` | Apple 웹 시각 언어와 비교할 때만. 규범이 아니라 참고 자료 |

## Related engineering guidance

| 문서 | 트리거 |
|---|---|
| `<repo-root>/docs/refactoring-principles.md` | `DesignSystem.swift` 분리, 공용 style 구조 변경 |
| `<repo-root>/docs/perf-profiling.md` | HUD body/layout/identity/material/shadow 변경 |
| `<repo-root>/docs/swift-concurrency.md` | async UI 상태나 MainActor 경계를 수정할 때 |

## Current implementation entry points

### Foundations

- `<repo-root>/Picky/DesignSystem.swift`
- `<repo-root>/Picky/HUD/PickyHUDTypography.swift`
- `<repo-root>/Picky/App/Settings/PickyAppearanceStore.swift`
- `<repo-root>/Picky/HUD/PickyHUDLayoutPolicy.swift`

### Signature surfaces

- Dock: `<repo-root>/Picky/HUD/PickyHUDDockRailView.swift`
- Session tile: `<repo-root>/Picky/HUD/PickyHUDDockIconView.swift`
- Conversation Card: `<repo-root>/Picky/HUD/Conversation/PickyConversationCardView.swift`
- Composer: `<repo-root>/Picky/HUD/Conversation/PickyConversationComposerView.swift`
- Conversation bubbles: `<repo-root>/Picky/HUD/Conversation/Bubbles/`
- Quick Input: `<repo-root>/Picky/QuickInput/`
- Companion: `<repo-root>/Picky/Companion/`
- Settings: `<repo-root>/Picky/App/Settings/`
- Auxiliary panels: `<repo-root>/Picky/HUD/PickyReportViewer.swift`, `<repo-root>/Picky/HUD/PickyToolHistoryViewer.swift`, `<repo-root>/Picky/Sessions/PickyTerminalOverlay.swift`

## Priority rule

충돌 시 다음 순서를 따른다.

1. 사용자 안전, 접근성, Picky 제품 invariant
2. Apple 공식 macOS HIG와 시스템 동작
3. `design/DESIGN.md`와 `design/PRINCIPLES.md`
4. token/component 문서
5. Apple 웹 분석과 기타 외부 레퍼런스
