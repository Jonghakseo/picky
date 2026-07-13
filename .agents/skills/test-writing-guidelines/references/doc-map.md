# Picky 테스트 문서 라우팅 맵

스킬 reference는 원본 문서의 대체 SSOT가 아니다. 대상 영역에 해당하는 원본과 가까운 테스트만 읽는다.

## 공통 읽기 순서

1. `AGENTS.md`
2. 이 스킬의 `references/common-test-conventions.md`
3. 아래 원본 문서
4. 대상 구현과 가까운 기존 테스트
5. 충돌하거나 근거가 약하면 `references/rule-gaps.md`

## 원본 문서

| 변경 영역 | 원본 문서 | 확인할 내용 |
|---|---|---|
| 구조적 refactor | `docs/refactoring-principles.md` | characterization test, invariant ownership, protocol set |
| Swift async/UI | `docs/swift-concurrency.md` | MainActor-first, Task/actor 경계 |
| HUD rendering/perf | `docs/perf-profiling.md` | signpost와 profile 근거 |
| 전체 architecture | `ARCHITECTURE.md` | app-agentd 책임과 local-first 경계 |
| packaging/runtime | `AGENTS.md`, package scripts | bundled Node와 smoke 절차 |

## Swift 앱

| 대상 | 대표 구현 | 대표 테스트 |
|---|---|---|
| interaction state/effects | `Picky/Interaction/` | `PickyTests/PickyInteractionReducerTests.swift`, `PickyTests/PickyInteractionStateMachineTests.swift` |
| voice/PTT | `Picky/CompanionManager.swift`, `Picky/Companion/Dictation/` | `PickyTests/PickyCompanionManagerTests.swift`, `PickyTests/BuddyDictationManagerTests.swift` |
| agent client/protocol routing | `Picky/PickyAgentClient.swift`, `Picky/PickyAgentClientRouter.swift` | `PickyTests/PickyAgentClientTests.swift`, `PickyTests/PickyAgentClientRouterTests.swift` |
| session/HUD | `Picky/PickySessionViewModel.swift`, `Picky/HUD/` | `PickyTests/PickySessionViewModelTests.swift`, `PickyTests/PickyConversationCardViewTests.swift` |
| pointer overlay | `Picky/PointerOverlay/` | `PickyTests/PickyPointerOverlayResolverTests.swift` |
| settings/installers | `Picky/App/Settings/`, `Picky/App/PickySkillInstaller.swift` | `PickyTests/PickySettingsSanitizerTests.swift`, `PickyTests/PickySkillInstallerTests.swift` |
| AppKit text/IME | conversation composer/text bridge | `PickyTests/PickyIMETextViewTests.swift`, `PickyTests/PickyMarkdownInlineTextViewTests.swift` |

## agentd

| 대상 | 대표 구현 | 대표 테스트 |
|---|---|---|
| WebSocket server/protocol | `agentd/src/server.ts`, `agentd/src/protocol.ts` | `agentd/src/server.test.ts`, `agentd/src/protocol.test.ts` |
| session lifecycle | `agentd/src/session-supervisor.ts`, `agentd/src/session-store.ts` | `agentd/src/session-supervisor.test.ts`, `agentd/src/session-store.test.ts` |
| runtime adapters | `agentd/src/runtime/` | `agentd/src/runtime/pi-sdk-runtime.test.ts`, `agentd/src/runtime/mock-runtime.test.ts` |
| prompt/context | `agentd/src/prompt-builder.ts`, `contracts/prompts/`, `contracts/context/` | `agentd/src/prompt-builder.test.ts` |
| extension UI/tools | `agentd/src/application/` | 가까운 `*.test.ts`, 특히 ask-user-question/handoff/pointer tests |
| domain policies | `agentd/src/domain/` | 같은 디렉터리의 `*.test.ts` |

## Cross-language protocol

항상 함께 확인한다.

- `Picky/PickyAgentProtocol.swift`
- `agentd/src/protocol.ts`
- `contracts/protocol/`
- `PickyTests/ProtocolContractTests.swift`
- `agentd/src/protocol.test.ts`

## 검증 명령 라우팅

### Swift 단일 suite

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  test -only-testing:PickyTests/<SuiteName>
```

### Swift 전체 suite

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO test
```

전체 suite를 병렬 실행하면 shared Speech/Audio/launcher framework 초기화가 충돌할 수 있으므로 serial 지침을 유지한다.

### agentd 단일 파일

```bash
pnpm --dir agentd exec vitest run src/path/to/file.test.ts
```

### agentd contract/전체

```bash
pnpm --dir agentd run test:contracts
pnpm --dir agentd run test:serial
pnpm --dir agentd run typecheck
```

현재 명령은 실행 전에 `agentd/package.json`과 `scripts/pre-push-checks.sh`에서 재확인한다.
