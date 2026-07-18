# Picky 전체 디자인 감사 findings — 2026-07-18

기준 문서: `design/DESIGN.md`, `PRINCIPLES.md`, `TOKENS.md`, `COMPONENTS.md`, `AUDIT.md`
범위: Conversation Card/Composer/Bubbles, HUD Dock, Quick Input, Companion/Settings/Shortcuts,
Auxiliary panels, Overlays(신규 annotation/pointer 포함), Foundation
방법: surface별 5개 병렬 감사 후 P1 전 항목 직접 코드 크로스체크. 리뷰 전용(코드 미수정).
이전 감사: `AUDIT-findings-2026-07-14.md`, `UX-improvements-2026-07-14.md` (94 커밋 경과)

총평: 토큰·모션 규율은 7-14 이후 뚜렷하게 개선됐다. 현재 최대 문제는 장식이 아니라 **침묵**이다 —
`blocked`가 attention 시스템에서 빠져 있고, 상태 구분이 색에 기대는 지점이 남았으며, 신규
annotation overlay는 핵심 정보(label)를 버린다. 반대로 "이유 없는 색"(status-as-CTA)도 잔존한다.

## Score (종합)

| 기준 | 점수 | 근거 |
|---|---:|---|
| Information hierarchy | 2 | turn 카드/헤더/progressive disclosure 견고 |
| Action/status semantics | 1 | bash send·pending·Save·running 색 오용 4건 |
| Token consistency | 1 | raw font 20→12, hex 5→3, radius 종류 11→8 개선. 단 15/10/5pt 재drift + semantic alias 부재 |
| Density/spacing | 2 | 위반 없음 |
| Interaction completeness | 1 | dock 타일 키보드 접근 불가, hover 부재 다수 |
| Appearance/accessibility | 1 | 선택 상태 색상 전용, VoiceOver 상태 누락, 시스템 RM 부분 무시 |
| Material/elevation/motion | 1 | RM fallback 대폭 개선(4/4), transparency fallback 10/10. 장식 pulse 1건 잔존 |
| Product invariants | 1 | blocked 침묵 = promise Q2("무엇이 기다리는가") 정면 실패 |

---

## P1 — 핵심 상태 이해·접근성 (전 항목 코드 재검증됨)

| # | 위치 | 문제 | 위반 규칙 | 수정안 |
|---|------|------|-----------|--------|
| 1 | `Picky/PickySessionViewModel.swift:2274` `attentionStates`, `:2263` done flash | `blocked`가 unread/attention에서 제외, one-shot 전환 신호는 `.completed` 전용 → 자리 비운 사이 blocked된 Pickle이 dock 신호 0 | DESIGN §1 Q2, §4 invariant | `attentionStates`에 `.blocked` 추가, failed/blocked 전환에 비축하 톤 one-shot 확장 + 회귀 테스트 (7-14 Wave 2 미해결) |
| 2 | `Picky/HUD/PickyHUDDockIconView.swift:140` a11y label `"Preview \(title)"`, `:824` `acceptsFirstResponder=false` | dock 타일 VoiceOver label에 상태 정보 0, FKA/VoiceOver로 open·stop·archive 불가 | PRINCIPLES §9, invariant | 상태를 accessibilityValue로, 실제 동작을 label/hint로, 기존 콜백 공유 focusable element 노출 (Wave 3 미해결) |
| 3 | `PickyHUDDockIconView.swift:404-410`, `PickyHUDDockGroupViews.swift:329-333`, `PickyConversationHeaderView.swift:478` | blocked≡failed 동일 `help` glyph(full+mini tile), waiting≡blocked 동일 `!`(header), mini tile의 queued/running/completed/cancelled는 전부 plain glyph → 색으로만 구분 | invariant, §9 | blocked 전용 glyph(lock/hand) 1개로 세 표면 동시 해결 (Wave 1 미해결) |
| 4 | `Picky/HUD/Conversation/Bubbles/PickyQuestionBubbleView.swift:301-305` | 옵션 선택 상태가 accentSubtle 배경+stroke 색상뿐 — check/radio glyph·`.isSelected` trait 없음 | §3, §9 | 선택 marker glyph + `.accessibilityAddTraits(.isSelected)` + value (Wave 3 미해결) |
| 5 | `Picky/HUD/Conversation/Bubbles/PickyAgentBubbleSurfaceView.swift:203` | 축약 응답의 report 버튼이 `isPointerInside`일 때만 표시 → 키보드/VoiceOver로 전체 본문 접근 불가 | §9, DESIGN §1 Q5 | hover disclosure 유지 + 항상 접근성 트리에 있는 action 또는 Conversation 메뉴 진입점 (Wave 4 부분 미해결) |
| 6 | `Picky/Overlay/PickyAgentAnnotationOverlayView.swift:35-53` | `.label` shape만 렌더/VoiceOver 요약에 포함 → rect/line/spotlight에 붙은 `label="..."`이 화면·낭독 모두에서 소실 | invariant(정보 은닉 금지) | shape-attached label 배치·낭독 정책 추가 (신규 표면) |
| 7 | `Picky/Overlay/BlueCursorView.swift:218` mascot `TimelineView(.animation)`, `:584-587` follow spring | 상시 노출 mascot의 반복 scale/rotation과 follow spring이 시스템 Reduce Motion 미확인(앱 preference만 확인) | §7, §9 | `accessibilityReduceMotion` 분기 추가 — RM 대응은 waiting dot/highlight ring에는 이미 존재 |

## P2 — "이유 없는 색" (status-as-CTA, 전부 검증)

| # | 위치 | 문제 | 수정안 |
|---|------|------|--------|
| 8 | `PickyConversationComposerView.swift:1210` `sendColor` | Bash 모드에서 send가 `bashAccentColor`(green/amber)로 Action Blue 이탈 — bash 문맥은 이미 badge·border·glyph가 전달 | Bash 여부 무관 `accentText` 반환 |
| 9 | `Picky/HUD/Conversation/Bubbles/PickyPendingBubbleView.swift:17` | 실행 전 pending follow-up이 `DS.Colors.success`(완료색), steer는 overlay 전용 blue | pending은 neutral queued tone, 종류 구분은 기존 glyph/label/dash |
| 10 | `Picky/Shortcuts/ShortcutSettingsViews.swift:181` | 저장(primary) 버튼 fill이 `destructiveText` 빨강 + `isEnabled` 미반영 | `accent`/`accentHover` + disabled projection |
| 11 | `Picky/HUD/PickyToolHistoryViewer.swift:457` | running 상태 색이 `accentText`(action 문법 공유) | `DS.Colors.info` |
| 12 | `Picky/Companion/CompanionPanelStatusView.swift:219` | idle~listening~processing~responding 내내 green mic — 첫 시선 단서가 상태와 무관 | voiceState별 icon+semantic color 매핑 |

## P2 — 놓친 상태 표현

| # | 위치 | 문제 | 수정안 |
|---|------|------|--------|
| 13 | `Picky/Sessions/PickyTerminalOverlay.swift:417` | non-zero exit이 일반 문자열로만 저장 → 정상 종료와 동일한 neutral text + green icon | exit 상태/code 구조화, failure icon/color + 다음 행동 |
| 14 | `Picky/Overlay/BlueCursorView.swift:1713` | pointer highlight ring이 여전히 장식성 `repeatForever`(RM fallback은 추가됨) — 7-14 #4의 잔여 | `PickyInkOverlay`식 one-shot arrival 후 정적 ring |

## P2 — Interaction/접근성 완성도

| # | 위치 | 문제 | 수정안 |
|---|------|------|--------|
| 15 | `Picky/QuickInput/QuickInputPanelView.swift:144` | Send/Close가 `.plain` + 정적 색 — hover/pressed 없음 | 공용 icon-action 스타일 또는 명시적 hover/pressed |
| 16 | `Picky/HUD/Conversation/PickyHUDArchivedSessionsListView.swift:181` | delete-all/restore/delete(파괴 포함) hover/pressed 없음 | `PickyHUDCompactChipButtonStyle` 또는 state layer 적용 |
| 17 | `Picky/HUD/Conversation/Bubbles/PickyActivitySummaryView.swift:15` | tool summary가 클릭 시 history를 여는 버튼인데 rest≡hover, hint 없음 → 정적 통계로 오인 | `.hoverAffordance()` + label/“Open tool history” hint |
| 18 | `PickyConversationComposerView.swift:577` | autocomplete 키보드 선택이 subtle blue 배경뿐 — trait/비색상 marker 없음 | marker + `.isSelected` trait |
| 19 | `PickyConversationComposerView.swift:1189` `sendHelpText` | attachment-only 전송 가능 상태에서 label이 “Enter a message to send” — 활성 동작을 반대로 설명 | `attachments.isEmpty` 검사 후 “Send attachment(s)” |
| 20 | `Picky/HUD/PickyReportViewer.swift:1167` outline, `PickyToolHistoryViewer.swift:276` scope | 현재 section/scope 선택이 색·weight뿐, selected trait 없음 | `.isSelected` trait + localized value |
| 21 | `Picky/Companion/Onboarding/OnboardingHighlightViewerPanelController.swift:147` | close가 ~18pt glyph만, label/help/hover 없음 — 30초 패널의 유일한 직접 조작 | 28×28pt 이상 hit frame + label/help/hover |
| 22 | `Picky/HUD/PickyHUDLayoutPolicy.swift:13` `PickyHUDExpansion.animation` | 220ms 공간 전환이 RM 무관 상시 적용 | 정책에서 RM 시 nil/정적 전환 선택 가능하게 |
| 23 | `Picky/Companion/CompanionPanelExtensionsView.swift:458` | curated extension info 버튼 ~10pt hit target + label 누락 (bundled 쪽과 불일치) | `CompanionPanelIconActionStyle` + label |
| 24 | `Picky/HUD/PickyReportViewer.swift:311` | 검색이 occurrence가 아닌 block ID 단위 → 긴 문단 다중 일치가 `1/1`, 문단 전체 tint | occurrence 모델링 + 해당 run만 강조 |

## P2 — 토큰 재drift / Foundation

| # | 위치 | 문제 | 수정안 |
|---|------|------|--------|
| 25 | `Picky/HUD/PickyHUDArchiveUndoToast.swift:164-168` | 15pt radius 3곳 잔존 — 7-14 감사에서 12pt 지시했으나 미이행 | `DS.CornerRadius.extraLarge` 단일 shape 재사용 |
| 26 | `Picky/Companion/CompanionPanelSettingsView.swift:963` OAuth 카드 10pt, `Bubbles/PickyOpenAsReportHoverIcon.swift:30` 5pt, Rewind/그룹 row 9·5·7pt 잔존 | radius 재drift (literal 29건/13파일) | 역할별 `DS.CornerRadius` 토큰으로 회수 |
| 27 | `Picky/DesignSystem.swift:15-21` | TOKENS.md의 alias-first migration 미착수 — 63파일 1,118 `DS.*` 참조가 `surface1...4` 등 구현명에 결합 | semantic alias 레이어 먼저 추가 |
| 28 | `Picky/DesignSystem.swift:303-310` | 미사용 `DS*ButtonStyle` 6종 — fixed 16pt font, disabled 미투영, RM 무시 press scale인 dead API | 제거하거나 계약 완성 후 실제 채택 |
| 29 | `Picky/Shortcuts/ShortcutSettingsViews.swift:119-122` | double-tap keycap 2개가 동일 `id`로 `ForEach` identity 충돌 | index 합성 identity |
| 30 | `Picky/Companion/CompanionPanelSettingsView.swift:1410` | credential/path 입력이 native text-field 스타일 대신 정적 custom stroke — focus/disabled/contrast 미재현 | `.textFieldStyle(.roundedBorder)` 또는 예외 문서화 |

---

## Keep (유지 — 7-14 이후 명확히 좋아진 것 포함)

- 정량 개선: raw font 파일 20→12, raw hex 5→3, literal radius 종류 11→8, pointing-hand 커서 0건,
  Reduce Transparency fallback 10/10 material, baseline 반복 모션 RM fallback 4/4
- send/retry Action Blue 통일, running border 정적화, focus state layer(레이아웃 비변형),
  `.hoverAffordance()` 도입, `DS.Colors.notification` 분리, `DS.GroupAccent` 토큰화, Settings radius 9 흡수
- dock breathing의 `TimelineView` 방식(세션 종료 시 확실히 정지), pi-badge VoiceOver semantic 낭독,
  실패 버블의 원인 지점 액션 배치(Retry/Open Terminal), report 500pt 읽기 컬럼·독립 zoom,
  annotation rough-stroke RM fallback·고정 layering, overlay material fallback
- Settings의 native Picker/Toggle 사용, turn 카드 progressive disclosure + "View as TUI" escape hatch

## 이전 감사 대비 상태

- 해결: 7-14 P1 #1(breathing CTA)·#2(send green)·#3(running sweep)·#5(hover scale), P2 #6(retry)·#7(unread 토큰),
  radius 5/7/9/14 통합, Wave 1 #1(RM fallback 4곳), Wave 4 #14(transparency fallback)
- 미해결 이월: Wave 1 #3·#4(blocked glyph → 본 문서 #3), Wave 2 #5·#6(blocked attention/flash → #1),
  Wave 3 #7·#8·#9(dock focus/질문 선택/send label → #2·#4·#19), Wave 4 #11(report 진입 → #5),
  BlueCursor pulse 잔여(→ #14), archive toast 15pt(→ #25)

## 권장 순서

1. **즉시 (invariant/접근성)**: #1 blocked attention + #3 blocked glyph(상호 증폭) → #2 dock a11y → #6 annotation label
2. **다음 pass (semantic 정리)**: 색 오용 일괄 #8~#12, 접근성 #4·#5
3. **foundation 결정 후**: #27 semantic alias, #28 dead style, #25·#26 radius 회수, #22 RM 정책

## Validation

- 감사 중 실행: macOS build 성공, Swift 테스트 1,354건 포함 관련 스위트 전부 통과 (읽기 전용, 코드 변경 없음)
- P1 7건은 해당 줄 직접 재확인 완료. P2는 표본 검증(#8, #9, #10, flash)
- 미검증: 실기기 light/dark·VoiceOver·RM 토글 육안 확인 (정적 분석 기반)
