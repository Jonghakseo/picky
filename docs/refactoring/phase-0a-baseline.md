# Phase 0A Baseline and Preflight

Date: 2026-05-02

Scope: documentation-only preflight for the behavior-preserving refactor. No production Swift or TypeScript runtime source was changed in this phase.

## Gate decision

**READY** for the first conservative Phase 1 slice.

Proceed-ready criteria:
- `pnpm --dir agentd test`: PASS
- `pnpm --dir agentd typecheck`: PASS
- `xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test`: PASS
- Xcode filesystem-synced root groups: confirmed
- Swift access-control checklist: recorded below
- Protocol fields changed in Phase 0A: no

## 0A-1 Working state

Command:

```bash
git status --short
git branch --show-current
```

Result:

```text
?? docs/REFACTORING.md
main
```

Notes:
- Branch: `main`.
- Working tree was not clean before this artifact was created: `docs/REFACTORING.md` was already untracked from the planning step.
- Phase 0A added only documentation artifacts; no production runtime files were edited.

## 0A-2 Toolchain versions

Command:

```bash
xcodebuild -version
node --version
pnpm --version
```

Result:

```text
Xcode 16.3
Build version 16E140
v22.11.0
10.15.1
```

## 0A-3 agentd test baseline

Command:

```bash
pnpm --dir agentd test
```

Result: PASS

Evidence:

```text
Test Files  10 passed (10)
Tests       71 passed (71)
```

Observed stderr was expected test coverage for corrupt metadata handling:

```text
Skipping unreadable Picky session metadata .../sessions/corrupt.json: Unexpected non-whitespace character after JSON at position 16 (line 2 column 1)
```

## 0A-4 agentd typecheck baseline

Command:

```bash
pnpm --dir agentd typecheck
```

Result: PASS / no type errors

Evidence:

```text
tsc -p tsconfig.json --noEmit
```

The command exited successfully without diagnostics.

## 0A-5 Swift/Xcode test baseline

Command:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
```

Result: PASS

Evidence:

```text
Test run with 76 tests passed after 3.635 seconds.
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/creatrip/Library/Developer/Xcode/DerivedData/Picky-ayfzdyoncbrdeaevflvabvbfqhee/Logs/Test/Test-Picky-2026.05.02_15-52-57-+0900.xcresult
```

Notes:
- The test host emitted normal app/test logs from the Xcode test process. Picky was not manually launched or restarted outside the requested test command.
- AppIntents metadata extraction warning was non-fatal: `Metadata extraction skipped. No AppIntents.framework dependency found.`
- Voice asset lookup warnings were non-fatal during tests.

## 0A-6 Xcode filesystem-synced groups

Command:

```bash
grep -n "PBXFileSystemSynchronizedRootGroup" Picky.xcodeproj/project.pbxproj
```

Result: confirmed

Evidence:

```text
45:/* Begin PBXFileSystemSynchronizedRootGroup section */
47:            isa = PBXFileSystemSynchronizedRootGroup;
55:            isa = PBXFileSystemSynchronizedRootGroup;
60:            isa = PBXFileSystemSynchronizedRootGroup;
64:/* End PBXFileSystemSynchronizedRootGroup section */
```

Guardrail:
- Swift file moves under synced roots should still be followed by `xcodebuild ... test`, because access control, generated accessors, resource paths, and runtime behavior can break independently of project references.

## 0A-7 Swift access-control checklist

Command:

```bash
rg -n "\b(fileprivate|private)\b" \
  Picky/PickySessionViewModel.swift \
  Picky/PickyContextPacket.swift \
  Picky/PickyAgentClient.swift \
  Picky/PickySettings.swift \
  Picky/PickySessionPolish.swift \
  Picky/DesignSystem.swift \
  Picky/BuddyDictationManager.swift
```

Result: checklist recorded.

### Decisions for Phase 1/3 splits

Default decision order:
1. Keep helper in original file when the helper is only used by the type in that file.
2. Move caller and helper together when extracting a cohesive type/extension.
3. Widen to `internal` only when a split would otherwise break compilation and the PR explicitly calls it out.

### File notes

#### `Picky/PickySessionViewModel.swift`

High-risk items before extraction:
- `private` stored state and methods on `PickySessionListViewModel` lines 164-183, 374-533.
- `private extension PickySessionListViewModel.SessionCard` at line 552.
- `private extension Array where Element == PickySessionListViewModel.SessionCard` at line 600.
- `private func pickySessionLog` at line 689.

Decision:
- For `SessionCard` extraction, keep `SessionCard` nested and move helper extensions with their callers if extracting to `PickySessionListViewModel+SessionCard.swift`.
- Do not promote nested types to top-level in Phase 1.
- Widen helper access only if a same-module extension split requires it and tests prove the behavior remains unchanged.

#### `Picky/PickyAgentClient.swift`

High-risk items:
- `WebSocketPickyAgentClient` private connection state lines 126-133.
- Receive/handle internals lines 184 and 207.
- `private func pickyAgentClientLog` line 226.
- `private extension PickyCommandEnvelope` line 231.
- `private extension PickyEventEnvelope` line 247.

Decision:
- Keep transport internals together when splitting protocol vs websocket implementation.
- If envelope debug helpers move to protocol-focused files, move all direct callers with them or deliberately widen to `internal` in the same PR.

#### `Picky/PickySettings.swift`

High-risk items:
- `private func validateDirectory` line 82.
- `private extension JSONEncoder` line 101.
- `PickySettingsViewModel` private store/validation state lines 112-114.

Decision:
- Keep store/validation helpers colocated with settings persistence unless a dedicated settings persistence file is extracted with tests.

#### `Picky/PickySessionPolish.swift`

High-risk items:
- `private static func path(fromDiffHeader:)` line 57.
- `private(set)` archive/search state lines 65-66.

Decision:
- Safe candidate for pure helper extraction only if tests around diff preview/search remain green.

#### `Picky/DesignSystem.swift`

High-risk items:
- Multiple SwiftUI `@State private` view-local fields.
- Multiple private button color helpers.
- `private class PointerCursorNSView` line 764.
- `private struct PointerCursorView` line 775.
- `private class IBeamCursorNSView` line 794.
- `private struct NativeTooltipView` line 825.

Decision:
- Split design-system components by moving each view/helper pair together.
- Cursor wrappers should move together; do not split `NSViewRepresentable` from its backing `NSView` unless access is deliberately widened and tested.

#### `Picky/BuddyDictationManager.swift`

High-risk items:
- `fileprivate` shortcut helper properties lines 54 and 67.
- `private enum ShortcutEventType` line 89 and shortcut transition helpers lines 131-157.
- Private dictation state and lifecycle methods lines 219-873.
- `private enum BuddyDictationStartSource` line 207.
- `private struct BuddyDictationDraftCallbacks` line 212.

Decision:
- Known required check: `BuddyPushToTalkShortcut` has `fileprivate` helper extensions used by `BuddyDictationManager`; Phase 3 must either keep helpers with their callers or widen access deliberately.
- Dictation lifecycle extraction is not a Phase 1 first slice; defer until smaller standalone splits prove the mechanics.

#### `Picky/PickyContextPacket.swift`

No `private` / `fileprivate` matches in the scan.

## 0A-8 Protocol/contract touch map

Commands:

```bash
find contracts -type f | sort
rg -n "pickyAgentProtocolVersion|PROTOCOL_VERSION|CommandEnvelope|EventEnvelope|PickyAgentSession" Picky agentd/src contracts
```

### Contract fixtures

```text
contracts/context/multi-screen.context.json
contracts/context/plain-text.context.json
contracts/context/sentry-url.context.json
contracts/context/slack-url.context.json
contracts/pi-events/abort-error.json
contracts/pi-events/agent-end.json
contracts/pi-events/agent-start.json
contracts/pi-events/extension-ui-request-confirm.json
contracts/pi-events/message-text-delta.json
contracts/pi-events/queue-update.json
contracts/pi-events/tool-end-error.json
contracts/pi-events/tool-end-success.json
contracts/pi-events/tool-start.json
contracts/pi-events/tool-update.json
contracts/prompts/sentry-url.expected.md
contracts/prompts/slack-url.expected.md
contracts/protocol/abort.request.json
contracts/protocol/artifact-opened.event.json
contracts/protocol/artifact-updated.event.json
contracts/protocol/create-task.request.json
contracts/protocol/error.event.json
contracts/protocol/extension-ui-form-request.event.json
contracts/protocol/extension-ui-request.event.json
contracts/protocol/extension-ui-response.request.json
contracts/protocol/follow-up.request.json
contracts/protocol/get-session.request.json
contracts/protocol/hello.event.json
contracts/protocol/list-sessions.request.json
contracts/protocol/open-artifact.request.json
contracts/protocol/quick-reply.event.json
contracts/protocol/route-task.request.json
contracts/protocol/session-log-appended.event.json
contracts/protocol/session-snapshot.event.json
contracts/protocol/session-updated.event.json
contracts/protocol/steer.request.json
contracts/protocol/tool-activity.event.json
```

### Protocol owner files

Swift:
- `Picky/PickyAgentProtocol.swift` owns `pickyAgentProtocolVersion`, `PickyCommandEnvelope`, `PickyEventEnvelope`, and `PickyAgentSession`.
- `Picky/PickyAgentClient.swift` encodes/decodes command and event envelopes.
- `Picky/PickySessionViewModel.swift`, `Picky/CompanionManager.swift`, and `Picky/PickyArtifactReporter.swift` consume session/command/event types.

TypeScript:
- `agentd/src/protocol.ts` owns `PROTOCOL_VERSION`, `CommandEnvelopeSchema`, `EventEnvelopeSchema`, `PickyAgentSessionSchema`, parsers, and inferred types.
- `agentd/src/server.ts` wraps outbound events with `PROTOCOL_VERSION` and parses inbound commands.
- `agentd/src/session-store.ts`, `agentd/src/session-supervisor.ts`, and `agentd/src/artifact-store.ts` persist/consume `PickyAgentSession`.

Tests:
- `agentd/src/protocol.test.ts` validates protocol fixtures.
- `agentd/src/server.test.ts` validates websocket hello/list-session protocol behavior.
- `agentd/src/__tests__/smoke.test.ts` asserts the current protocol version.
- Swift `ProtocolContractTests` decode protocol fixtures during `xcodebuild test`.

Guardrail:
- Phase 0A does not change protocol fields.
- Future protocol schema changes must update fixtures and both Swift/TypeScript tests in the same PR.

## 0A-9 Phase 1 execution notes

Recommended first Phase 1 PR slice:

1. Prefer an `agentd` pure domain helper extraction before high-risk Swift UI/dictation splits.
2. Good candidates are pure helper functions with existing coverage, for example artifact/report helpers or session status/merge helpers, while keeping `server.ts` root-level unless Phase 5 is explicitly approved.
3. If Swift is chosen first, start with standalone folder placement or design-system component pairs that keep private helpers and their callers together.

Phase 1 guardrails:
- No deterministic task routing in Picky.
- No protocol field changes.
- No runtime behavior changes.
- Tests must pass after every phase and every PR slice.
- Any `private`/`fileprivate` widening must be explicitly listed in PR notes.

## 0A-10 Gate summary

Phase 0A is **READY** because required baselines are green and preflight maps are recorded.

Remaining caution:
- The baseline working tree already included untracked `docs/REFACTORING.md`; do not mix additional unrelated work into the first refactor PR.
- Xcode tests execute the test host app, so test logs can include app startup lines even though no manual app launch/restart was performed.

## References

- Swift.org, Access Control: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
- TypeScript Handbook, Modules: https://www.typescriptlang.org/docs/handbook/modules/introduction.html
