# Picky 테스트 계층 결정

테스트는 파일 종류가 아니라 보장할 Picky 계약으로 선택한다. 같은 신뢰도를 만들 수 있으면 가장 작고 빠르며 결정적인 계층을 사용한다.

## 판단 출발점: Picky의 약속

- 로컬 우선으로 동작하고 사용자 데이터를 불필요하게 외부로 보내지 않는다.
- 여러 Pickle이 장시간 실행되어도 상태, queue, abort, follow-up, persistence, reconnect가 예측 가능하다.
- Picky는 neutral context와 세션 UI를 담당하고 Pi가 intent와 workflow를 결정한다.
- voice, quick input, CLI, HUD 입력이 올바른 세션으로 명시적으로 routing된다.
- 사용자 액션의 실패가 조용히 사라지지 않는다.
- Swift 앱과 TypeScript agentd의 protocol 계약이 함께 진화한다.

## 계층 표

| 계층 | 역할 | 선택 기준 | Picky 예시 |
|---|---|---|---|
| Pure policy/reducer unit | 순수 불변조건과 상태 전이 | 입력, 상태, 출력/effect만으로 증명 가능 | interaction reducer, dock grouping, queue policy, formatter |
| Swift orchestration | 앱 객체 간 routing과 effect 실행 | manager/view model/coordinator와 주입된 fake의 상호작용이 계약 | voice target snapshot, client routing, installer controller |
| View projection | 사용자가 보는 상태의 경량 검증 | 실제 창 없이 projection/render snapshot으로 oracle이 명확 | conversation bubble count, status presentation, composer state |
| agentd unit | TypeScript 순수 도메인/application 규칙 | filesystem/runtime/server 없이 검증 가능 | categorizer, mapper, validation, prompt policy |
| agentd integration | lifecycle와 adapter 연결 | store/runtime/server/event 연결이 핵심 | SessionSupervisor, SessionStore, WebSocket server |
| Cross-language contract | 앱-daemon wire compatibility | protocol field/type/default/fixture가 바뀜 | Swift Codable + Zod + `contracts/protocol` |
| UI/E2E 후보 | 실제 macOS UI 연결성 | window, permission, focus, global shortcut가 핵심 oracle | menu bar, permission onboarding, real shortcut routing |
| Runtime/package smoke | 번들 실행 가능성 | Node bundle, launcher, signing, packaged resources가 변경됨 | packaged mock runtime startup/shutdown |

## 결정 순서

1. 입력과 출력만으로 규칙을 증명할 수 있는가? → Pure policy/reducer 또는 agentd unit
2. 앱 객체의 routing/effect 실행이 핵심인가? → Swift orchestration
3. 사용자에게 보이는 상태가 projection으로 관찰 가능한가? → View projection
4. store/runtime/server를 실제로 연결해야 계약이 드러나는가? → agentd integration
5. wire shape 또는 호환성이 변하는가? → Cross-language contract를 반드시 추가
6. 실제 macOS UI/권한/포커스가 아니면 증명할 수 없는가? → UI/E2E 후보로 분리
7. 번들 앱 자체가 실행되어야만 증명되는가? → Runtime/package smoke

## 계층별 경계

### Pure policy/reducer

상태와 명시적 effect를 함께 검증한다. stale event, duplicate, cancellation, idempotency, ordering이 관련되면 정상 경로와 같은 중요도로 다룬다. facade나 ViewModel을 통해 간접 검증하지 않는다.

### Swift orchestration

SUT는 실제 구현으로 두고 WebSocket, audio provider, selection store, filesystem root, clock 같은 외부 경계를 fake로 주입한다. `@MainActor` 소유 상태는 MainActor에서 관찰한다.

### View projection

실제 SwiftUI hierarchy보다 `renderSnapshot`, presentation policy, 접근 가능한 label/text/state를 우선한다. view identity나 rendering performance는 기능 assertion만으로 증명하지 않는다.

### agentd integration

임시 디렉터리와 `MockRuntime`/manual runtime을 사용한다. 실제 daemon, Pi 세션, 사용자 Application Support를 사용하지 않는다. create/abort/follow-up race와 terminal state 보존은 대표 integration 계약이다.

### Cross-language contract

다음을 하나의 변경 세트로 확인한다.

- `Picky/PickyAgentProtocol.swift`
- `agentd/src/protocol.ts`
- `contracts/protocol/`
- `PickyTests/ProtocolContractTests.swift`
- `agentd/src/protocol.test.ts`

양쪽 parser가 fixture를 읽는 것뿐 아니라 optional/default/unknown-field 호환성도 검토한다.

### UI/E2E 후보

현재 자동 생성된 `PickyUITests`는 menu-bar 앱의 permission/UI harness를 신뢰성 있게 제공하지 않는다. 단순 UI 분기를 이유로 XCUI 테스트를 추가하지 않는다. 실제 UI oracle이 필수라면 먼저 harness, 초기 상태, 권한, cleanup을 정의하고 사용자에게 범위를 확인한다.

### Runtime/package smoke

일반 코드 변경에는 사용하지 않는다. launcher, bundled Node, resource copy, entitlement/signing 경계가 바뀔 때만 검토한다. 실행 중인 Picky 앱은 재시작하지 않는다.

## 여러 계층이 필요한 경우

- protocol 변경: Cross-language contract + 해당 domain unit/integration
- server 계산 결과를 HUD가 표시: agentd unit/integration + Swift projection
- reducer effect를 manager가 실행: reducer unit + 얇은 orchestration test
- package resource 설치: filesystem unit/orchestration + 필요 시 package smoke

상위 테스트는 하위 테스트의 조합 전체를 반복하지 말고 연결점만 얇게 검증한다.
