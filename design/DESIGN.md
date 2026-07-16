---
title: Picky Design System
version: 0.1.0-draft
status: draft
last_updated: 2026-07-14
---

# Picky Design System

Picky는 데스크톱 위에서 장기 실행되는 Pi 작업의 상태와 다음 행동을 한눈에 보여주는 조용한 macOS command center다.

이 문서는 Picky 디자인 시스템의 단일 진입점이자 최상위 제품 디자인 기준이다. 외부 레퍼런스의 외형을 복제하지 않고, Picky의 제품 목적과 macOS 플랫폼 관습에 맞게 원칙을 해석한다.

## 1. Product promise

Picky의 UI는 사용자가 다음 질문에 빠르게 답할 수 있게 해야 한다.

1. 지금 어떤 Pickle이 실행 중인가?
2. 어떤 Pickle이 입력이나 확인을 기다리는가?
3. 방금 무엇이 완료되거나 실패했는가?
4. 내가 지금 할 수 있는 가장 중요한 행동은 무엇인가?
5. 필요할 때 세부 로그, 도구 활동, 결과물에 어떻게 접근하는가?

UI chrome은 이 정보와 행동보다 앞에 나서지 않는다.

## 2. Design thesis

> **Activity first. Quiet chrome. Explicit state. Native behavior.**

- **Activity first:** 제품 사진이 아니라 대화, 작업 상태, 도구 활동, 결과물이 주인공이다.
- **Quiet chrome:** 장식보다 내용과 상태의 대비로 위계를 만든다.
- **Explicit state:** 색상만으로 상태를 표현하지 않고 아이콘, 문구, 위치를 함께 사용한다.
- **Native behavior:** macOS의 키보드, 포인터, appearance, material, window 관습을 존중한다.
- **Local confidence:** 로컬 실행과 장기 세션의 지속성, 복구 가능성, 사용자 통제감을 시각적으로 지지한다.

## 3. Sources of truth

디자인 결정이 충돌할 때 다음 순서를 따른다.

1. 사용자 안전, 접근성, Picky의 제품 불변 조건
2. Apple macOS Human Interface Guidelines와 시스템 동작
3. 이 문서와 [PRINCIPLES.md](./PRINCIPLES.md)
4. [TOKENS.md](./TOKENS.md)와 [COMPONENTS.md](./COMPONENTS.md)
5. 외부 시각 레퍼런스

`references/`의 문서는 영감과 비교 자료이며 Picky의 규범이 아니다.

## 4. Non-negotiable product invariants

- 여러 Pickle의 상태를 동시에 구분할 수 있어야 한다.
- `running`, `waiting`, `completed`, `failed`, `blocked`, `queued`가 명확히 구분돼야 한다.
- follow-up, abort, rewind, archive 같은 세션 제어가 예측 가능해야 한다.
- tool activity, logs, artifacts, confirmation UI가 숨겨지지 않아야 한다.
- light/dark appearance와 키보드 중심 조작을 지원해야 한다.
- 장식적 단순화를 위해 정보나 상태를 제거하지 않는다.
- 시각 변경이 HUD 성능, 레이아웃 안정성, 텍스트 입력을 악화시키면 안 된다.

## 5. System overview

### Color

- 하나의 **Picky Action Blue**가 링크, 선택, 주요 액션을 담당한다.
- 상태색은 액션색과 별도 의미 체계로 유지한다.
- 배경과 표면은 중립색 계층으로 구성한다.
- 시스템 semantic color와 appearance 적응을 우선한다.

자세한 규칙: [TOKENS.md — Color](./TOKENS.md#color)

### Typography

- 시스템 폰트를 사용한다.
- 기본 읽기 텍스트는 regular, 강조는 semibold를 우선한다.
- monospace는 명령, 경로, 시간, 로그, 구조화된 상태에 한정한다.
- 웹 마케팅용 대형 타이포 스케일을 HUD에 가져오지 않는다.

자세한 규칙: [TOKENS.md — Typography](./TOKENS.md#typography)

### Spacing and density

- 4pt 기반 간격 체계를 사용한다.
- 장기 작업을 다루는 HUD 특성상 정보 밀도는 유지하되, 의미 단위 사이에는 충분한 호흡을 둔다.
- 공간 부족을 작은 글자로 해결하기 전에 정보 우선순위와 progressive disclosure를 검토한다.

### Shape

- compact control, standard control, surface, panel, pill/circle의 제한된 문법을 사용한다.
- 같은 역할의 요소는 같은 radius를 사용한다.
- pill은 액션, 선택, 짧은 상태 표현에만 사용한다.

### Material and elevation

- material은 Dock, detached panel, transient overlay처럼 실제로 떠 있는 계층을 구분할 때 사용한다.
- shadow는 실제 부유 계층과 drag preview에만 사용한다.
- 버튼, 텍스트, 일반 카드에 장식용 glow를 사용하지 않는다.
- 작은 상태 aura는 Dock 상태 표시처럼 의미가 명확한 제한된 경우만 허용한다.

### Motion

- motion은 상태 변화, 공간 관계, 직접 조작의 결과를 설명해야 한다.
- hover는 빠르고 절제되게, press는 즉시 반응하게 만든다.
- 장식적인 반복 pulse나 breathing animation은 기본적으로 사용하지 않는다.
- Reduce Motion 환경에서도 의미가 유지돼야 한다.

## 6. Documentation map

| 문서 | 역할 |
|---|---|
| [DESIGN.md](./DESIGN.md) | 최상위 제품 디자인 기준과 문서 인덱스 |
| [PRINCIPLES.md](./PRINCIPLES.md) | 디자인 판단 원칙과 금지 규칙 |
| [TOKENS.md](./TOKENS.md) | 색상, 타이포, 간격, 형태, 재질, 모션 토큰 |
| [COMPONENTS.md](./COMPONENTS.md) | 컴포넌트 분류, 상태 계약, 구현 인벤토리 |
| [AUDIT.md](./AUDIT.md) | 전체 UI 감사 기준, 우선순위, 기록 양식 |
| [references/DESIGN-apple.md](./references/DESIGN-apple.md) | Apple 웹사이트 분석 원본 레퍼런스 |
| [references/APPLE-HIG.md](./references/APPLE-HIG.md) | Apple 공식 macOS 디자인 문서 인덱스 |

## 7. Decision workflow

새 UI 또는 큰 시각 변경은 다음 순서로 검토한다.

1. 사용자 목표와 상태를 정의한다.
2. 기존 컴포넌트와 semantic token으로 해결 가능한지 확인한다.
3. light/dark, hover, pressed, disabled, waiting, error 상태를 명시한다. custom focus 시각화는 필요한 경우에만 선택적으로 설계한다.
4. 키보드 조작, 포인터, VoiceOver, contrast, Reduce Motion 영향을 검토한다. focus 효과를 추가하면 layout을 바꾸지 않는 subtle background state layer를 우선한다.
5. HUD 변경이면 레이아웃 안정성과 성능을 측정한다.
6. 새로운 토큰이나 variant가 필요하면 이 문서를 먼저 갱신한다.

## 8. Adoption strategy

전체 교체가 아니라 점진적으로 도입한다.

1. 문서와 semantic token 이름을 승인한다.
2. 기존 `Picky/DesignSystem.swift`와 `Picky/HUD/PickyHUDTypography.swift`를 새 기준에 매핑한다.
3. Conversation Card와 Composer를 첫 파일럿으로 검수한다.
4. HUD Dock, Quick Input, Companion/Settings, auxiliary panels 순으로 확장한다.
5. 각 단계에서 [AUDIT.md](./AUDIT.md)의 기준으로 전후를 기록한다.

현재 문서는 **foundation draft**다. 컴포넌트 리디자인이나 기존 토큰의 일괄 변경을 승인하지 않는다.
