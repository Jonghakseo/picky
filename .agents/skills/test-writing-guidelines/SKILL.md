---
name: test-writing-guidelines
description: Picky 저장소에서 테스트 추가·작성, 회귀 테스트, TDD, 테스트 전략 수립, 테스트 레벨 선택, 기존 테스트 리뷰가 필요할 때 사용한다. Swift Testing, Vitest, app-agentd 프로토콜 계약, voice/PTT, HUD, 비동기 상태 전이 테스트 요청에서 트리거한다.
---

# Picky Test Writing Guidelines

이 스킬은 테스트 수를 늘리는 대신, Picky의 사용자·시스템 계약을 가장 작고 신뢰도 높은 계층에서 검증하도록 판단을 표준화한다.

핵심 목표:

- 테스트 전에 깨지면 안 되는 Picky 불변조건을 정의한다.
- Swift 앱, TypeScript agentd, 공유 프로토콜 중 올바른 검증 경계를 고른다.
- 실행 중인 Picky 앱이나 실제 사용자 환경을 건드리지 않는 결정적 테스트를 만든다.
- 사용자가 테스트 작성까지 요청했을 때만 테스트 파일을 수정한다.

## 필수 참조

활성화되면 먼저 다음을 읽는다.

1. `references/test-layer-decision.md` — Picky 테스트 계층과 선택 기준
2. `references/common-test-conventions.md` — Swift Testing/Vitest 공통 작성 규칙
3. `references/doc-map.md` — 변경 영역별 원본 문서와 대표 테스트 라우팅

대상 영역이 정해지면 필요할 때만 추가로 읽는다.

- `references/picky-test-use-cases.md` — voice, HUD, protocol, agentd lifecycle, installer 등 구체 사례
- `references/rule-gaps.md` — 문서와 기존 패턴이 부족하거나 충돌할 때의 처리

참조 문서는 저장소 원본 규칙을 복제하지 않는다. `references/doc-map.md`가 가리키는 원본 문서와 가까운 기존 테스트를 직접 확인한다.

## Workflow

### 1. 요청을 분류한다

하나 이상으로 분류한다.

- **TDD**: 구현 전에 실패할 계약 테스트를 먼저 정의한다.
- **버그 회귀**: 재현 조건과 수정 후 기대 결과를 고정한다.
- **구현 검증**: 변경된 정상·오류·취소 경로를 검증한다.
- **테스트 전략**: 여러 경계에 걸친 변경을 계층별 계획으로 나눈다.
- **테스트 리뷰**: 기존 테스트의 신뢰도, 결합도, 결정성을 검토한다.
- **실패 조사**: 제품 회귀와 flaky/환경 문제를 분리한다.

### 2. 근거를 수집한다

코드나 테스트를 작성하기 전에:

1. `git status --short`로 사용자 변경을 보호한다.
2. 대상 구현과 가장 가까운 테스트를 찾는다.
3. 대상 경로의 `AGENTS.md`와 `references/doc-map.md`가 연결하는 원본 문서를 읽는다.
4. Swift인지 agentd인지, 또는 양쪽 프로토콜 계약인지 식별한다.
5. 실제로 실행 가능한 가장 좁은 테스트 명령을 확인한다.
6. 기존 패턴의 신뢰도를 판단한다.
   - **High**: 원본 문서와 가까운 테스트 여러 개가 같은 계약 경계를 사용한다.
   - **Medium**: 유사 영역 패턴만 있다.
   - **Low**: 과한 mock, 임의 sleep, 실제 사용자 환경 의존, 구현 세부사항 고정, flaky 징후가 있다.

### 3. Picky 불변조건을 먼저 쓴다

최소 하나를 명시한다.

- Picky는 neutral context를 캡처하고 Pi가 intent를 해석한다.
- follow-up/steer/submit 대상은 명시적이고 예측 가능해야 한다.
- 장기 실행 Pickle의 상태, queue, abort, persistence, reconnect 계약이 보존되어야 한다.
- 사용자 액션 실패는 UI 상태, 반환값, 이벤트 또는 구조화 로그로 관찰 가능해야 한다.
- app-agentd 프로토콜은 Swift, TypeScript, fixture가 함께 호환되어야 한다.
- UI/voice 상태 전이는 stale, duplicate, cancellation, race에도 안전해야 한다.
- 테스트는 실행 중인 Picky 앱, 실제 `~/.pi`, 마이크, TTS, keychain, 외부 네트워크를 우연히 건드리지 않아야 한다.

### 4. 가장 작은 유효 계층을 고른다

`references/test-layer-decision.md`의 순서대로 검토한다.

1. Pure policy/reducer unit
2. Swift orchestration 또는 view projection
3. agentd unit
4. agentd integration
5. Cross-language protocol contract
6. UI/E2E 후보
7. Runtime/package smoke

같은 신뢰도를 주면 더 작고 빠른 계층을 선택한다. 모든 계층에 테스트를 추가하지 않는다. 선택하지 않은 상위 계층은 제외 이유를 남긴다.

### 5. Test Plan Card를 먼저 출력한다

테스트 코드를 작성하기 전에 다음 카드를 제시한다. 단순하고 계층 선택이 명백한 변경은 불필요한 항목을 한 줄로 축약할 수 있다.

```markdown
## Test Plan Card

- 변경 대상:
- 보장할 사용자/시스템 계약:
- 관련 Picky 불변조건:
- 후보 계층:
  - Pure policy/reducer:
  - Swift orchestration:
  - View projection:
  - agentd unit:
  - agentd integration:
  - Cross-language contract:
  - UI/E2E 또는 runtime smoke:
- 최종 선택과 제외 이유:
- 핵심 케이스:
  - 정상 경로:
  - 오류/취소:
  - stale/duplicate/race:
  - 이전 데이터·프로토콜 호환성:
- fake/mock 경계:
- 작성 위치:
- 가장 좁은 실행 명령:
- 전체 검증 필요 여부:
- 참고 근거:
- rule gap / 확인 질문:
```

### 6. 필요한 경우 질문한다

다음 상황에서는 추측으로 테스트를 작성하지 말고 `ask_user_question`을 사용한다.

- 실제 앱 재실행, macOS 권한, 실제 마이크/오디오, keychain, 외부 API 자격 증명이 필요하다.
- UI/E2E가 필요해 보이지만 permission/UI harness와 안정적인 oracle이 없다.
- 테스트가 실제 사용자 홈, 설치된 Pi, 실행 중인 daemon 또는 영구 파일을 변경할 수 있다.
- 문서와 가까운 테스트 패턴이 충돌해 계층 또는 mock 경계 선택이 크게 달라진다.
- 패키지/서명/runtime smoke 범위가 사용자 기대보다 커질 수 있다.

### 7. 요청된 경우에만 테스트를 작성한다

사용자가 테스트 구현을 요청한 경우:

- 기존 사용자 변경을 덮어쓰지 않는다.
- `references/common-test-conventions.md`와 가까운 High 신뢰도 패턴을 따른다.
- 외부 경계만 fake/mock하고 핵심 reducer/policy/SUT는 실제 구현을 사용한다.
- 정상 경로만이 아니라 관련 있는 오류, 취소, stale, duplicate, race를 검토한다.
- protocol 변경이면 Swift 모델, TypeScript schema, fixture, 양쪽 테스트를 하나의 계약 세트로 다룬다.
- 실제 앱을 재시작하지 않는다.

### 8. 좁은 검증부터 확대한다

1. 변경한 테스트 파일 또는 suite만 실행한다.
2. 관련 contract 또는 패키지 suite를 실행한다.
3. 필요할 때만 전체 agentd/Swift suite로 확대한다.
4. Swift 전체 suite는 저장소의 serial runner 지침을 따른다.
5. 실패 시 제품 회귀, 테스트 결함, 환경/flaky 가능성을 구분해 보고한다.

## 빠른 명령

```bash
# Swift 단일 suite
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  test -only-testing:PickyTests/<SuiteName>

# Swift 전체 suite: 공유 시스템 framework 충돌 방지를 위해 serial
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO test

# agentd 단일 파일
pnpm --dir agentd exec vitest run src/path/to/file.test.ts

# agentd protocol contracts
pnpm --dir agentd run test:contracts

# agentd 전체 suite
pnpm --dir agentd run test:serial
```

명령은 대상 파일과 현재 package scripts를 확인한 뒤 사용한다. 문서보다 실제 scripts가 달라졌다면 `rule gap`으로 보고한다.

## 완료 보고

계획만 작성한 경우:

- 선택한 테스트 계층과 제외 이유
- 핵심 계약과 케이스
- 작성 위치와 실행 명령
- 참고 근거와 rule gap

테스트까지 작성한 경우:

- 변경 파일
- 실행한 명령과 결과
- 검증한 계약
- 미실행 검사와 남은 리스크

## 금지

- 실행 중인 Picky 앱을 테스트 편의를 위해 재시작하지 않는다.
- 테스트에서 실제 `~/.pi`, Picky Application Support, keychain, 마이크 또는 외부 서비스에 의존하지 않는다.
- UI 구조, private state, 우연한 호출 순서만 고정하지 않는다.
- 임의의 긴 sleep으로 async race를 숨기지 않는다.
- 프로토콜 변경을 한 언어의 테스트만으로 완료 처리하지 않는다.
- HUD 성능 회귀를 기능 테스트만으로 증명했다고 주장하지 않는다.
