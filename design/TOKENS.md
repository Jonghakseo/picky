# Picky Design Tokens

이 문서는 Picky의 foundation token과 semantic token의 목표 구조를 정의한다. 현재 Swift 구현과의 매핑은 점진적으로 진행하며, 이 문서만으로 기존 API를 즉시 삭제하거나 이름을 바꾸지 않는다.

## Token model

```text
Primitive → Semantic → Component
```

- **Primitive:** 원시 색상이나 수치. 제품 코드에서 직접 사용하지 않는다.
- **Semantic:** 역할 중심 토큰. 대부분의 화면이 사용한다.
- **Component:** 특정 컴포넌트의 구조적 예외. 꼭 필요한 경우만 추가한다.

예:

```text
blue.600 → action.fill → button.primary.background
neutral.dark.1 → surface.panel → conversation.card.background
```

## Color

### Semantic roles

| 목표 토큰 | 역할 | 현재 구현 후보 |
|---|---|---|
| `color.canvas` | 가장 깊은 앱/HUD 배경 | `DS.Colors.background` |
| `color.surface.panel` | 카드, sidebar, panel | `DS.Colors.surface1` |
| `color.surface.control` | input, bubble, control fill | `DS.Colors.surface2` |
| `color.surface.hover` | hover 및 선택적 keyboard-focus state layer | `DS.Colors.surface3` |
| `color.surface.pressed` | pressed/active state | `DS.Colors.surface4` |
| `color.separator.subtle` | card outline, divider | `DS.Colors.borderSubtle` |
| `color.separator.strong` | emphasized boundary | `DS.Colors.borderStrong` |
| `color.text.primary` | 제목과 본문 | `DS.Colors.textPrimary` |
| `color.text.secondary` | 설명과 보조 정보 | `DS.Colors.textSecondary` |
| `color.text.tertiary` | timestamp, disabled-adjacent metadata | `DS.Colors.textTertiary` |
| `color.action.fill` | primary action fill | `DS.Colors.accent` |
| `color.action.hover` | primary action hover/pressed | `DS.Colors.accentHover` |
| `color.action.text` | link, icon, selection signal | `DS.Colors.accentText` |
| `color.action.subtle` | selected background | `DS.Colors.accentSubtle` |
| `color.status.running` | 실행·정보 상태 | `DS.Colors.info` |
| `color.status.success` | 완료 상태 | `DS.Colors.success` |
| `color.status.warning` | 입력 대기·주의 | `DS.Colors.warningText` |
| `color.status.danger` | 실패·파괴적 행동 | `DS.Colors.destructiveText` |

Keyboard focus에 전용 시각 token을 강제하지 않는다. 별도 표시가 필요한 컴포넌트는 `color.surface.hover` 계열의 subtle state layer를 우선 재사용하며, border/ring은 배경 전환만으로 상태가 충분히 전달되지 않는 경우에만 사용한다. focus 처리로 component의 frame, padding, radius가 달라져서는 안 된다.

### Draft palette

현재 제품 정체성과 마이그레이션 비용을 고려해 Picky Action Blue는 기존 `#2563EB`를 기준으로 유지한다. Apple의 `#0066CC`를 그대로 복제하지 않는다.

| 역할 | Light | Dark | 비고 |
|---|---:|---:|---|
| Canvas | `#F7F8F8` | `#101211` | 가장 깊은 배경 |
| Panel | `#FFFFFF` | `#171918` | 주요 카드와 panel |
| Control | `#F0F1F1` | `#202221` | input과 bubble |
| Hover | `#E5E7E6` | `#272A29` | interactive hover |
| Pressed | `#D9DBDA` | `#2E3130` | active/pressed |
| Primary text | `#1A1C1B` | `#ECEEED` | 본문과 제목 |
| Secondary text | `#525956` | `#ADB5B2` | 설명 |
| Tertiary text | `#8B928F` | `#6B736F` | metadata |
| Action fill | `#2563EB` | `#2563EB` | 주요 CTA |
| Action text | `#1D4ED8` | `#60A5FA` | 링크와 아이콘 |

정확한 색상값보다 semantic role과 appearance 적응이 우선한다. 시스템 semantic color가 같은 역할을 안정적으로 제공한다면 AppKit/SwiftUI 시스템 색상을 우선 검토한다.

### Color rules

- Action Blue는 행동 가능성을 표현한다.
- status color는 상태를 표현하며, CTA fill로 사용하지 않는다.
- raw hex는 token 정의 외부에서 사용하지 않는다.
- alpha를 component 파일에서 임의 조절하지 않는다. 반복되는 alpha는 semantic/component token으로 승격한다.
- Pull Request, GitHub 등 외부 브랜드 상태색은 integration namespace 아래 명시적 예외로 둔다.

### Integration colors

외부 서비스 브랜드 색은 `DS.Integration` 아래에만 정의한다. 제품 semantic 역할로 재사용하지 않는다.

| 토큰 | Light | Dark | 용도 |
|---|---:|---:|---|
| `integration.github.prOpen` | `#1A7F37` | `#3FB950` | PR open (Primer fg) |
| `integration.github.prMerged` | `#8250DF` | `#A371F7` | PR merged (Primer fg) |
| `integration.github.prClosed` | `#CF222E` | `#F85149` | PR closed (Primer fg) |
| `integration.github.prDraft` | `#59636E` | `#8B949E` | PR draft (Primer fg) |

GitHub 상태색은 foreground-grade다. 칩에서는 텍스트/아이콘 색으로 쓰고, 배경은 같은 색의 저농도 tint(light 5% / dark 10%)로 한다. 불투명 brand fill 위에 흰 텍스트를 올리지 않는다.
| `integration.sentry.logo` | `#181225` | `#FFFFFF` | Sentry 로고 틴트 |

사용자 설정값으로 저장된 hex(예: 블루 커서 색상 설정)를 런타임에 렌더링하는 경우는 토큰 대상이 아니다.

## Typography

Picky는 macOS HUD이므로 Apple 웹 레퍼런스의 17–56px 마케팅 스케일을 사용하지 않는다.

### Type roles

| 토큰 | 기준 크기 | 기본 weight | 용도 | 현재 구현 후보 |
|---|---:|---|---|---|
| `type.heading.primary` | 15pt | Semibold | section heading, markdown H1 | `heading1` |
| `type.title` | 14pt | Semibold | card title, panel title | `title` |
| `type.heading.secondary` | 14pt | Semibold | markdown H2 | `heading2` |
| `type.heading.tertiary` | 13.5pt | Semibold | markdown H3 | `heading3` |
| `type.body` | 13pt | Regular | 기본 대화와 설명 | `body` |
| `type.body.compact` | 12.5pt | Regular | 밀도 높은 보조 본문 | `bodyCompact` |
| `type.supporting` | 12pt | Regular | secondary content | `supporting` |
| `type.label` | 11.5pt | Semibold | control label, badge | `label*` |
| `type.status` | 11pt | Regular/Semibold | 상태와 progress | `status*` |
| `type.meta` | 10.5pt | Regular | timestamp, counts | `meta*` |
| `type.minimum` | 10pt | Regular/Semibold | 제한된 metadata 예외 | `minimum*` |
| `type.badge` | 8pt | Semibold/Bold | shortcut hint, 상태 badge, 미니 카운트 (component 예외) | 신규 |
| `type.badgeIcon` | 7pt | Bold | badge 내부 SF Symbol 글리프 | 신규 |

### Typography rules

- regular와 semibold를 기본 ladder로 사용한다.
- medium은 dense monospace/status에서 semibold가 과도하게 보이는 경우에만 허용한다.
- bold/heavy는 작은 숫자 badge나 강한 경고 등 제한된 경우에만 사용한다.
- monospace는 명령, 경로, code, 시간, token count, 구조화 상태에 사용한다.
- global app font scale을 모든 읽기 텍스트에 적용한다.
- SF Symbol의 optical size는 텍스트 토큰의 직접 대상이 아니다.
- 10pt 미만 텍스트는 `type.badge`/`type.badgeIcon` 두 토큰만 허용하며, 대상은 shortcut hint·상태 badge·미니 카운트로 한정한다. 그 외의 장식용 SF Symbol 글리프 크기는 토큰 비대상이다.

## Spacing

4pt 기반 scale을 사용한다.

| 토큰 | 값 | 용도 |
|---|---:|---|
| `space.1` | 4pt | icon-label 내부, tight metadata |
| `space.2` | 8pt | control 내부, 인접 요소 |
| `space.3` | 12pt | 작은 group, card 내부 최소 padding |
| `space.4` | 16pt | 표준 section/group |
| `space.5` | 20pt | 넓은 control/content padding |
| `space.6` | 24pt | panel section |
| `space.8` | 32pt | 큰 empty state와 major separation |

17pt처럼 타이포 기반 optical value가 필요하면 component token으로 명시한다. 구조적 layout은 가능한 한 scale에 맞춘다.

## Shape

| 토큰 | 값 | 용도 |
|---|---:|---|
| `radius.compact` | 6pt | badge, inline code, compact control |
| `radius.control` | 8pt | input, button, small card |
| `radius.surface` | 12pt | bubble, content card, transient panel |
| `radius.panel` | 14pt | Conversation Card, Dock shell |
| `radius.pill` | full | 짧은 action, selection, status chip |
| `radius.circle` | 50% | icon-only circular control |

3, 5, 7, 9, 15pt 등의 기존 값은 시각 감사에서 역할을 확인한 뒤 위 scale로 통합한다. Dock preset에 따른 비례 radius는 component-level 예외다.

Component 토큰:

| 토큰 | 값 | 용도 |
|---|---:|---|
| `radius.bubble.anchor` | 4pt | conversation bubble의 말꼬리(anchor) 코너. agent 측은 bottomLeading, user 측은 bottomTrailing |

결정 사항: 기존 10pt(`DS.CornerRadius.large`)는 목표 scale에 없으므로 `radius.surface`(12pt)로 통합하고 삭제한다.

## Material

| 토큰 | 처리 | 용도 |
|---|---|---|
| `material.none` | solid semantic surface | 일반 콘텐츠와 control |
| `material.floating` | system thin/ultra-thin material + separator | HUD Dock, floating shortcut hint |
| `material.overlay` | system material 또는 adaptive solid fallback | tooltip, autocomplete, toast |

- material 위 텍스트 contrast를 appearance별로 확인한다.
- Reduce Transparency에서는 semantic solid surface로 대체 가능해야 한다.
- material을 단순히 고급스러워 보이게 만드는 장식으로 사용하지 않는다.

## Elevation

| 토큰 | 처리 | 용도 |
|---|---|---|
| `elevation.flat` | shadow 없음 | 일반 surface와 control |
| `elevation.floating` | `0 4 8`, black 12% 기준 | Dock, Conversation Card |
| `elevation.transient` | `0 8 12`, black 18% 기준 | toast, tooltip, transient overlay |
| `elevation.dragging` | interaction 중 강화 | drag preview |

수치는 시작점이며 실제 appearance와 panel composition에서 검증한다. 여러 shadow를 겹쳐 장식적 glow를 만들지 않는다.

## Motion

| 토큰 | 시간 | 용도 |
|---|---:|---|
| `motion.fast` | 120–150ms | hover, pressed, tint |
| `motion.standard` | 220–250ms | panel expand/collapse, selection |
| `motion.slow` | 400ms | completion feedback, 큰 전환 |

- press scale은 필요할 때 `0.97`을 기준으로 한다.
- hover에서 control을 확대하지 않는 것을 기본으로 한다.
- 무한 반복 motion은 실제 progress를 나타내는 경우만 허용한다.
- Reduce Motion에서는 opacity/tint 변화로 대체한다.

## Implementation migration

1. 기존 `DS` API를 유지한 채 semantic alias를 먼저 정의한다.
2. raw hex, raw font, raw radius, raw shadow를 새 코드에서 추가하지 않는다.
3. 파일럿 영역에서 semantic token으로 교체한다.
4. 시각 및 접근성 검증 후 기존 이름을 단계적으로 deprecated 처리한다.
5. 구조 분리는 역할과 검증 기준이 명확해진 뒤 수행한다.
