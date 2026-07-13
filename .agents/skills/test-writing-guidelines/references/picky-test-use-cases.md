# Picky 테스트 유즈케이스

대상 변경과 관련된 섹션만 사용한다.

## 1. Reducer, state machine, policy

대표 대상:

- `Picky/Interaction/`
- HUD presentation/interaction policies
- queue, routing, formatting domain helpers

추천:

- 초기 state + event/input → 새 state + explicit effects를 직접 검증한다.
- 정상 경로와 함께 stale event, duplicate event, idempotency, cancellation, ordering을 검토한다.
- journal/log가 observability 계약이면 state/effect와 별도로 assertion한다.
- facade나 SwiftUI view를 통해 pure rule을 간접 테스트하지 않는다.

대표 근거:

- `PickyTests/PickyInteractionReducerTests.swift`
- `PickyTests/PickyVoiceInteractionMachineTests.swift`
- `PickyTests/PickyHUDDockInteractionPolicyTests.swift`
- `agentd/src/domain/queue-policy.test.ts`

## 2. Voice, PTT, quick input routing

핵심 계약:

- shortcut press 시점의 대상 session snapshot을 사용한다.
- 선택된 Pickle이 없을 때 submit, 있을 때 명시된 follow-up/steer 정책을 사용한다.
- voice input 중 CLI/quick reply가 TTS를 잘못 선점하지 않는다.
- release/finalizing/submitting/cancellation 전이가 stale callback에 안전하다.
- 실패가 processing state에 영구히 남지 않는다.

경계:

- 실제 마이크, NSSpeechSynthesizer, 외부 transcription/TTS API를 사용하지 않는다.
- agent client, selection store, capture coordinator, playback provider를 fake로 주입한다.
- manager orchestration 전에 routing policy/state machine에서 증명 가능한지 확인한다.

대표 근거:

- `PickyTests/PickyCompanionManagerTests.swift`
- `PickyTests/BuddyDictationManagerTests.swift`
- `PickyTests/PickyVoiceTranscriptRoutingPolicyTests.swift`
- `PickyTests/GlobalPushToTalkShortcutMonitorTests.swift`

## 3. Session ViewModel과 client routing

핵심 계약:

- session snapshot/event가 dock, selection, unread, queue 상태로 올바르게 반영된다.
- connect/hello 전 명령을 보내지 않는다.
- reconnect, malformed event, late event가 recoverable하다.
- abort/follow-up/steer 실패가 관찰 가능하다.

추천:

- WebSocket은 fake task/factory를 사용한다.
- ViewModel 전체보다 pure projection/policy가 owner인 규칙은 해당 policy에서 검증한다.
- process-global 상태나 system framework를 공유하면 serialized 이유를 명시한다.

대표 근거:

- `PickyTests/PickyAgentClientTests.swift`
- `PickyTests/PickyAgentClientRouterTests.swift`
- `PickyTests/PickySessionViewModelTests.swift`

## 4. SwiftUI/AppKit와 HUD

핵심 계약:

- 사용자가 보는 bubble/status/queue/activity/composer 상태
- keyboard shortcut와 focus routing
- dock grouping/collapse/resize interaction
- IME marked text와 AppKit text editing 보존

추천:

- `renderSnapshot`, presentation policy, interaction controller를 우선한다.
- 실제 SwiftUI hierarchy나 modifier order를 고정하지 않는다.
- IME/AppKit bridge처럼 framework behavior가 핵심이면 focused integration test를 사용한다.
- cursor-side bubble 변경은 관련된 두 presentation component를 모두 조사한다.
- layout identity나 성능 문제는 signpost/profile을 병행한다.

대표 근거:

- `PickyTests/PickyConversationCardViewTests.swift`
- `PickyTests/PickyHUDKeyboardShortcutPolicyTests.swift`
- `PickyTests/PickyIMETextViewTests.swift`
- `docs/perf-profiling.md`

## 5. app-agentd protocol

변경 세트:

- Swift Codable model
- TypeScript Zod schema/type
- shared JSON fixture
- Swift fixture decode/compatibility test
- TypeScript exact schema/fixture test

검토 케이스:

- required/optional/default 의미
- old payload without new fields
- unknown future fields/types
- enum spelling과 legacy tolerant decode
- timestamp, UUID, path normalization

한쪽 parser의 inline JSON test만 추가하고 완료하지 않는다.

대표 근거:

- `PickyTests/ProtocolContractTests.swift`
- `agentd/src/protocol.test.ts`
- `contracts/protocol/`

## 6. agentd session lifecycle

핵심 계약:

- create, queue, follow-up, steer, abort, archive, rewind
- runtime event → durable session/message/status projection
- persistence/reload/reconnect
- create/abort 및 late runtime completion race
- cancelled/failed terminal status가 늦은 event로 되돌아가지 않음

추천:

- 작은 mapper/policy는 unit으로 분리한다.
- lifecycle은 temporary `SessionStore` + `MockRuntime`/manual runtime으로 검증한다.
- Promise continuation으로 race 순서를 직접 제어한다.
- 실제 Pi process 또는 사용자 session file은 contract/smoke 목적이 아니면 사용하지 않는다.

대표 근거:

- `agentd/src/session-supervisor.test.ts`
- `agentd/src/session-supervisor-rewind.test.ts`
- `agentd/src/session-store.test.ts`
- `agentd/src/runtime/mock-runtime.test.ts`

## 7. Extension UI와 tool bridge

핵심 계약:

- form/request가 HUD에서 보이는 구조로 mapping된다.
- cancellation, missing UI, malformed answer가 명시적으로 처리된다.
- confirmation이 필요한 동작을 로그에 숨기지 않는다.

추천:

- tool execute 결과와 UI bridge request를 함께 검증한다.
- 실제 HUD window보다 bridge contract와 projection을 우선한다.

대표 근거:

- `agentd/src/application/ask-user-question-tool.test.ts`
- `agentd/src/application/extension-ui-request-mapper.test.ts`
- `PickyTests/PickyAskUserQuestionFormTests.swift`

## 8. Filesystem, installers, settings

핵심 계약:

- install/update/uninstall ownership marker
- conflict 시 사용자 파일 삭제 거부
- settings migration/default/sanitization
- diagnostic redaction과 artifact cleanup

추천:

- temporary home, bundle resource root, app support root를 주입한다.
- 실제 global Pi skill/extension, shell command, keychain을 수정하지 않는다.
- success뿐 아니라 conflict, outdated, unmanaged, partial failure를 검증한다.

대표 근거:

- `PickyTests/PickySkillInstallerTests.swift`
- `PickyTests/PickyExtensionInstallerTests.swift`
- `PickyTests/ShellCommandInstallerTests.swift`
- `PickyTests/PickySettingsSanitizerTests.swift`

## 9. Runtime와 package smoke

다음 변경에만 검토한다.

- `PickyAgentDaemonLauncher`
- bundled Node resolution/entitlement
- package resource copy
- daemon process lifecycle/port shutdown

일반 unit test가 먼저다. 실제 packaged app smoke가 필요하면 AGENTS의 mock runtime 절차를 사용하되, 실행 중인 Picky 앱을 재시작하지 않고 사용자에게 범위를 확인한다. 서명 앱이 필요하지 않으면 signed package script를 사용하지 않는다.

## 10. Bug regression

버그 회귀 테스트는 다음을 명시한다.

1. 버그가 발생한 정확한 state/context/session 조건
2. 이전 구현에서 실패하는 관찰 가능한 결과
3. 수정 후 기대 결과
4. 인접 정상 경로가 유지되는지
5. race/stale/duplicate가 원인이면 event 순서를 결정적으로 제어하는 방법

스크린샷으로 구현 의도를 우회하지 않는다. 가능한 경우 underlying policy/state contract를 고정한다.
