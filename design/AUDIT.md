# Picky Design Audit

이 문서는 Picky 전체 UI를 일관된 기준으로 검수하기 위한 rubric과 기록 양식을 제공한다.

## Baseline snapshot

2026-07-14 기준 정적 조사 결과:

- `DS.*`를 참조하는 Swift 파일: 54개
- `PickyHUDTypography`를 참조하는 Swift 파일: 26개
- raw system font 선언이 남은 파일: 20개
- `.shadow(...)`를 사용하는 파일: 18개
- gradient를 사용하는 파일: 2개
- raw `Color(hex:)`를 사용하는 파일: 5개
- 확인된 literal corner radius: 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 15pt

이 수치는 품질 점수가 아니라 디자인 결정이 분산된 위치를 찾기 위한 baseline이다.

## Audit order

1. Conversation Card + Composer
2. Conversation bubbles, question, error, progress
3. HUD Dock + session tile + grouping
4. Quick Input
5. Companion panel + Settings + Shortcuts
6. Terminal + Report + Tool History
7. Pointer / response overlays

## Scoring

각 항목을 0–2점으로 평가한다.

- **0 — 문제:** 사용자 이해나 일관성을 명확히 해친다.
- **1 — 부분 충족:** 기본 기능은 되지만 상태, token, 접근성 또는 일관성에 gap이 있다.
- **2 — 충족:** 문서 기준을 일관되게 만족한다.

총점은 우선순위를 돕는 지표일 뿐, 심각한 단일 문제를 상쇄하지 않는다.

## Criteria

### 1. Information hierarchy

- 현재 상태와 다음 행동이 첫 시선에 보이는가?
- title, body, metadata의 강도가 역할과 맞는가?
- chrome이 콘텐츠와 경쟁하지 않는가?

### 2. Action and status semantics

- Action Blue가 행동에 일관되게 사용되는가?
- status color가 CTA와 혼동되지 않는가?
- 색상 외 아이콘, 레이블, 형태가 있는가?

### 3. Token consistency

- semantic color, typography, spacing, radius를 사용하는가?
- 같은 역할에 같은 token이 적용되는가?
- raw 값에는 정당한 예외 사유가 있는가?

### 4. Density and spacing

- 정보가 작아서 읽기 어려워지지 않았는가?
- 의미 단위가 spacing으로 구분되는가?
- 반복 정보가 과도한 공간을 차지하지 않는가?

### 5. Interaction completeness

- rest, hover, pressed, focus, disabled, selected 상태가 정의됐는가?
- keyboard와 pointer 사용이 모두 가능한가?
- destructive 또는 irreversible action이 충분히 구분되는가?

### 6. Appearance and accessibility

- light/dark에서 contrast와 위계가 유지되는가?
- Increase Contrast, Reduce Transparency, Reduce Motion에서 의미가 유지되는가?
- VoiceOver label/value가 상태를 설명하는가?
- 작은 시각 요소에도 충분한 hit area가 있는가?

### 7. Material, elevation, and motion

- material과 shadow가 실제 레이어 관계를 설명하는가?
- 일반 카드나 버튼에 불필요한 glow가 없는가?
- animation이 원인과 결과를 설명하는가?
- 반복 motion이 실제 progress와 연결되는가?

### 8. Product invariants

- 여러 Pickle과 상태를 동시에 구분할 수 있는가?
- long-running session의 follow-up, abort, reconnect 흐름을 방해하지 않는가?
- tool activity, confirmation, error, artifact가 숨겨지지 않는가?
- HUD 레이아웃과 성능이 안정적인가?

## Severity

| 등급 | 의미 | 예시 |
|---|---|---|
| P0 | 작업 수행 또는 안전을 방해 | 입력 불가, 상태 오인, destructive action 오작동 |
| P1 | 핵심 상태 이해 또는 접근성을 저해 | waiting/failed 혼동, focus 표시 없음, contrast 부족 |
| P2 | 시스템 일관성과 완성도 저하 | radius drift, raw spacing, 불필요한 shadow |
| P3 | 개선 아이디어 | 미세한 optical alignment, 문구 개선 |

## Audit record template

```markdown
## [Surface / Component]

- 구현: `path/to/file.swift`
- 검수 일자: YYYY-MM-DD
- 검수자:
- appearance: Light / Dark / Both
- 상태 범위: Rest / Hover / Focus / Disabled / Running / Error / ...

### Score

| 기준 | 점수 | 근거 |
|---|---:|---|
| Information hierarchy | 0–2 | |
| Action and status semantics | 0–2 | |
| Token consistency | 0–2 | |
| Density and spacing | 0–2 | |
| Interaction completeness | 0–2 | |
| Appearance and accessibility | 0–2 | |
| Material, elevation, and motion | 0–2 | |
| Product invariants | 0–2 | |

### Findings

1. `[P1]` 문제와 사용자 영향
2. `[P2]` 문제와 일관성 영향

### Recommendation

- 유지할 것:
- 변경할 것:
- 필요한 token/component 결정:
- 검증 방법:
```

## Validation checklist

시각 변경 PR은 관련 항목을 기록한다.

- [ ] Light appearance 확인
- [ ] Dark appearance 확인
- [ ] Hover / pressed / keyboard focus 확인
- [ ] Disabled / waiting / error 상태 확인
- [ ] Increase Contrast 또는 contrast 수동 확인
- [ ] Reduce Transparency fallback 확인
- [ ] Reduce Motion fallback 확인
- [ ] Dynamic font scale 확인
- [ ] VoiceOver label/value 확인
- [ ] HUD layout clipping/jump 확인
- [ ] 관련 테스트 실행
- [ ] HUD 변경 시 perf signpost 비교

## First pilot exit criteria

Conversation Card + Composer 파일럿은 다음을 만족해야 완료로 본다.

- 주요 시각 값이 승인된 semantic token으로 설명된다.
- Action Blue와 session status color의 역할이 혼동되지 않는다.
- Composer의 입력, focus, bash, drop, autocomplete, disabled 상태가 문서화된다.
- 불필요한 shadow/glow와 radius 변형이 제거되거나 예외로 기록된다.
- light/dark와 keyboard interaction이 동일한 정보 구조를 유지한다.
- 기존 IME, resize, streaming, scroll, follow-up 동작이 보존된다.
