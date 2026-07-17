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
| **T1 — Public API** | `defineTool`, `loadSkills`, `createAgentSessionServices`, `SettingsManager`, `DefaultPackageManager`, `AgentSession.prompt`, `AgentSession.subscribe`, `AgentSession.bindExtensions` | Daemon cannot boot or pi cannot answer at all | `src/__tests__/pi-contract.test.ts` (hard fail), TypeScript types |
| **T2 — Capability sniffs** | `setThinkingLevel`, `cycleThinkingLevel`, `cycleModel`, `getContextUsage`, `compact`, `reload`, `executeBash`, `recordBashResult`, `isCompacting`, `extensionRunner.emitUserBash` | One pi runtime feature silently no-ops (e.g. `/compact` becomes "not supported", thinking level cycling does nothing) | `src/runtime/pi-capabilities.ts` wraps each sniff, logs `pi capability absent` per session; `pi-contract.test.ts` warns (not fails) on absence so back-compat builds keep passing |
| **T3 — Internal shapes** | `session.state.messages` array layout, `assistantMessage.content[]` blocks (`{type:"text"}` / `{type:"toolCall"}` / `{type:"toolResult"}`), `session.model.{api,provider,id}` with `state.model` fallback, pi `subscribe()` event types (`agent_start`, `message_update`, `turn_end`, `agent_end`, ...) and field names (`stopReason`, `toolCallId`, `toolName`) | Subtle, hard-to-detect regressions (lost session file path, dropped status events, malformed bootstrap, stale tool-call repair) | Centralised in `pi-event-normalizer.ts` + `pi-capabilities.ts.readModelMetadata`/`readThinkingLevel`; no compile-time gate yet (TODO — track in a "T3 hardening" issue) |
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
- `this.runtime.session.state.messages` (T3 — direct mutation in
  `injectInitialBootstrap` and `repairDanglingToolCalls`)
- `this.runtime.session.sessionManager.appendMessage` (T3)
- `this.runtime.setRebindSession(...)` (T4)
- `this.runtime.session` subscribe/unsubscribe race guard (T4) — see the
  `bindCurrentSession()` reentry comment for the long-form explanation.

### Capability wrappers: `agentd/src/runtime/pi-capabilities.ts`

Single chokepoint for every `as unknown as { foo?: ... }` cast against
`AgentSession`. Each wrapper:

1. Performs the unsafe cast in exactly one place.
2. Returns `undefined` / a discriminated `{ supported: false }` when the
   underlying pi method is missing.
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

1. **Run the contract test first**: `cd agentd && pnpm exec vitest run src/__tests__/pi-contract.test.ts`.
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

- **T3 compile-time gate for `session.state.messages` shape**: today the
  `injectInitialBootstrap` and `repairDanglingToolCalls` paths mutate the
  message array via `as never` casts. A pi reshape of the message record
  would compile cleanly and break at runtime. Either expose a typed pi
  helper (`pi.appendBootstrapPair(...)`, `pi.repairTranscript(...)`) or
  ship a Picky-side typed adapter that builds the messages via pi's own
  type exports.
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
