# Picky Design Principles

이 문서는 화면을 만들거나 검수할 때 사용하는 판단 규칙이다. 구체적인 값은 [TOKENS.md](./TOKENS.md), 컴포넌트 계약은 [COMPONENTS.md](./COMPONENTS.md)를 따른다.

## 대원칙: 사용자 인지부하 최소화

사용자가 내부 상태를 해석하지 않아도 지금 필요한 정보와 다음 행동을 알 수 있어야 한다. 기능을 추가할 때 정보와 컨트롤을 더하기 전에, 이 화면에서 꼭 필요한지 먼저 판단한다.

- 같은 상태를 여러 배너·배지·행에 반복하지 않는다. 작업명·상태·시간은 가능한 한 한 행에 둔다.
- 정상적인 등록·대기·취소를 경고처럼 표현하지 않는다. 실제 실패나 확인이 필요한 상황은 해당 동작 옆에 한 번만 알린다.
- 보관 목록은 세션 이름·경로와 복원·삭제에 집중한다. 작업 진행·상세·중지는 복원한 세션에서 다룬다. ‘보관된 피클 전체 삭제’는 실행 상태로 대상을 걸러내지 않으며, 연결된 작업의 정리는 삭제 과정에서 처리한다.
- 피클 재진입 때 상태를 불러온다는 이유만으로 작업 영역이나 여백을 만들지 않는다. 실제 작업·결과 또는 대응할 오류가 있을 때 표시한다.
- 표시를 줄여도 실행 추적과 종료 확인은 유지한다. 명시적 삭제의 보관 대상·성공 응답·오류를 확인하되, 자동 런타임 해제 조건을 삭제 버튼의 활성 조건으로 재사용하지 않는다.

## 1. Activity is the hero

대화, 실행 상태, 질문, 도구 활동, 결과물이 화면의 주인공이다.

**Do**

- 현재 상태와 다음 행동을 첫 시선에 배치한다.
- 상세 정보는 필요할 때 확장할 수 있게 한다.
- 색상, 간격, 타이포의 대비로 위계를 만든다.

**Don't**

- 장식용 배경, glow, gradient로 콘텐츠와 경쟁하지 않는다.
- 모든 정보를 같은 시각 강도로 표시하지 않는다.

## 2. One blue means action

Picky Action Blue는 클릭과 선택처럼 사용자의 행동 가능성을 알리는 데 사용한다.

**Do**

- 주요 CTA, 링크, 선택 상태에 일관되게 사용한다.
- dark surface에서는 contrast가 확보된 밝은 action text variant를 사용한다.

**Don't**

- 단순 정보나 장식에 Action Blue를 사용하지 않는다.
- blue를 `running` 상태와 주요 CTA에 같은 방식으로 사용하지 않는다. 형태와 레이블로 역할을 구분한다.

## 3. Status is semantic, not decorative

장기 세션 제품에서는 상태색이 필수다. 단일 accent 원칙보다 상태 명확성이 우선한다.

- Running / informational: blue 계열
- Success / completed: green 계열
- Waiting / warning: amber 계열
- Blocked(사용자 개입·외부 대기): amber 계열이되 failed와 같은 error 톤을 공유하지 않고, 전용 glyph와 dot 형태로 구분한다
- Failure / destructive: red 계열
- Queued / cancelled / unavailable: neutral 계열

모든 상태는 색상 외에 아이콘, 문구 또는 형태를 함께 사용한다. 색상만으로 상태를 구분하지 않는다.

## 4. Native before novel

대상 플랫폼의 표준 동작이 충분한 경우 커스텀 동작보다 우선한다. Mac의 시스템 동작 규칙을 폰 브라우저에 그대로 적용하지 않는다. 아래 키보드·포인터·material 규칙은 Mac 화면에 적용한다.

- 시스템 폰트와 SF Symbols를 기본으로 한다.
- 표준 pointer, keyboard navigation, tooltip, menu 동작을 보존한다.
- material과 vibrancy는 기능적 레이어 구분에 사용한다.
- light/dark와 접근성 설정에 적응한다.

새로운 시각 표현은 native behavior를 대체하는 것이 아니라 Picky의 상태 모델을 더 명확히 표현해야 한다.

### 같은 작업 의미, 플랫폼에 맞는 조작

Mac과 폰은 작업 상태, 질문, 전송·중단 결과, 주요 용어를 공유한다. 폰에서는 hover나 키보드 단축키 없이도 필요한 행동에 접근할 수 있어야 한다. 화면 크기에 맞게 배치와 입력 방식을 바꾸되, 별도의 작업 상태 체계나 에이전트 실행 모델을 만들지 않는다. [원격 PWA 설계](../docs/remote-pwa-plan.md)가 화면별 대응을 정의한다.

### Cursor는 macOS 관습을 따른다

macOS는 pointing-hand(손가락) 커서를 하이퍼링크에만 예약한다. 웹처럼 모든 클릭 가능한 컨트롤에 pointing-hand를 붙이지 않는다.

- 버튼, tile, chip, badge, 아이콘 액션 등 일반 컨트롤은 기본 arrow 커서를 유지한다.
- "클릭 가능함"은 커서가 아니라 **hover 상태(배경/색상/텍스트 전환)** 로 전달한다 (§7·§8). 커서만으로 어포던스를 표현하지 않는다.
- pointing-hand 커서는 외부 URL을 여는 진짜 링크에만 사용한다.
- 드래그 핸들의 grab(open/closed hand), 리사이즈 핸들의 resize, 텍스트 입력의 I-beam 등 **다른** 시스템 커서는 각자의 macOS 관습대로 유지한다 — 이 규칙은 pointing-hand에만 적용된다.

따라서 `.pointerCursor()`(pointing-hand) modifier와 버튼 스타일의 `NSCursor.pointingHand` 사용은 앱 전역에서 제거하며, 신규 코드에서도 도입하지 않는다.

## 5. Dense, never cramped

Picky는 여러 장기 작업을 동시에 다루므로 일반적인 마케팅 페이지보다 밀도가 높다.

- 기본 본문을 불필요하게 줄이지 않는다.
- 최소 텍스트 크기는 badge, shortcut hint, 짧은 metadata에만 허용한다.
- 정렬과 grouping으로 밀도를 관리한다.
- 반복 metadata는 축약하되, 중요한 상태와 사용자 입력은 축약하지 않는다.

## 6. Elevation must explain structure

Picky의 elevation은 장식이 아니라 공간 관계를 설명한다.

허용되는 대표 사례:

- desktop 위에 떠 있는 HUD Dock
- Dock 옆에 열리는 Conversation Card
- autocomplete, tooltip, toast 같은 transient overlay
- drag 중인 session tile 또는 preview

일반 콘텐츠 카드, 버튼, badge, 텍스트에는 기본적으로 shadow를 사용하지 않는다. 상태 glow는 작고 일시적이며 의미가 명확한 경우만 허용한다.

## 7. Motion confirms cause and effect

- hover: 상호작용 가능성을 알린다.
- pressed: 입력 수신을 즉시 확인한다.
- expansion: 요소의 출발점과 도착점을 설명한다.
- progress: 실제 작업이 진행 중임을 전달한다.

지속적인 breathing, 장식용 pulse, 의미 없는 scale-up은 사용하지 않는다. 반복 motion은 Reduce Motion에서도 정적인 상태 표현으로 대체 가능해야 한다.

## 8. State completeness is part of design

컴포넌트는 기본 모양만으로 완료되지 않는다. 적용 가능한 상태를 모두 정의한다.

- Rest
- Hover
- Pressed
- Keyboard focused (해당 컴포넌트에 별도 시각 피드백이 필요할 때 선택 적용)
- Disabled
- Selected
- Loading/running
- Waiting for input
- Success/completed
- Error/failed

상태가 존재하지 않는다면 명시적으로 `not applicable`로 기록한다.

## 9. Accessibility is a visual requirement

- 텍스트와 아이콘의 contrast를 appearance별로 확인한다.
- Increase Contrast와 Reduce Transparency에서 정보가 사라지지 않게 한다.
- 최소 hit target은 컨트롤의 사용 맥락과 macOS 관습을 고려하되, 작은 시각 요소에도 충분한 실제 hit area를 제공한다.
- 키보드 조작 가능성은 유지하되 custom focus 시각화는 선택적으로 적용한다.
- focus 시각화를 적용할 때는 기존 레이아웃, 크기, shape를 바꾸지 않는다. border/ring/glow보다 `color.surface.hover` 계열의 미세한 배경색 전환을 우선하고, 경계선은 배경 변화만으로 부족한 경우에만 제한적으로 사용한다.
- 상태색에는 항상 비색상 단서를 제공한다.

## 10. Exceptions must be explicit

토큰과 다른 값을 사용하는 경우 코드 근처 또는 컴포넌트 명세에 이유를 기록한다.

허용 가능한 예외:

- 픽셀 정렬이 필요한 0.5/1pt hairline
- SF Symbol optical alignment
- Dock preset에 따라 비례 확대되는 geometry
- terminal/code처럼 별도 정보 밀도가 필요한 surface

"조금 더 예뻐 보여서"는 예외 사유가 아니다.
