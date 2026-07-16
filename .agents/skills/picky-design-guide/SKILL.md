---
name: picky-design-guide
description: Picky 저장소에서 SwiftUI/AppKit UI를 새로 만들거나 수정하고, HUD·Conversation·Dock·Quick Input·Companion·Settings·overlay의 색상, 타이포그래피, 간격, radius, material, shadow, motion, 상태 표현, 접근성, 디자인 일관성을 검수할 때 사용한다. Picky 디자인 문서를 source of truth로 적용하고 Action Blue와 semantic status, macOS HIG, light/dark, keyboard interaction, HUD 성능을 확인한다.
---

# Picky Design Guide

Picky의 시각 변경이 단순한 스타일 취향이 아니라 장기 실행 Pickle의 상태, 다음 행동, macOS 사용성을 더 명확하게 만들도록 안내한다.

핵심 문장:

> Activity first. Quiet chrome. Explicit state. Native behavior.

## 필수 참조

활성화되면 먼저 `references/doc-map.md`를 읽고 저장소 루트의 canonical 디자인 문서를 작업 범위에 맞게 연다.

최소 참조:

1. 모든 디자인 작업: `<repo-root>/design/DESIGN.md`
2. 구현 또는 리뷰: `<repo-root>/design/PRINCIPLES.md`
3. 색상·타이포·spacing·shape·material·motion 변경: `<repo-root>/design/TOKENS.md`
4. 컴포넌트 생성·변경: `<repo-root>/design/COMPONENTS.md`
5. 전체 검수 또는 리뷰: `<repo-root>/design/AUDIT.md`

외부 레퍼런스보다 Picky 제품 불변조건과 Apple 공식 macOS HIG를 우선한다.

## 요청 분류

요청을 하나 이상으로 분류한다.

- **Design proposal:** 새 surface, component, 상태 문법을 설계한다.
- **Visual implementation:** 승인된 디자인을 SwiftUI/AppKit에 반영한다.
- **Design audit:** 기존 화면의 일관성, 상태, 접근성을 검수한다.
- **Foundation change:** token, 공용 style, appearance 체계를 수정한다.
- **Near miss:** backend-only, protocol-only, session policy-only처럼 시각 표현과 무관한 작업이다.

Near miss에는 이 스킬의 시각 규칙을 억지로 적용하지 않는다. 사용자에게 보이는 상태 projection이 바뀌는 경우에만 관련 범위를 적용한다.

## Workflow

### 1. 현재 상태를 보호하고 조사한다

1. `git status --short`로 사용자 변경을 확인한다.
2. 코드 네비게이션은 `AGENTS.md`의 UI 인덱스에서 시작한다.
3. View뿐 아니라 backing view model/store와 interaction state를 함께 확인한다.
4. 기존 `DS`, `PickyHUDTypography`, appearance, layout policy로 해결 가능한지 찾는다.
5. 동일한 컴포넌트가 SwiftUI/AppKit 또는 cursor/response overlay에 중복돼 있는지 확인한다.

실행 중인 Picky 앱은 사용자가 명시적으로 요청하지 않는 한 재시작하지 않는다.

### 2. 사용자 목표와 상태를 먼저 정의한다

새 컴포넌트나 의미 있는 시각 변경은 코드 전에 `references/review-templates.md`의 **Design Decision Card**를 작성한다.

다음이 불명확하면 한 번에 묶어 질문하지 말고 가장 중요한 결정부터 `ask_user_question`으로 확인한다.

- 첫 시선에 보여야 하는 정보
- primary action과 secondary action
- running, waiting, completed, failed 등 필요한 상태
- 화면 밀도와 progressive disclosure
- native control로 해결할지 custom control이 필요한지

큰 변경이나 새 기능이면 `design-first` 절차를 함께 적용하고 승인 전에 구현하지 않는다.

### 3. Picky 디자인 문법을 적용한다

#### Activity first

대화, 작업 상태, 질문, 도구 활동, artifact가 주인공이다. chrome, border, badge, glow가 콘텐츠와 경쟁하지 않게 한다.

#### One blue means action

- Action Blue: CTA, 링크, 선택
- Semantic status: running/info, success, waiting/warning, failure/destructive, queued/neutral
- status는 색상 외 아이콘, 레이블 또는 형태를 함께 사용한다.
- status color를 일반 CTA fill로 사용하지 않는다.

#### Native before novel

- 시스템 폰트와 SF Symbols를 기본으로 한다.
- macOS keyboard navigation, pointer, tooltip, menu, drag/drop 동작을 보존한다.
- system semantic color와 appearance 적응을 우선한다.
- custom control은 rest, hover, pressed, disabled 상태를 명시한다. custom focus 시각화는 필요한 경우에만 선택 적용하며, 기존 layout을 바꾸지 않는 subtle background 전환을 border/ring보다 우선한다.

#### Dense, never cramped

- 작은 글자로 공간 문제를 숨기지 않는다.
- 의미 grouping과 progressive disclosure로 밀도를 관리한다.
- monospace는 명령, 경로, 로그, 시간, 구조화 상태에 한정한다.

#### Elevation explains structure

- material과 shadow는 Dock, Conversation Card, transient overlay, drag preview처럼 실제로 떠 있는 계층에 사용한다.
- 일반 버튼, badge, 텍스트, 콘텐츠 카드에 장식용 glow를 추가하지 않는다.
- status aura는 작고 일시적이며 의미가 명확한 경우만 허용한다.

#### Motion confirms cause and effect

- hover와 press는 짧고 즉각적으로 반응한다.
- expansion은 공간 관계를 설명한다.
- 무한 반복 motion은 실제 progress를 나타내는 경우만 허용한다.
- Reduce Motion에서 정적 의미가 유지돼야 한다.

### 4. 기존 foundation을 점진적으로 사용한다

- 우선 `<repo-root>/Picky/DesignSystem.swift`와 `<repo-root>/Picky/HUD/PickyHUDTypography.swift`를 재사용한다.
- semantic token이 있는데 raw hex, raw font, raw radius, raw shadow를 추가하지 않는다.
- 새 semantic 역할이 필요하면 token 문서를 먼저 갱신하고 기존 API에 alias를 추가하는 방식을 우선한다.
- `DS` 의존 범위가 넓으므로 foundation을 한 번에 교체하지 않는다.
- 구조 분리는 줄 수가 아니라 역할과 invariant가 명확할 때만 한다.

### 5. 상태와 접근성을 완성한다

적용 가능한 상태를 검토한다.

- Rest
- Hover
- Pressed
- Keyboard focused (custom 시각화가 필요한 경우에만 선택 적용)
- Disabled
- Selected
- Loading/running
- Waiting for input
- Success/completed
- Error/failed

그리고 다음을 확인한다.

- Light / Dark appearance
- Increase Contrast
- Reduce Transparency
- Reduce Motion
- global app font scale
- VoiceOver label/value
- 충분한 hit area
- 색상 외 상태 단서

### 6. 감사 요청은 근거 중심으로 보고한다

리뷰나 전체 검수 요청이면 `references/review-templates.md`의 **Design Audit Report**를 사용한다.

- 파일과 symbol을 근거로 남긴다.
- `AUDIT.md`의 0–2점과 P0–P3 severity를 사용한다.
- 취향 표현보다 사용자 영향과 Picky invariant를 설명한다.
- 유지할 것과 변경할 것을 함께 기록한다.
- 사용자가 리뷰만 요청했다면 파일을 수정하지 않는다.

### 7. 좁은 범위부터 검증한다

변경 파일을 대상으로 먼저 확인한다.

```bash
rg -n 'Color\(hex:|\.font\(\.system|cornerRadius: [0-9]|\.shadow\(|LinearGradient|RadialGradient' <changed-files>
```

raw 값이 발견되면 제거하거나 component-level 예외 이유를 기록한다.

그다음 작업에 맞게 검증한다.

1. 관련 pure policy/view projection 테스트
2. 대상 Swift test suite
3. macOS build
4. light/dark와 interaction state 수동 확인
5. HUD 렌더링 변경이면 `<repo-root>/docs/perf-profiling.md`에 따라 signpost 비교

스크린샷은 검수 근거로 사용할 수 있지만 구현 의도나 실제 상태 동작을 대신할 수 없다.

## Tool guidance

- `read`: canonical 디자인 문서와 관련 View/ViewModel을 읽는다.
- `rg`: 기존 token, component, raw style, 중복 구현을 찾는다.
- `todo_write`: 화면 여러 개나 foundation까지 걸치는 감사에 사용한다.
- `ask_user_question`: 시각 목표나 상태 우선순위가 결과를 크게 바꿀 때 사용한다.
- `web_search`/`fetch_content`: Apple API/HIG 가정이 필요하면 공식 `developer.apple.com`을 우선한다.
- `show_widget`: 사용자가 명시적으로 시안이나 비교 보드를 원할 때만 사용한다.

## 완료 보고

구현 작업:

- 적용한 디자인 원칙과 token
- 변경 파일과 핵심 상태
- appearance/accessibility 처리
- 실행한 검증과 결과
- 남은 예외 또는 수동 확인

감사 작업:

- 범위와 총평
- P0–P3 findings와 코드 근거
- 유지할 점
- 우선순위별 권고안
- 필요한 token/component 결정

## 금지

- Apple 웹사이트의 외형이나 수치를 Picky HUD에 그대로 복제하지 않는다.
- status color를 없애 단일 accent만 남기지 않는다.
- 모든 surface에 material, shadow, pill을 적용하지 않는다.
- 장식 목적으로 지속적인 glow나 breathing animation을 추가하지 않는다.
- 디자인 정리를 이유로 장기 Pickle 상태, tool activity, confirmation, error 정보를 숨기지 않는다.
- foundation을 big-bang으로 교체하지 않는다.
- 실행 중인 Picky 앱을 임의로 재시작하지 않는다.

## Self-validation

완료 전에 확인한다.

- [ ] 필요한 canonical 디자인 문서를 읽었다.
- [ ] 사용자 목표, 정보 위계, action/status가 명확하다.
- [ ] 적용 가능한 interaction/session 상태를 검토했다.
- [ ] 기존 semantic token과 component를 우선 사용했다.
- [ ] appearance와 접근성 영향을 확인했다.
- [ ] raw 스타일 예외를 기록했다.
- [ ] HUD 변경이면 layout/performance 리스크를 확인했다.
- [ ] 요청이 리뷰 전용이면 파일을 수정하지 않았다.

스킬이나 canonical 디자인 문서를 수정한 경우 다음 검증을 실행한다.

```bash
python3 scripts/validate_design_guide.py
```
