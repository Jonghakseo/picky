# pi-coding-agent coupling map

This doc is the running inventory of every place picky-agentd reaches into
`@earendil-works/pi-coding-agent`. It exists because pi is a fast-moving
runtime and a silent behavioural change there has bitten Picky before — the
`runtime.session.sessionFile` timing race that hid the Messages tab's "Open in
Pi" / "Copy resume command" buttons after the pi 0.74 bump. Treat this doc as
the **pre-upgrade checklist for every pi version bump**.

## Stability tiers

| Tier | Examples | What breaking means | Where it's enforced |
|------|----------|---------------------|---------------------|
| **T1 — Public API** | `defineTool`, `createAgentSessionServices`, `ModelRuntime` provider auth/status/login, `SettingsManager`, `DefaultPackageManager`, `AgentSession.prompt`, `AgentSession.subscribe`, `AgentSession.bindExtensions`, `AgentSession.messages`, `AgentSession.setScopedModels` | Daemon cannot boot or pi cannot answer at all | `src/__tests__/pi-contract.test.ts` (hard fail), TypeScript types |
| **T2 — Capability sniffs** | `setThinkingLevel`, `cycleThinkingLevel`, `cycleModel`, `getContextUsage`, `compact`, `reload`, `executeBash`, `recordBashResult`, `isCompacting`, `extensionRunner.emitUserBash` | One pi runtime feature silently no-ops (e.g. `/compact` becomes "not supported", thinking level cycling does nothing) | `src/runtime/pi-capabilities.ts` wraps each sniff, logs `pi capability absent` per session; `pi-contract.test.ts` warns (not fails) on absence so back-compat builds keep passing |
| **T3 — Internal shapes** | `session.state.messages` array layout, `ModelRuntime.credentials.store.reload` compatibility bridge, `PromptOptions.preflightResult` (`started` / `queued` / `handled` are accepted; rejection throws), `assistantMessage.content[]` blocks (`{type:"text"}` / `{type:"toolCall"}` / `{type:"toolResult"}`), `session.model.{api,provider,id}` with `state.model` fallback, pi `subscribe()` event types (`agent_start`, `message_update`, `turn_end`, `agent_end`, ...) and field names (`stopReason`, `toolCallId`, `toolName`) | Subtle, hard-to-detect regressions (lost session file path, stale live credentials, dropped status events, malformed bootstrap, stale tool-call repair) | Centralised in `pi-event-normalizer.ts` + `pi-capabilities.ts`; credential reload and state shape are hard-gated in `pi-contract.test.ts` |
| **T4 — Lifecycle assumptions** | `runtime.session.sessionFile` exposed synchronously after `createHandle()`, `reportDiagnostics()` scheduled via `setTimeout(0)`, `setRebindSession` invoked when pi swaps the inner session | Race conditions that drop events between handle creation and subscription | Documented inline in `pi-sdk-runtime.ts` (`bindCurrentSession` race guard, `createPrewarmedMainHandle` early-attach comment); fragile, no automated guard |

## File-by-file inventory

### Hot path: `agentd/src/runtime/pi-sdk-runtime.ts`

Single largest pi consumer. All `as unknown as` capability sniffs have been
moved to `pi-capabilities.ts`; only **typed** pi surfaces remain inline:

- `this.runtime.session.prompt`, `abort`, `subscribe`, `bindExtensions`,
  `clearQueue`, `getSteeringMessages`, `getFollowUpMessages`, `steeringMode`,
  `followUpMode`, `isStreaming`, `sessionFile`, `setSessionName`
- `this.runtime.session.extensionRunner.getRegisteredCommands()` (slash
  command catalog)
- `this.runtime.session.resourceLoader.getSkills().skills`
- `this.runtime.session.promptTemplates`
- `this.runtime.session.messages` (T1 — typed read for bootstrap injection)
- `this.runtime.session.state.messages` (T3 — typed direct mutation in
  `injectInitialBootstrap`; defensive structural repair in `repairDanglingToolCalls`)
- `this.runtime.session.sessionManager.appendMessage` (T3)
- `this.runtime.setRebindSession(...)` (T4)
- `this.runtime.session` subscribe/unsubscribe race guard (T4) — see the
  `bindCurrentSession()` reentry comment for the long-form explanation.

### Capability wrappers: `agentd/src/runtime/pi-capabilities.ts`

Single chokepoint for optional `AgentSession` capabilities. Since Pi 0.84 these
surfaces are read directly from the public type; runtime `typeof` guards remain so
older or reshuffled builds still fail soft. Each wrapper:

1. Uses Pi's public method signature without a structural type assertion.
2. Returns `undefined` / a discriminated `{ supported: false }` when the
   underlying pi method is missing at runtime.
3. Logs `pi capability absent` once per (sessionId, capability) pair so a
   silent pi regression shows up in `agentd.stdout.log`.

Wrappers (T2):
`trySetThinkingLevel`, `tryCycleThinkingLevel`, `tryCycleModel`,
`tryGetContextUsage`, `tryCompact`, `tryReload`, `isCompacting`,
`tryGetBashSurface` (executeBash + recordBashResult + emitUserBash),
`tryRefreshSystemPromptFromActiveTools` (getActiveToolNames + setActiveToolsByName),
`readModelMetadata`, `readThinkingLevel`.

Adding a new sniff? Add it here AND in `pi-contract.test.ts`'s
`SOFT_SESSION_MEMBERS` list AND update the T2 row above.

### Event normalizer: `agentd/src/domain/pi-event-normalizer.ts`

Pure-function translator from pi's raw `subscribe()` event payloads to
Picky's `RuntimeEvent`. String-keyed switch on pi event `type` values:

```
agent_start | message_update | tool_execution_start | tool_execution_update
| tool_execution_end | extension_ui_request | session_info
| session_info_changed | turn_end | agent_end | extension_error
| auto_retry_end
```

Sub-discriminators inside `assistantMessageEvent`:

```
text_delta | thinking_delta | error
```

Stop-reason values inspected at terminal events:

```
error | aborted | toolUse | end_turn (plus pass-through for unknown values)
```

This file uses `asRecord` / `stringValue` / `requiredString` defensively.
If pi adds a new event type we care about, extend the switch and the
`NormalizedPiEvent` discriminated union here; no compile-time gate exists.

### Strict UI bridge: `agentd/src/application/extension-ui-bridge.ts`

Implements `ExtensionUIContext` directly (T1). Object literal is typed as
`ExtensionUIContext` so a future pi version that adds an interface method
fails the build with TS2741, and removed methods surface as TS2353.

Picky-side extras (`askUserQuestion`, snake_case `ask_user_question`) are
layered onto the result via `Object.assign` AFTER the strict object so they
cannot mask a missing pi method.

`addAutocompleteProvider` is host-neutral and is composed in agentd over Pi's
`CombinedAutocompleteProvider`; query/apply results cross the app protocol as
UTF-16 cursor metadata. `setEditorComponent` / `getEditorComponent` remain
unsupported because their factories consume raw terminal input and render ANSI
components. The native HUD editor only projects the active completion prefix
with temporary AppKit attributes.

### Provider authentication: `agentd/src/application/pi-oauth-service.ts`

Picky Settings OAuth uses the public async `ModelRuntime` facade (`getProvider`,
`getProviderAuthStatus`, `login`) through an owner-bound interactive coordinator.
The Swift app never imports Pi files or discovers a global `pi` executable. Active
runtime handles reload the file-backed credential snapshot through the single
`pi-capabilities.ts.reloadModelRuntimeCredentials` compatibility sniff, then call
public `ModelRuntime.refresh({ allowNetwork: false })`. Remove the sniff when Pi
publishes a first-class credential reload API.

### Tool definitions: `agentd/src/application/*-tool.ts`

`ask-user-question-tool.ts` and `user-guide-tool.ts` use `defineTool` +
`ToolDefinition` from Pi (T1). Low risk; Pi rarely changes tool schema. The
Picky handoff command is a Pi extension under `pi-extensions/picky-handoff/`,
not an agentd tool definition.

### Package operations: `agentd/src/application/package-operations.ts`

Uses `SettingsManager`, `DefaultPackageManager`, and `getAgentDir` (T1) for
package listing, install/update/remove operations, and installed-extension
resolution. Track these imports and constructor calls in the audit-on-bump
checklist.

## Per-bump upgrade checklist

When bumping pi (`agentd/package.json` `@earendil-works/pi-coding-agent`):

1. **Run the contract tests first**: `cd agentd && pnpm exec vitest run src/__tests__/pi-contract.test.ts src/runtime/pi-oauth-service.test.ts`.
   - Hard-tier failures: investigate immediately. The bump is unsafe.
   - Soft-tier warnings: capture in the upgrade notes; verify the affected
     `pi-capabilities.ts` wrapper still has a sensible fallback. If the
     fallback drops user-visible functionality, surface that in the bump
     PR description.
2. **Read pi CHANGELOG.md** for the version range you're crossing. Anything
   under "Breaking" or "Changed" near `AgentSession`, `SessionManager`,
   `ExtensionUIContext`, or `extensions` deserves a re-read of T3 / T4
   touch points (`pi-event-normalizer.ts`, `pi-sdk-runtime.ts`
   `injectInitialBootstrap`, `repairDanglingToolCalls`,
   `bindCurrentSession`).
3. **Run the full agentd suite**: `cd agentd && pnpm test`. The supervisor
   regression at `session-supervisor.test.ts` "captures pi session file
   emitted via setTimeout(0) inside prewarm before patchMainState resolves"
   guards the most recent race; new pi-related regressions should land
   alongside an equivalent guard.
4. **Build the app**: `xcodebuild -project Picky.xcodeproj -scheme Picky
   -destination "platform=macOS,arch=$(uname -m)" build`. Picky's Swift
   side does not directly import pi but it consumes events the daemon
   forwards. New pi event types may need new normalizer branches.
5. **Manual smoke**: relaunch via `./scripts/run-dev-signed-app.sh`, send
   one main-agent turn, confirm Messages tab shows "Open in Pi" /
   "Copy resume command", trigger a Pickle handoff, confirm the Pickle
   reports back. Check `~/Library/Application Support/Picky/Logs/agentd.stdout.log`
   for `pi capability absent` entries — each one is a soft regression
   surface to triage before merging.

## Bump notes

### 0.74.0 -> 0.75.1

- Pi 0.75.0 raises the minimum Node.js runtime to 22.19.0. Picky packages that
  are built through `scripts/package-signed-app.sh` now bundle a pinned Node
  runtime under `Contents/Resources/agentd-runtime/bin/node`; source/dev builds
  and `PICKY_SKIP_NODE_BUNDLE=1` packages still fall back to `PICKY_NODE_PATH`
  or `/usr/bin/env node`.
- No CHANGELOG entry in this range calls out a breaking `AgentSession`,
  `ExtensionUIContext`, tool schema, or extension registration API change. Keep
  the normal contract test + full agentd suite as the upgrade gate because
  Picky still depends on T3/T4 internal session/event shapes.

### 0.75.1 -> 0.78.0

- This bump pinned Pi packages to `0.78.0` at the time. Treat the older bump
  notes above as historical context, not the current dependency version.
- `pi-capabilities.ts` also sniffs active-tool refresh support via
  `tryRefreshSystemPromptFromActiveTools`, backed by `getActiveToolNames` /
  `setActiveToolsByName` when present. Keep this T2 capability non-fatal and
  update warn-only contract coverage if the upstream surface changes.

### 0.80.3 -> 0.80.6

- Pi 0.80.6 adds the opt-in `max` thinking level across the SDK and model
  selection. Picky now preserves `max` through daemon schemas, session event
  normalization, Swift protocol decoding, and Pi/Pickle settings.
- No changelog entry in 0.80.4-0.80.6 removes or changes Picky's T1-T4
  `AgentSession`, extension UI, tool definition, or event surfaces.

### 0.80.6 -> 0.80.7

- Pi 0.80.7 adds cache-friendly dynamic extension tool loading. Picky supplies
  its SDK tools up front and does not dynamically activate tools during a run,
  so no runtime code change is required.
- The release removes the `openai-responses` `compat.sendSessionIdHeader`
  models setting in favor of `compat.sessionAffinityFormat`. Picky does not
  define either setting, so the breaking configuration change does not affect
  the daemon or bundled handoff extension.
- No changelog entry removes or changes Picky's T1-T4 `AgentSession`, extension
  UI, tool definition, command registration, or event surfaces.

### 0.80.7 -> 0.81.1

- Pi 0.80.8 replaces `AgentSessionServices.modelRegistry` with the async
  `modelRuntime` facade. Picky now resolves available models through
  `modelRuntime.getAvailable()` and checks provider-scoped authentication with
  `modelRuntime.hasConfiguredAuth(model.provider)`.
- Pi 0.81.0 adds full provider extension registration, model refresh, filtering,
  authentication, and custom streaming. Picky creates sessions through Pi's
  public service/runtime factories, so loaded user extensions inherit the new
  provider support after the `modelRuntime` migration.
- Tool, compaction, and branch-summary usage is now persisted in Pi sessions and
  included in Pi's session totals. Picky's HUD context meter intentionally keeps
  using `AgentSession.getContextUsage()` because it represents the active context
  window rather than cumulative session cost.
- Pi 0.81.1 adds summarization retry lifecycle events. Picky's existing
  `compaction_start`/`compaction_end` handling keeps the HUD in a running state
  while Pi retries internally; the finer-grained events are currently ignored
  fail-closed and can be surfaced later if retry-attempt UI is desired.
- Pi 0.81.1 restores the default stream fallback for extensions built against
  the pre-0.81 agent-core API, improving compatibility for user-installed
  extensions without requiring another daemon adapter.
- The SDK bump also removed OAuth orchestration from `AuthStorage`. Picky's
  Settings helper previously deep-imported `dist/core/auth-storage.js`, so both
  provider cards failed at runtime on `getOAuthProviders()`. OAuth now runs in
  typed agentd code through public `ModelRuntime`; app-daemon contract tests and
  a real pinned-SDK status smoke guard this path.
- Existing sessions still need credential snapshot refresh after another
  `ModelRuntime` writes `auth.json`. Pi 0.81.1 has no public reload method, so
  Picky temporarily hard-gates the centralized
  `ModelRuntime.credentials.store.reload` compatibility bridge.

### 0.81.1 -> 0.82.0

- Pi 0.82.0 adds constrained tool sampling through an optional inherited
  `Tool.constrainedSampling` field. Picky's `defineTool` definitions continue to use
  the default sampling contract, so no tool schema or execution change is required.
- Built-in and factory-created bash tools now expose Pi session/model metadata through
  environment variables. Picky delegates direct bash execution to `AgentSession.executeBash`,
  so the metadata is inherited without changing the `PiBashSurface` adapter.
- Direct RPC bash commands now emit correlated `bash_execution_update` events. Picky uses
  the SDK `AgentSession` surface rather than Pi's RPC command transport, so no protocol or
  event-normalizer change is required.
- The release contains no breaking `AgentSession`, `ExtensionUIContext`, tool definition,
  command registration, model runtime, or session event changes. The pinned `pi-ai`,
  `pi-coding-agent`, and `pi-tui` packages are kept on the same `0.82.0` release line.

### 0.82.0 -> 0.83.0

- Pi 0.83.0 upgrades its bundled TypeBox aliases to 1.3.7 and removes `Type.Base`,
  `Type.Awaited`, `Type.Promise`, `Type.AsyncIterator`, `Type.Iterator`,
  `Type.Options`, and `Value.Mutate`. Picky's tool schemas only use
  `Type.Any/Boolean/Literal/Number/Object/String/Union`, so no schema migration was
  required. `agentd/package.json` moved its direct `typebox` dependency from
  `^1.1.37` to `^1.3.7` so the daemon and Pi share one resolved TypeBox instance
  instead of loading 1.1.37 alongside Pi's 1.3.7.
- Pi adds the non-terminal `"pending"` stop reason for partial streaming messages.
  It only appears on in-flight provider partials, which reach Picky through
  `message_update` deltas; `turn_end` / `agent_end` still carry terminal reasons
  only. `terminalStatusFromStopReason` therefore needs no new branch. If a future
  Pi ever emits `turn_end` with `"pending"`, the normalizer would misread it as a
  completed turn — that is the branch to revisit.
- Unmapped provider terminal reasons now surface as provider errors instead of
  successful stops. Picky inherits this as `stopReason: "error"` -> `failed`, which
  is the intended fail-closed direction for Pickle status.
- Pi fixes session replacement during an active response to abort and persist the
  outgoing turn instead of leaving dangling tool calls. Picky's
  `repairDanglingToolCalls` stays as a defensive T3 guard; it is now expected to
  find fewer dangling calls, not none.
- Pi fixes skills, prompts, and themes losing package source metadata after a
  resource reload. Picky reads only name/description off
  `resourceLoader.getSkills().skills` and `promptTemplates`, so this is an upstream
  improvement with no host change.
- `ctx.scopedModels` is newly exposed to extensions. Picky already passes
  `scopedModels` at session creation for fixed-model overrides and does not consume
  the extension-side read.
- The release contains no breaking `AgentSession`, `ExtensionUIContext`, tool
  definition, command registration, or model runtime changes. `pi-ai`,
  `pi-coding-agent`, and `pi-tui` are kept on the same `0.83.0` release line.

### 0.83.0 -> 0.84.0

Official source: [Pi coding-agent CHANGELOG 0.84.0](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md#0840---2026-08-06).

- JSON/RPC `message_update` now carries only `assistantMessageEvent` deltas. Picky's
  SDK event normalizer already consumes only that field and assembles streamed text
  in the supervisor, so no event adapter migration is required.
- `ModelRegistry.refresh()` and `ModelRuntime.setRuntimeApiKey()` changed option and
  result contracts. Picky uses `ModelRuntime.refresh({ allowNetwork: false })` for
  local credential synchronization and does not call `ModelRegistry.refresh()` or
  `setRuntimeApiKey()`, so the existing public path remains valid.
- Provider refresh publication and OAuth `refreshToken` contracts changed. Picky
  does not register a handwritten provider or OAuth refresh callback; user-loaded
  extensions are composed by Pi's own service factory and inherit the new behavior.
- Pi agent-core replaced its legacy harness session APIs with v4 lane-based APIs.
  Picky does not import agent-core or removed experimental paths, so this remains a
  transitive runtime change.
- `AgentSession.messages`, `AgentSession.setScopedModels`, and
  `ExtensionRunner.emitUserBash` are public typed surfaces in the pinned SDK. Picky
  now uses those declarations directly, removing structural casts while retaining
  runtime guards only for genuinely optional capabilities.
- Synthetic bootstrap messages now use exported `UserMessage` / `AssistantMessage`
  types and assign the typed `AgentState.messages` array without `as never`. The
  private `ModelRuntime.credentials.store.reload` bridge remains the necessary
  credential-related structural cast because Pi exposes no public live reload.
- `pi-ai`, `pi-coding-agent`, and `pi-tui` are pinned together on `0.84.0`.

### 0.84.0 -> 0.84.1

Official source: [Pi coding-agent CHANGELOG 0.84.1](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md#0841---2026-08-07).

- Blocked extension `tool_call` handlers can now terminate an all-terminating batch
  without another model call. Picky's bundled handoff extension registers only a
  slash command, and agentd registers no `tool_call` event hook, so no adapter
  change is required; user-installed extensions inherit the upstream behavior.
- Pi fixes recursive extension TUI method wrappers. Picky supplies its own strict
  `ExtensionUIContext` bridge rather than wrapping the interactive TUI context, so
  this is an upstream robustness improvement with no host code migration.
- `Agent.reset()` now rejects while an inherited agent run is active. Picky drives
  the public `AgentSession` lifecycle and does not call `Agent.reset()`, so session
  orchestration remains unchanged.
- Qwen Token Plan Individual, `pi auth check`, fullscreen selection/scrolling, bash
  environment guidance, and terminal theme detection do not change Picky's SDK
  contracts or native HUD behavior.
- `pi-ai`, `pi-coding-agent`, and `pi-tui` are pinned together on `0.84.1`.

### 0.84.1 -> 0.84.2

Official source: [Pi coding-agent CHANGELOG 0.84.2](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md#0842---2026-08-14).

- `pi.sendUserMessage()` can now explicitly expand commands, skills, and prompt
  templates through `expandPromptTemplates`. Picky's bundled handoff extension
  registers a slash command but does not call `sendUserMessage()`, so no extension
  migration is required.
- `pi.sendMessage(..., { triggerTurn: false })` now records custom messages without
  steering an active run. Picky does not call this extension API; agentd drives
  turns through `AgentSession.prompt()`, so routing behavior remains unchanged.
- Fallback rendering for extension tool results now collapses long output and honors
  expansion. Picky renders tool activity in its native HUD and does not consume the
  interactive TUI fallback renderer, so this is an upstream robustness improvement.
- JSON/RPC `message_update` events now retain cumulative usage while streaming.
  Picky embeds the SDK and derives context usage from `AgentSession.getContextUsage()`
  through its capability wrapper rather than consuming JSON/RPC cumulative usage.
- Configurable default tools preserve extension and SDK custom tools. Picky supplies
  custom tools through `createAgentSessionServices()` and benefits from this fix
  without a host-side contract change.
- Fullscreen search, exit-output settings, theme selection, provider transport fixes,
  and the `nanoid` development dependency security update do not alter Picky's native
  HUD or the SDK surfaces in the T1-T4 coupling map.
- `pi-ai`, `pi-coding-agent`, and `pi-tui` are pinned together on `0.84.2`.

### 0.84.2 -> 0.84.3

Official source: [Pi coding-agent CHANGELOG 0.84.3](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md#0843---2026-08-24).

- Pi renames the inherited `GoogleThinkingLevel` type to
  `GoogleApiThinkingLevel` and adds `ResolvedGoogleThinkingLevel`. Picky imports
  neither type, so no provider adapter migration is required.
- Pi adds `session_compact_failed` extension events. Picky consumes SDK
  `compaction_start` / `compaction_end` events and already maps `willRetry`,
  `aborted`, and `errorMessage` into its compaction lifecycle, so the new
  extension-only notification does not require another normalizer branch.
- Failed extension factories now clean up subscriptions and provider/default
  registrations. User-installed extensions loaded through Picky inherit the fix
  without a host-side change.
- JSON/RPC `toolcall_start` correlation fixes, installer changes, and the bundled
  CLI runtime split do not affect Picky's direct SDK event path or packaged Node
  launcher.

### 0.84.3 -> 0.84.4

Official source: [Pi coding-agent CHANGELOG 0.84.4](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md#0844---2026-08-28).

- Pi adds `ui_prompt_start` and `ui_prompt_end` extension events. Picky's strict
  `ExtensionUIContext` bridge already emits native `extension_ui_request` state
  and marks blocking prompts through `waitsForInput`, so no SDK event adapter
  change is required.
- RPC adds `clear_queue`, while Picky calls the public SDK
  `AgentSession.clearQueue()` and queue snapshot methods directly. The existing
  hard contract test continues to guard those methods.
- Deferred `triggerTurn: false` extension messages now wait for active tool
  results before entering history. Picky does not call `pi.sendMessage()` and
  therefore needs no routing change; user extensions inherit the safer ordering.
- Mid-run large-result compaction now occurs before the next assistant response.
  Picky already keeps queued input isolated across `compaction_start` /
  `compaction_end`, with retry, failure, and queue-drain coverage in
  `pi-sdk-runtime.test.ts`.
- `pi-ai`, `pi-coding-agent`, and `pi-tui` are pinned together on `0.84.4`.

### 0.84.4 -> 0.85.0 (적용 보류)

공식 근거: [Pi 0.85.0 CHANGELOG](https://github.com/earendil-works/pi/blob/v0.85.0/packages/coding-agent/CHANGELOG.md),
[배포 패키지 메타데이터](https://registry.npmjs.org/@earendil-works/pi-coding-agent/0.85.0).

- 전역 CLI는 `0.85.0`이지만 저장소 SDK와는 별개다. `pi-ai`,
  `pi-coding-agent`, `pi-tui`를 함께 `0.85.0`으로 설치한 뒤 필수 계약 검증에서
  실패하여 manifest와 루트 lockfile을 기존 `0.84.4`로 복원했다.
- Node `24.18.1`에서 `import("@earendil-works/pi-coding-agent")`가
  `ERR_MODULE_NOT_FOUND`로 실패한다. 배포된 `dist/experimental/server.js`는
  `@earendil-works/pi-server`와 `/unix`를 import하지만 패키지 dependencies에
  `pi-server`가 없다. 실험 서버를 사용하지 않는 SDK 소비자도 루트 import에서 실패한다.
- `pnpm exec vitest run src/__tests__/pi-contract.test.ts src/application/pi-oauth-service.test.ts`
  결과는 두 파일 모두 수집 실패이며 실행된 테스트는 0개다. 같은 환경에서 `0.84.4`는
  변경 전과 복원 후 모두 12개 테스트와 실제 Node 루트 import가 통과했다.
  `0.85.0`의 typecheck는 통과하므로 타입 검사만으로 이 배포 결함을 잡을 수 없다.
- 저장소 hard-contract 정책에 따라 업데이트를 중단했다. 실험 패키지를 직접 추가하거나
  private import로 우회하지 않는다. 수정 릴리즈에서 위 Node import와 계약 테스트를
  먼저 통과시킨 뒤 전체 검증을 다시 실행한다.

변경 내역의 코드 영향과 개선 검토는 다음과 같다. 아래 upstream 개선은 이번에 적용되지 않았다.

- Claude thinking effort 보존과 signed-thinking 복구, provider 스트림 순서 및 Codex SSE
  종료 이벤트 수정은 `pi-sdk-runtime.ts`와 `pi-event-normalizer.ts`의 입력 품질 개선이다.
  호스트 API 변경 근거는 없으며 실제 SDK 실행 검증이 선행되어야 한다.
- `SessionManager.inMemory()`의 외부 엔트리 복원은
  [공개 API](https://github.com/earendil-works/pi/blob/v0.85.0/packages/coding-agent/src/core/session-manager.ts)다.
  Picky는 `SessionManager.create/open`의 JSONL 파일을 재연결 및 터미널 재개에 사용하므로
  메모리 전용 세션으로 대체하지 않는다. bootstrap 주입의 영속성 계약도 유지한다.
- [fork compaction 경계 수정](https://github.com/earendil-works/pi/pull/8990)은 label 제거 시
  `firstKeptEntryId`를 보존한다. 과거 중단된 tool call을 복구하는
  `repairDanglingToolCalls`와는 다른 계약이므로 복구 코드를 삭제하지 않는다.
- [기본 도구의 `ctx.cwd` 반영](https://github.com/earendil-works/pi/pull/8627)은
  세션별 작업 경로를 따르게 한다. Picky의 `createHandle`은 이미 세션 cwd를 전달하며,
  `pi-extensions/picky-handoff/index.ts`도 `ctx.cwd`를 캡처한다. 제거할 로컬 우회는 없다.
- Bash만 활성화했을 때 skill이 사라지는 문제는 Pi의 resource/tool 경로 수정이다.
  Picky의 `resourceLoader.getSkills()`와 별도 skill 실행 정책을 대체하지 않는다.
- `vllmPriority`, `supportsMaxOutputTokens`, `/client` 호환 진입점 복원, RPC 수동
  compaction abort 수정은 Picky가 직접 사용하는 설정이나 진입점이 아니다.
- 전체 화면 검색·작업 표시·최신 메시지 이동은 Pi TUI 변경이다. native HUD의 표시,
  extension UI 대기 상태, queue 및 취소 어댑터를 대체하지 않는다.
- `ModelRuntime`에 공개 credential reload API가 추가되지 않아
  `reloadModelRuntimeCredentials`를 유지한다. T2 capability fallback 역시 저장소 정책에
  따라 유지한다. 단순화·대체·삭제 적용은 0건이다.

복원 후 검증: `pnpm --dir agentd run typecheck`, `pnpm --dir agentd run test:ci`
(1,249개 통과, 외부 TTS 실서비스 테스트 2개 건너뜀), `pnpm --dir agentd run build`,
빌드된 `dist/runtime/pi-sdk-runtime.js`의 Node import, `git diff --check`가 통과했다.
Xcode 16.3 앱 빌드도 통과했지만 SDK 실행 검증을 대체하지 않는다.
실행 중인 앱을 재시작하지 않았으므로 main-agent 응답, 터미널 재개 버튼, Pickle handoff의
실제 앱 수동 smoke는 미실행이다.

### 0.87.1 -> 0.99.1

공식 근거: [Pi CHANGELOG](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md),
[extension 도구 문맥](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md#tool-exposure).
이 범위의 공식 릴리즈는 `0.99.0`과 `0.99.1`이다. 전역 CLI는 이미 `0.99.1`이며,
저장소의 직접 의존성 `pi-ai`, `pi-coding-agent`, `pi-tui`만 함께 올린다.
`agentd/vendor/async-task-providers`의 선택적 `*` peer 정책은 변경하지 않는다.

- `AgentSession.prompt()`의 `preflightResult`는 boolean 대신
  `PromptDisposition` (`started`, `queued`, `handled`)을 받는다. 거절된 입력에는
  호출되지 않는다. `promptUntilAccepted`는 새 결과를 접수 로그에 기록하고,
  거절 정리는 기존 promise rejection 경로에서 수행한다. 기존 시작·큐·무응답
  slash-command 회귀 테스트의 대역도 공개 `PromptOptions` 계약을 따른다.
- 도구 실행 문맥은 `ExtensionToolContext`이며 `tools`, `executeTool()`을 포함한다.
  실제 subagent 도구를 직접 실행하는 통합 테스트는 공개
  `ExtensionRunner.createToolContext()`를 사용한다. 과거 `0.85.0` 비교 하네스는
  기존 `createContext()` 경로를 유지한다.
- MCP, codemode, tool search가 CLI의 built-in extension으로 추가된다. Pi CLI는
  factory를 주입하지만 Picky의 `createAgentSessionServices`는 이를 주입하지 않는다.
  따라서 SDK bump만으로 `mcp.json` 로드나 새 MCP 서버 실행이 활성화되지 않는다.
  기존 curated MCP plugin을 자동 삭제하거나 새 설정으로 이관하지 않는다.
- 사용자 확장이 `ctx.executeTool()`을 쓰면 `parentToolCallId`가 있는 중첩 도구
  이벤트를 보낼 수 있다. 기존 normalizer는 도구별 ID로 모두 활동을 표시한다.
  부모·자식 그룹 표시나 집계 정책 변경은 이번 업데이트에 포함하지 않는다.
- 카탈로그 요청에 `types=chat,image,classifier` 쿼리가 추가된다. 테스트 HTTP 서버는
  `request.url` 전체 대신 URL pathname으로 provider 경로를 판별한다. 변경 전
  원격 모델 선택·목록·캐시 테스트 4개가 404로 실패했고, 수정 후 해당 8개가 통과했다.
  production catalog refresh adapter는 변경하지 않는다.
- virtual models, classifier, image generation이 `ModelRuntime`에 추가되지만 Picky의
  모델 선택은 기존 chat accessor 계약을 유지한다. GPT-6.1 Sol 카탈로그와 Codex 기본
  모델 변경, 기존 OAuth 및 RPC listener 수정은 upstream에서 상속한다. 새 `openai`
  ChatGPT 로그인은 Picky의 OAuth provider 목록에 추가하지 않는다. 기존
  `openai-codex` / `anthropic` 로그인 계약은 유지한다. TUI system theme은
  native SwiftUI HUD를 대체하지 않는다.
- 새 세션 파일을 첫 사용자 메시지에서 만드는 수정은 세션 파일 발견 경로의 개선이다.
  bootstrap 영속성, 재연결, `bindCurrentSession` 구독 경쟁 방어를 제거할 근거는 아니다.
- 공개 credential reload API는 여전히 없어 `reloadModelRuntimeCredentials`를 유지한다.
  T2 soft fallback과 `repairDanglingToolCalls` 역시 다른 계약을 보호하므로 유지한다.
  별도 선택적 단순화·대체·삭제는 적용하지 않는다.
- `createLocalShellOperations`는 여전히 cwd 접근 검사 후 abort 재검사 없이 spawn한다.
  취소 이후 외부 프로세스를 시작하지 않는 기존 패치를
  `patches/pi-coding-agent@0.99.1.patch`로 옮긴다. spawn-fence 회귀 테스트가
  취소 직후 spawn 0회와 정상 실행·실행 중 취소·timeout 보존을 검증한다.
  격리 SDK 사본에서 패치만 되돌린 비교 실행은 취소 후 spawn 1회를 재현했다.
- lockfile의 새 `pi-mcp`, `pi-codemode`, `quickjs-wasi`와 OpenAI SDK 갱신은 Pi의
  전이 의존성 변경이다. 기존 `ws@8.20.0`은 새 OpenAI SDK의 선택적
  `ws@^8.21.0` peer 경고를 남긴다. 이 업데이트는 범위 밖 직접 의존성을 올리지 않는다.

패키지 smoke의 기존 경로는 owned provider를 일반 extension 필터에 넘겨 도구를
모두 제거하고 있었다. `scripts/test-async-provider-package.mjs`는 production의
owned loader와 같이 검증된 절대 경로를 `additionalExtensionPaths`에 직접 전달한다.
확장 로딩 오류도 빈 배열임을 검사해 도구 누락 원인이 숨지 않도록 한다.
SDK 변경 때문에 production 필터를 제거하거나 provider bus 격리를 약화하지 않는다.

검증 결과:

- 필수 SDK/OAuth 계약 16개 통과, 변경된 runtime와 spawn-fence 집중 검증 114개 통과
  (기존 선택적 테스트 1개 건너뜀).
- 전체 `test:ci` 첫 단계는 카탈로그 테스트 4개 실패와 1,132개 통과였다. HTTP fixture를
  수정한 뒤 해당 파일 8개를 재검증했고 모두 통과했다. 나머지 server/supervisor 단계는
  446개 통과했다. 전체 범위의 고유 테스트는 1,582개 통과, 기존 선택적 테스트 6개
  건너뜀이며, 첫 단계에서 실제 packed bash/subagent admission 테스트 26개도 실행됐다.
- `pnpm --dir agentd run typecheck`, `pnpm --dir agentd run build`, 변경 TypeScript 파일
  ESLint, `pnpm run check:architecture` (기존 경고 4개), `git diff --check` 통과.
- `node scripts/test-async-provider-package.mjs`가 standalone 의존성, 확장 도구 로드,
  provider 파일 변조 차단을 검증했다. Xcode 16.3과 공유 `PickyAgentDD` 앱 빌드 통과.
- 외부 extension checkout을 요구하는 과거 `0.85.0` 비교 하네스는 이번에 실행하지 않았다.

실행 중인 앱을 재시작하는 수동 smoke는 별도 명시 허가 없이는 수행하지 않는다.
격리 SDK/provider 통합 테스트와 standalone package smoke는 실제 앱 수동 검증과 구분한다.

### 0.99.1 -> 1.0.0

공식 근거: [Pi CHANGELOG](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md),
[Pi 1.0 발표](https://earendil.com/posts/pi-1-0/). 이 범위의 릴리즈는 `0.99.2`와 `1.0.0`이다.
발표의 codemode, virtual models, deferred tool loading, cache warming, mid-conversation
system messages는 `0.86`~`0.99.0`에서 이미 들어왔다. 세션 파일 버전은 3으로 같다.
`pi-ai`, `pi-coding-agent`, `pi-tui`만 함께 올린다.

- 제거·변경된 공개 API(`getCodemodeWorkerUrl`, `createToolSearchDescription`,
  `MODEL_GLOBAL_DECLARATIONS`, `McpExposure`의 `codemode-deferred`)는 Picky가 쓰지 않는다.
  `picky-mcp.ts`가 dist에서 읽는 MCP config 함수와 `runMcpCommand` 경로는 그대로다.
- `mcp-auth.json` 키가 URL에서 `mcp__<server>|<url>`로 바뀌고, 1.0 기본 저장소는 첫 로드 때
  URL 키를 옮긴 뒤 지운다. Picky는 사용자 Pi CLI와 agent directory를 공유하므로 기본 저장소를
  쓰면 1.0 미만 CLI가 Picky가 건드린 OAuth 서버에서 모두 로그아웃된다.
  `picky-mcp-credentials.ts`가 세션 MCP 확장과 Hub의 `runMcpCommand`에 호환 저장소를 넘긴다.
  읽은 entry에 다시 쓰고(서버별 entry > URL entry 순), URL entry를 옮기거나 지우지 않으며,
  첫 로그인은 URL entry에 쓴다. 1.0이 이미 서버별 entry를 만든 URL은 서버별 entry를 따르고,
  같은 URL을 쓰는 다른 서버만 서버별 entry를 가진 경우에도 읽은 URL entry에 다시 쓴다. 로그아웃은 두 entry를 모두
  지운다. refresh는 두 버전의 잠금 파일(URL 키, 서버별 키 순서)을 모두 잡는다.
  `picky-mcp-credentials.test.ts`는 1.0 기본 저장소로 8개 실패(RED)를 재현한 뒤 통과한다.
  agent directory 격리가 들어가면 이 저장소를 제거한다.
- 호환 저장소의 알려진 한계: mcp.json에서 지운 서버의 서버별 키가 `mcp-auth.json`에 남으면,
  같은 URL을 쓰는 다른 서버의 첫 로그인이 서버별 키로 가서 1.0 미만 CLI가 보지 못한다.
  내장 `mcp` 확장을 대체하는 사용자 확장(`replaceable: true`)이나 `-builtin:mcp`는 이 저장소를 우회한다.
  refresh는 URL 잠금을 쥔 채 서버별 잠금을 기다리므로, 드문 3자 중첩에서는 구버전 CLI의 refresh가
  ELOCKED로 실패할 수 있다.
- `auth.provider`, `oauth.clientName`, `oauth.authServerMetadataUrl`, 서버 `description`은
  1.0 SDK가 직접 처리한다. `-`와 `_`만 다른 서버 이름은 CLI와 같이 거부된다.
- MCP 도구·namespace 이름의 `-`가 `_`로 바뀐다(`mcp__my-server__x` → `mcp__my_server__x`).
  Swift 활동 칩과 도구 설명은 이름을 표시만 하고 설정 이름과 비교하지 않으므로 수정하지 않는다.
- 변경된 `mcp_servers` system prompt 섹션은 대화 중간 system 메시지로 붙는다.
  `pi-session-syncer`는 user/assistant만 동기화하고, `AsyncTaskModelFence`는 `custom`만 거른다.
- codemode MCP 서버는 첫 프롬프트를 막지 않고 백그라운드로 연결된다. 긴 세션에서 프롬프트 제출이
  느려지던 문제(#10198)와 재개 시 deferred MCP 도구가 빠지던 문제는 upstream에서 상속한다.
- `createLocalShellOperations`는 1.0에서도 cwd 검사 뒤 abort를 다시 확인하지 않는다.
  기존 패치를 `patches/pi-coding-agent@1.0.0.patch`로 옮긴다.
- async task 특성 테스트의 SDK 버전 가드(`fixtures/async-task-host.mjs`,
  `async-task-sdk-spawn-fence.test.ts`, `async-task-provider-admission.integration.test.ts`)를
  `1.0.0`으로 바꾼다. 가드만 바꾸고 기대 동작은 그대로 둔 채 실제 1.0 SDK에서 재실행한다.
- 기본 TUI가 fullscreen으로 바뀌지만 SDK 세션에는 영향이 없다. 앱의 Pi 터미널 오버레이는
  PATH의 `pi`를 실행하므로 사용자 CLI 버전을 따른다.
- lockfile의 `ws@^8.21.0` peer 경고는 0.99.1과 같다.

검증 결과:

- 필수 SDK/OAuth/MCP 계약 20개 통과. 새 `picky-mcp-credentials.test.ts` 10개 통과.
- `PICKY_TEST_ASYNC_PROVIDER_ROOT=agentd/vendor/async-task-providers`로 전체 `test:ci` 실행:
  첫 단계 1,172개 통과(선택적 6개 건너뜀), server/supervisor 단계 447개 통과.
- `typecheck`, `lint`, `build`, `pnpm run check:architecture`(기존 경고 4개),
  `node scripts/test-async-provider-package.mjs` 통과.
- Xcode 앱 빌드와 실행 중인 앱의 수동 smoke는 실행하지 않았다. Swift 코드는 바뀌지 않았다.

### 1.0.0 -> 1.0.4

공식 근거: [Pi CHANGELOG](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md).
이 범위의 릴리즈는 `1.0.1`~`1.0.4`다. `pi-ai`, `pi-coding-agent`, `pi-tui`만 함께 올린다.

- `1.0.3`에서 Azure provider가 `azure-openai-responses`에서 `azure`로 바뀐다. Picky 코드는 이
  이름을 쓰지 않는다. fast mode 정책은 OpenAI·Anthropic 허용 목록만 보므로 두 이름 모두 제외된다.
  `fast-mode-policy.test.ts`의 제외 예시만 `azure`로 바꾼다. 사용자 `auth.json`·`settings.json`의
  provider 키 이전은 사용자 Pi 설정 몫이고, 옛 이름으로 저장된 세션은 재개 때 다른 모델로 넘어간다.
- `1.0.1`의 `pi.registerToolRenderer()`, MCP 프로젝트 override, `oauth.clientRegistration: "cimd"`,
  `1.0.2`의 `samplingParamsByThinkingLevel`, `1.0.4`의 `--tools` 패턴·`--no-mcp`는 CLI·TUI·설정
  기능이라 Picky가 따로 대응하지 않는다. `ToolLoadout.getPromptGuidelines()` 추가는 Picky가
  `prepareLoadout`을 쓰지 않아 영향이 없다.
- MCP 종료가 연결 중인 서버를 기다리도록 고쳐졌다(#10249). `picky-mcp.ts`가 dist에서 읽는
  `extensions/mcp/config.js`, `core/mcp-servers.js`, `extensions/mcp/cli.js`, `core/auth-storage.js`
  경로는 그대로다.
- `createLocalShellOperations`는 1.0.4에서도 cwd 검사 뒤 abort를 다시 확인하지 않는다.
  기존 패치를 `patches/pi-coding-agent@1.0.4.patch`로 옮긴다.
- async task 특성 테스트의 SDK 버전 가드를 `1.0.4`로 바꾼다. 기대 동작은 그대로다.
- `1.0.1`에서 published package의 `npm-shrinkwrap.json`이 빠졌다. Picky는 pnpm lockfile로
  transitive 버전을 고정하므로 영향이 없다. lockfile 변화는 Pi 계열 패키지와
  `@anthropic-ai/sdk` 0.124.0 → 0.129.0이다.

### 1.0.4 -> 1.1.0

공식 근거: [Pi CHANGELOG](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md).
`pi-ai`, `pi-coding-agent`, `pi-tui`만 함께 올린다. 세션 파일 버전과 제거·이름 변경된 공개 API는 없다.

- `agent_settled`에 `aborted`, `tool_execution_end`와 tool render context에 `durationMs`가 추가됐다.
  둘 다 추가 필드라 `pi-event-normalizer.ts`, `async-task-model-fence.ts`,
  `pi-sdk-runtime-session.ts`는 그대로 둔다. Picky가 취소된 run을 구분하거나 도구 실행 시간을
  보여 주려면 이 필드를 쓸 수 있지만 이번 bump 범위에서는 적용하지 않는다.
- `--tools`의 `+name`/`-name`, OSC 7501 program status, `outputPad`, Claude Haiku 5.5,
  GPT-6 Luna·llama.cpp classifier는 CLI·TUI·모델 카탈로그 기능이라 따로 대응하지 않는다.
- MCP OAuth sign-in 취소·타임아웃과 종료 시 refresh 대기 제거(#10565)는 upstream에서 상속한다.
  `picky-mcp.ts`가 dist에서 읽는 `extensions/mcp/config.js`, `core/mcp-servers.js`,
  `extensions/mcp/cli.js`, `core/auth-storage.js` 경로는 그대로다.
- `createLocalShellOperations`는 1.1.0에서도 cwd 검사 뒤 abort를 다시 확인하지 않는다.
  기존 패치를 `patches/pi-coding-agent@1.1.0.patch`로 옮긴다.
- async task 특성 테스트의 SDK 버전 가드를 `1.1.0`으로 바꾼다. 기대 동작은 그대로다.
- lockfile 변화는 Pi 계열 패키지(`chord`, `pi-agent-core`, `pi-codemode`, `pi-mcp`,
  `pi-telemetry` 포함)뿐이다.

## Backward-compatibility policy

- **Capability sniffs (T2) MUST stay non-fatal.** A pi version that drops
  an optional method should land in Picky as a graceful fallback (log
  once, run the user-visible no-op path) so the host keeps shipping while
  upstream stabilises.
- **Contract test (C) leaves the soft tier as a `console.warn`** so a
  reshuffled pi build does not block CI; the warning is loud enough to
  surface in the bump PR review.
- **Hard contract failures are stop-the-line.** Pin the previous pi
  version in `agentd/package.json` until the host catches up.
- **Internal shapes (T3) and lifecycle (T4) are NOT guarded**. They rely
  on code review during a pi bump; this doc enumerates them so the
  reviewer knows where to look.

## TODO: hardening backlog

- **T3 typed repair helper for `session.state.messages`**: bootstrap injection is
  now checked against Pi's exported message types, but `repairDanglingToolCalls`
  still validates unknown historical/custom message shapes defensively before
  mutating the array. A public Pi transcript-repair helper would remove that last
  internal-shape dependency.
- **T4 race elimination**: the `setTimeout(0) -> reportDiagnostics ->
  "pi session: <path>" -> piSessionFilePathFromLogLine` chain that
  triggered the 0.74 regression is still inherently racy. The supervisor
  now attaches the subscriber before any awaited file I/O, but a future
  pi that pushes session-file discovery into an async path will re-open
  the window. A `runtime.session.ready` promise (or an explicit
  `onSessionFile` callback) on pi's side would close it.
- **Golden fixtures for `pi-event-normalizer.ts`**: capture real pi
  `subscribe()` payloads across a representative session and snapshot
  them. A pi version that renames an event field would diff the snapshot
  instead of producing silent `kind: "none"` returns.
