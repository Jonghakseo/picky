# Picky 고차원 UI/UX 개선 제안 — 2026-07-14

기준: `design/DESIGN.md`(product promise 5문 + invariants), `PRINCIPLES.md`, `AUDIT.md`.
성격: 토큰 감사 이후의 **경험 수준** 개선 여지. 취향이 아니라 원칙 위반/갭만 정리.
방법: 3개 병렬 조사(a11y·motion / state legibility / hierarchy) 결과를 크로스체크하고,
P0/P1 핵심 주장은 직접 코드로 재검증함.

## 핵심 통찰: 세 갭이 서로를 증폭시킨다

> `queued`와 `running`은 dock에서 **둘 다 파란색 + 같은 plain glyph**이고, 오직 running의
> **breathing 애니메이션**으로만 구분된다. 그런데 앱 전체에 **Reduce Motion 대응이 0건**이다.
> → Reduce Motion을 켠 사용자에게 "대기 중"과 "실행 중"이 **완전히 똑같이 보인다.** (invariant 정면 위반)

상태 구분이 색+모션에 의존 → 색약/Reduce Motion에서 무너짐. 따라서 glyph 구분과 Reduce Motion
fallback을 **함께** 하면 효과가 배가된다.

---

## 🔴 Wave 1 — 상태 명료성 + Reduce Motion (P1, 상호 의존)

| # | 문제 | 근거 | 원칙 |
|---|------|------|------|
| 1 | Reduce Motion 전무. 무한 애니메이션 4곳이 Reduce Motion에서도 반복 | `PickyToolCallInlineRow.swift:179`(pulsing dot), `BlueCursorView.swift:1523`(waiting 3-dot)/`:1685`(highlight ring), `PickyHUDDockIconView.swift:227`(breathing halo) | §7·§9, native behavior |
| 2 | queued vs running 구분이 색+모션뿐 → Reduce Motion/색약에서 동일 | `PickyDockPickleStatusVisual.color` + `statusAssetName`(둘 다 plain glyph) | invariant, §9 |
| 3 | blocked vs failed 동일 glyph(`PickleDockHelp`), 색만 다름 | `PickyHUDDockGroupViews.swift:325-328` | invariant, §9 |
| 4 | waiting vs blocked 헤더 동일 "!" glyph, 같은 amber 계열 | `PickyConversationHeaderView.swift:464-469, 552-561` | invariant, §9 |

**제안:** blocked에 전용 glyph(lock/hand), queued에 static 구분 요소 부여. 무한 애니메이션 4곳에
`@Environment(\.accessibilityReduceMotion)` 정적 fallback(full-opacity dot / static ring).
검증 완료: 2·3·4 모두 실제 코드에서 색/모션 의존 확인함.

## 🟠 Wave 2 — 놓친 순간 (product Q2·Q3)

| # | 문제 | 근거 |
|---|------|------|
| 5 | `.blocked`가 unread/attention에서 제외 → 자리 비운 사이 blocked된 Pickle이 dock 신호 0 (Q2 실패) | `PickySessionViewModel.swift:2180` `attentionStates = [.completed, .failed, .waiting_for_input]` (검증 완료) |
| 6 | completion flash가 `.completed` 전용 → 실패/blocked 전환에 "방금 끝남" 신호 없음 (Q3 실패) | `PickySessionViewModel.swift:2163-2170` (검증 완료) |

**제안:** `attentionStates`에 `.blocked` 추가. flash(또는 다른 hue의 one-shot)를 failed/blocked에도 확장.

## 🟡 Wave 3 — 키보드/VoiceOver 완성도 (P1~P2)

| # | 문제 | 근거 |
|---|------|------|
| 7 | Dock 타일 키보드 접근 불가(`acceptsFirstResponder=false`, Button/FocusState 없음) → FKA/VoiceOver로 open·stop·archive 불가 | `PickyHUDDockIconView.swift:819` |
| 8 | 질문 옵션 버튼 선택 상태가 색상뿐 (체크마크/radio dot 없음, `isSelected` trait 없음) | `PickyQuestionBubbleView.swift:254-270` |
| 9 | send 버튼 `accessibilityLabel` 누락(stop엔 있음), 주 dock 타일 VoiceOver label에 상태 누락 | `PickyConversationComposerView.swift:798`, `PickyHUDDockIconView.swift:140` |

**제안:** dock 타일에 focusable accessibility element(또는 동일 액션 공유 hidden Button).
옵션 버튼에 checkmark/radio glyph + `accessibilityAddTraits(.isSelected)` + value. send label 추가.

## 🟢 Wave 4 — 위계/발견성 polish (P2~P3)

| # | 문제 | 근거 |
|---|------|------|
| 10 | 빈 상태가 `Color.clear` — 선택된 Pickle 없을 때 안내/CTA 없음 (Q1/Q4) | `PickyHUDView.swift:310-315` |
| 11 | 리포트/도구이력 상시 진입점 없음 — 메시지 hover로만 접근 (Q5) | `PickyConversationMenu`, `PickyConversationListView.swift:288-292` |
| 12 | error/question 버블 테두리(opacity 0.58)가 turn-card chrome(0.4×0.5pt)보다 무거움 | `PickyErrorBubbleView`/`PickyQuestionBubbleView` vs `PickyTurnCardView.swift:389-397` |
| 13 | turn 카드 expand/collapse가 방향성 없는 opacity fade | `PickyTurnCardView.swift:315-320` |
| 14 | Reduce Transparency material fallback 없음 (Dock/Card/toast/composer material) | `PickyHUDDockRailView.swift:1151` 외 다수 |

---

## 이미 잘 된 점 (유지)
- dock breathing이 `repeatForever` 대신 `TimelineView`라 세션 종료 시 확실히 멈춤 (모션 정확성)
- pi-badge VoiceOver가 색이 아닌 semantic status를 읽음 (`piBadgeAccessibilityLabel`, color/text 동기화)
- 실패 버블의 Retry/Open Terminal이 원인 지점에 붙어 있음 (next-action at point of relevance)
- 대화 목록이 최근 turn만 노출 + "View as TUI" escape hatch (progressive disclosure)
- 질문 버블/도구 행이 이미 색+비색상 단서 병행 (dock glyph 수정의 템플릿)

---

## 권장 순서
Wave 1(원칙 근거 최강, 서로 얽힘) → Wave 2(작은 변경, promise 갭 2개) → Wave 3 → Wave 4.
각 Wave는 batch-per-surface로 구현하고 macOS 빌드로 검증, 의도 단위 커밋.
Reduce Motion/Transparency 변경은 시스템 접근성 토글로 육안 확인 필요.
