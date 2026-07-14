# Picky 전체 디자인 감사 findings — 2026-07-14

기준 문서: `design/DESIGN.md`, `PRINCIPLES.md`, `TOKENS.md`, `COMPONENTS.md`, `AUDIT.md`
범위: Conversation, Bubbles, Dock, Quick Input, Companion/Settings, Auxiliary panels, Overlays, Foundation
총평: 핵심 상태 표현/접근성(P0)은 견고. 위반은 대부분 원칙(장식 motion·status-as-CTA)과 토큰 일관성(radius/hex/font) 수준.

---

## P1 — 원칙 위반 (상태 오인 · 장식 motion)

| # | 위치 | 문제 | 위반 규칙 | 수정안 |
|---|------|------|-----------|--------|
| 1 | `Picky/DesignSystem.swift:214-311` `DSPrimaryButtonStyle` | hover glow **infinite breathing pulse**(2.5s candle-flame) + **hover scale-up 1.03** | PRINCIPLES §6/§7, DESIGN §5 | breathing/glow 제거, hover는 색만, scale-up 제거 |
| 2 | `Picky/HUD/Conversation/PickyConversationComposerView.swift:1237-1244` `sendColor` | Send 버튼(CTA) fill에 `DS.Colors.success`(green) 사용 | "One blue = action" (status≠CTA) | follow-up/submit 모두 Action Blue로, green은 상태 전용 |
| 3 | `Picky/HUD/Conversation/PickyConversationComposerView.swift:1392-1414` `PickyRunningComposerBorder` | 실제 진행률과 무관한 `repeatForever` AngularGradient sweep | PRINCIPLES §7 (장식 motion) | 정적 tinted border로 (header dot이 이미 running 표시) |
| 4 | `Picky/Overlay/BlueCursorView.swift:1684-1687` highlight ring | 주의 환기용 `repeatForever` pulse (진행 아님) | PRINCIPLES §7 | `PickyInkOverlay`처럼 one-shot arrival 애니메이션 |
| 5 | `Picky/HUD/PickyHUDDockIconView.swift:57-59` / `Picky/HUD/PickyHUDDockGroupViews.swift:495` | hover **scale-up 1.03 / 1.04** | TOKENS Motion (hover 확대 금지) | hover scale 제거 |

## P2 — status/action 혼동

| # | 위치 | 문제 | 수정안 |
|---|------|------|--------|
| 6 | `Picky/HUD/Conversation/Bubbles/PickyErrorBubbleView.swift:296` | Retry 액션 칩에 `DS.Colors.success`(green) | Action Blue로 통일 (Retry는 action) |
| 7 | `Picky/HUD/PickyHUDDockIconView.swift:169` unread dot / `Picky/HUD/PickyHUDDockGroupViews.swift` unread chip | unread **status**를 Action Blue(`DS.Colors.accent`)로 표현 | 별도 status/notification 토큰 도입 여부 결정 필요 |

## P2 — 토큰 일관성 (radius/hex/font drift)

### Raw hex (semantic token 중복)
- `Picky/HUD/PickyDockGrouping.swift:47-53` — 7색 팔레트 전부 raw hex, 4개(`#34D399`/`#F1A10D`/`#70B8FF`/`#FF6369`)는 `DS.Colors`(success/warningText/info/destructiveText)와 동일값 → `DS.GroupAccent` 토큰화
- `Picky/Overlay/BlueCursorView.swift:46-49` — `#3380FF`(=`overlayCursorBlue`), `#FFB224`(=`warning`) 중복

### Radius drift (→ `DS.CornerRadius` 참조)
- `14`: `PickyConversationCardView.swift:155/158`, `OnboardingHighlightViewerPanelController.swift:171` → extraLarge(12) 또는 문서화
- `15`: `PickyHUDArchiveUndoToast.swift:92-95` → 12
- `9`: `PickyRewindPickerView.swift:136/140`, `CompanionPanelSettingsView.swift`(11곳), `CompanionPanelStatusView.swift:174/177`, `ShortcutSettingsViews.swift:93/96` → **`DS.CornerRadius`에 없는 관행값, 토큰 추가 결정 필요**
- `7`: `PickyConversationHeaderView.swift:427/430`, `PickyErrorBubbleView.swift:43`, `PickyConversationMarkdownText.swift:167/206/208`, `CompanionPanelMessagesView.swift:378/387/389`, `ShortcutSettingsViews.swift:165`
- `5`: `PickyConversationHeaderView.swift:128`, `PickyDockGroupCreatorView.swift:150`, `PickyHUDArchivedSessionsListView.swift:115/181/208`
- `4`: `OnboardingSkipPanelController.swift:181`, `CompanionPanelFooterView.swift:90`
- `3`: `PickyConversationComposerView.swift:1368`, `PickyConversationContextLineView.swift:407` (아주 작은 아이콘 plate, P3)
- 값은 맞지만 리터럴인 `8/10/12`: `PickyToolHistoryViewer.swift`, `PickyReportViewer.swift`, `PickyTerminalOverlay.swift:398/400`, `PickyInlineTerminalCardView.swift`, `PickyTurnCardView.swift`, `PickyCursorResponseBubbleView.swift:22`, `CompanionResponseOverlay.swift:27` 등 다수 → 토큰 참조로

### Raw system font (→ `PickyHUDTypography`/`.pickyFont`)
- `Picky/HUD/PickyHUDDockIconView.swift` — 8곳(title/status/todo/git/cwd, `:173,1167,1173,1219,1223,1226,1234,1239,1243,1251`)
- `Picky/HUD/PickyReportViewer.swift` — 5곳(`:266,271,274,284,317`)
- `Picky/Sessions/PickyTerminalOverlay.swift` — 4곳 header chrome(`:378,381,384,392`)
- `Picky/QuickInput/QuickInputPanelView.swift:78,111`
- `Picky/Overlay/BlueCursorView.swift`(5곳), `PickyCursorResponseBubbleView.swift`, `CompanionResponseOverlay.swift` (overlay window라 app-font-scale 미연결 caveat)

---

## Keep (유지 — 변경 금지)
- ConversationCard / Dock / toast / tooltip / response-bubble의 shadow → 실제 floating layer, 규칙 준수
- `PickyHUDDockIconView` breathing halo, `CursorWaitingIndicatorView` dot → **실제 running/waiting 진행**에 연결, 정당한 예외
- `PickyInkOverlayView`의 one-shot threshold ring → 올바른 패턴 (다른 pulse가 따라야 할 기준)
- `PickyConversationContextLineView`의 GitHub Primer / Sentry brand hex, terminal monospace, `PickyReportViewer` 독립 zoom → 문서화된 정당한 예외
- `PickyAppearanceStore`의 `PickyAppearancePanelChrome` raw hex → AppKit 패널 titlebar 브리징용 문서화된 예외
- 모든 status가 icon/label/shape 동반 (color-only 없음), Settings의 native control 사용

---

## 문서 선결정 (2026-07-14 결정)
1. **radius `9`, `7`**: 기존 `DS.CornerRadius`로 흡수 (9→8/10, 7→6/8). 새 토큰 추가 없음.
2. **unread 표시색**: 별도 notification semantic 토큰 신설 (Action Blue와 역할 분리).
3. **`DS.GroupAccent`**: 토큰 세트 신설. 중복 4색(success/warningText/info/destructiveText)은 기존 `DS.Colors` 참조.

---

## 수정 batch 진행 결과 (batch-per-surface)
1. **Batch A — Foundation** ✅: DSPrimaryButtonStyle dead code 제거(#1), `DS.Colors.notification` 신설+unread 분리(#7), `DS.GroupAccent` 신설+DockGrouping hex 제거, DockIcon/DockGroup hover scale-up 제거(#5). BlueCursorView hex는 Codable 지속 포맷이라 보류.
2. **Batch B — Conversation** ✅: send/retry Action Blue 통일(#2/#6), running border sweep→정적(#3), `DS.CornerRadius.panel(14)` 신설, radius drift(5/7) 토큰화.
3. **Batch C — Dock** ✅: DockIcon mini-preview 폰트를 명명 접근자로 정리. raw font는 dock-preset 스케일 예외로 확인되어 고정 역할 매핑 안 함(교체 시 프리셋 스케일 망가짐).
4. **Batch D — Panels/Overlays** ✅: Report/ToolHistory/Terminal/InlineTerminal/TurnCard/TodoProgress/오버레이 radius를 `DS.CornerRadius` 참조로 교체. ReportViewer/TerminalOverlay 폰트는 독립 zoom/미연결 스케일 예외로 유지.

### 수정 보류 항목
- `BlueCursorView` colorHex 등 — Codable 지속 포맷의 문자열 기본값이라 토큰 참조 전환 시 타입/영속 포맷 변경. 리스크 대비 가치 낮아 유지.
- `PickyReportViewer`/`PickyTerminalOverlay` 폰트 — 전자는 독립 per-panel zoom, 후자는 app-font-scale 미연결 standalone 패널. `PickyHUDTypography` 강제 시 스케일 회귀 위험.
- radius `9` 관행값(Companion/Shortcuts) — 결정에 따라 기존 토큰 흡수 대상이나 이번 batch 범위 밖(Companion/Settings은 별도 surface). 추후 정리 권장.
