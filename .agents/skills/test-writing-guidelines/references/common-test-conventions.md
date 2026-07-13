# Picky 공통 테스트 컨벤션

## 적용 우선순위

1. 대상 경로의 가장 가까운 `AGENTS.md`
2. 저장소 원본 문서 (`docs/refactoring-principles.md`, `docs/swift-concurrency.md`, `docs/perf-profiling.md` 등)
3. 이 reference
4. 대상과 가까운 High 신뢰도 테스트
5. 충돌하거나 근거가 약하면 `rule gap`

기존 테스트를 일관성만을 이유로 무비판적으로 복제하지 않는다.

## 테스트 이름

현재 저장소의 Swift와 TypeScript 패턴에 맞춰 영문 계약형 이름을 사용한다.

- 조건과 기대 결과를 이름에서 알 수 있게 쓴다.
- Swift `@Test func`는 구체적인 lowerCamelCase 계약명으로 쓴다.
- Vitest `it`/`test` 설명은 관찰 가능한 결과를 문장으로 쓴다.
- `works`, `handles case`, `testExample`처럼 실패 의미가 불명확한 이름을 피한다.
- `regression`, `after fix` 같은 진행 상태 대신 실제 조건과 결과를 적는다.

## 구조와 assertion

- Arrange/Act/Assert 또는 Given/When/Then 흐름을 유지하되 주석은 의무가 아니다.
- 한 테스트는 하나의 불변조건 또는 밀접한 하나의 계약을 설명한다.
- 상태 전이는 이전 상태, 입력 event/action, 새 상태와 effect를 구분한다.
- assertion 실패만 보고도 어떤 계약이 깨졌는지 알 수 있어야 한다.
- 전체 object/snapshot 고정보다 관련 field, state, effect, event를 직접 검증한다.

## Swift Testing

`PickyTests`는 기본적으로 Swift Testing을 사용한다.

- `import Testing`, `@Test`, `#expect`, `#require`, `Issue.record`를 사용한다.
- throw/optional precondition은 `#require`로 이후 assertion을 명확하게 만든다.
- UI/ViewModel/manager 상태가 MainActor 소유면 suite 또는 test를 `@MainActor`로 둔다.
- process-global 설정이나 공유 system framework 때문에 병렬 안전하지 않을 때만 `@Suite(.serialized)`를 사용하고 이유를 남긴다.
- XCUI가 실제 oracle인 경우 외에는 새 `XCTestCase` 기반 테스트를 기본값으로 삼지 않는다.

## Vitest

`agentd`는 Vitest를 사용한다.

- `describe`, `it`/`test`, `expect`, `vi`를 사용한다.
- 순수 domain 규칙은 filesystem/runtime/server 없이 직접 검증한다.
- store/lifecycle 테스트는 `mkdtemp`와 mock/manual runtime을 사용한다.
- 실제 Pi SDK 계약을 검증하는 테스트와 mock runtime 테스트를 구분한다.
- test file만 실행할 수 있으면 전체 suite보다 먼저 실행한다.

## Fake와 mock 경계

SUT와 핵심 정책은 실제 구현으로 둔다. fake/mock은 다음 경계에 둔다.

- WebSocket task/factory와 daemon client
- Pi runtime handle과 runtime event source
- audio transcription/playback provider
- clock, UUID/id factory, timer scheduler
- filesystem root, user defaults, keychain adapter
- macOS permission/system API
- 외부 HTTP/API

호출 횟수나 순서는 다음처럼 실제 계약일 때만 검증한다.

- idempotency 또는 duplicate suppression
- 외부 API/daemon에 명령을 보내지 않아야 함
- queue order와 exactly-once dispatch
- abort/cancellation 이후 effect가 다시 실행되지 않음

## Async와 concurrency

- 테스트 편의를 위해 production concurrency ownership을 우회하지 않는다.
- 고정된 긴 `Task.sleep`보다 event, continuation, injected scheduler 또는 timeout이 있는 `waitUntil`을 사용한다.
- timing 자체가 계약일 때만 짧은 controlled delay를 사용한다.
- fake의 mutable state가 actor 경계를 넘으면 actor, lock 또는 MainActor isolation으로 보호한다.
- timeout은 실패 시 무한 대기를 막는 안전장치이지 race를 숨기는 수단이 아니다.
- cancellation, stale callback, late completion이 관련된 변경은 해당 race를 직접 재현한다.

## Fixture와 임시 상태

- 결과에 영향을 주는 값은 테스트 본문에서 드러낸다.
- 날짜, UUID, session ID, context ID는 결정적인 값을 우선한다.
- filesystem 테스트는 고유한 temporary directory를 만들고 cleanup한다.
- 실제 `~/.pi`, Picky Application Support, keychain, installed CLI/skill을 변경하지 않는다.
- fixture가 여러 테스트에서 반복될 때만 builder/helper로 추출한다.

## UI와 snapshot

- private SwiftUI state, view hierarchy, modifier 순서, pixel 상수를 우연히 고정하지 않는다.
- 사용자에게 보이는 text, status, enabled state, projection, routing action을 검증한다.
- Picky의 `renderSnapshot`이나 pure presentation policy로 충분하면 실제 window를 띄우지 않는다.
- snapshot/golden은 serialization 또는 diff 자체가 계약일 때만 사용한다.
- HUD identity/performance 변경은 `docs/perf-profiling.md`의 측정 근거를 별도로 요구한다.

## Protocol

wire field/type/default가 바뀌면 Swift와 TypeScript 양쪽 테스트 및 fixture를 갱신한다. 새 field가 optional인지, 구버전 payload가 decode되는지, unknown future field가 안전한지 검토한다.

## 검증 순서

1. 새로 작성하거나 변경한 단일 suite/file
2. 관련 contract/package suite
3. 필요한 경우 전체 suite

Swift 전체 suite는 system framework 충돌을 피하기 위해 `-parallel-testing-enabled NO`를 사용한다. 실패가 unrelated로 보이면 임의로 수정하지 말고 명령, 핵심 로그, 영향 여부를 보고한다.

## 빠른 체크리스트

- [ ] 사용자/시스템 계약과 Picky 불변조건이 명확한가?
- [ ] 더 작은 계층에서 같은 신뢰를 얻을 수 없는가?
- [ ] SUT 또는 핵심 정책을 mock하지 않았는가?
- [ ] async test가 event-driven이고 bounded인가?
- [ ] 실제 사용자 환경이나 실행 중인 앱을 건드리지 않는가?
- [ ] protocol 변경이면 양쪽 언어와 fixture를 검증하는가?
- [ ] 실패 메시지만 보고 회귀 범위를 좁힐 수 있는가?
