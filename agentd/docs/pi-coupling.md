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
| **T1 — Public API** | `defineTool`, `loadSkills`, `createAgentSessionServices`, `ModelRuntime` provider auth/status/login, `SettingsManager`, `DefaultPackageManager`, `AgentSession.prompt`, `AgentSession.subscribe`, `AgentSession.bindExtensions`, `AgentSession.messages`, `AgentSession.setScopedModels` | Daemon cannot boot or pi cannot answer at all | `src/__tests__/pi-contract.test.ts` (hard fail), TypeScript types |
| **T2 — Capability sniffs** | `setThinkingLevel`, `cycleThinkingLevel`, `cycleModel`, `getContextUsage`, `compact`, `reload`, `executeBash`, `recordBashResult`, `isCompacting`, `extensionRunner.emitUserBash` | One pi runtime feature silently no-ops (e.g. `/compact` becomes "not supported", thinking level cycling does nothing) | `src/runtime/pi-capabilities.ts` wraps each sniff, logs `pi capability absent` per session; `pi-contract.test.ts` warns (not fails) on absence so back-compat builds keep passing |
| **T3 — Internal shapes** | `session.state.messages` array layout, `ModelRuntime.credentials.store.reload` compatibility bridge, `assistantMessage.content[]` blocks (`{type:"text"}` / `{type:"toolCall"}` / `{type:"toolResult"}`), `session.model.{api,provider,id}` with `state.model` fallback, pi `subscribe()` event types (`agent_start`, `message_update`, `turn_end`, `agent_end`, ...) and field names (`stopReason`, `toolCallId`, `toolName`) | Subtle, hard-to-detect regressions (lost session file path, stale live credentials, dropped status events, malformed bootstrap, stale tool-call repair) | Centralised in `pi-event-normalizer.ts` + `pi-capabilities.ts`; credential reload and state shape are hard-gated in `pi-contract.test.ts` |
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

`handoff-tool.ts`, `ask-user-question-tool.ts`, `user-guide-tool.ts`,
`open-pickle-response-tool.ts`. All use `defineTool` + `ToolDefinition`
from pi (T1). Low risk; pi rarely changes tool schema. Track here so the
audit-on-bump checklist covers them.

### Skill catalog: `agentd/src/application/skill-catalog.ts`

Uses `loadSkills`, `SettingsManager`, `DefaultPackageManager`,
`getAgentDir` (T1). Stable since pi 0.7x.

## Per-bump upgrade checklist

When bumping pi (`agentd/package.json` `@earendil-works/pi-coding-agent`):

1. **Run the contract tests first**: `cd agentd && pnpm exec vitest run src/__tests__/pi-contract.test.ts src/application/pi-oauth-service.test.ts`.
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
