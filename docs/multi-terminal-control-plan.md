# Pickle Multi-Terminal Control Plan

_Status: proposed; product decision and technical review complete, implementation not started_

_Last updated: 2026-08-19_

## Summary

The Pickle utility panel already contains only `Terminal | Artifacts`; the former Activity/Progress tab has been removed. This plan preserves that two-tab structure and turns the Terminal tab into a per-Pickle terminal workspace that can:

- create, select, rename, and close multiple local shell terminals;
- keep terminal processes alive while the utility panel is hidden or the Artifacts tab is selected;
- allow the owning Pickle agent to create, inspect, write to, and close explicitly shared terminals;
- prevent user and agent input from being merged into the same shell line;
- degrade safely across archive, child-daemon exit, WebSocket disconnect, duplicate requests, and mixed app/daemon capability versions.

The recommended architecture keeps PTY ownership in Picky.app through SwiftTerm. The owning child `picky-agentd` receives a Pickle-only `picky_terminal` tool and uses a bounded request/response bridge to ask the app to operate on that Pickle's terminal workspace.

The core invariant is:

> Picky owns terminal processes and visible control state; the owning Pickle may operate only on terminals for which the user has granted capability, under an exclusive mutation lease.

## Confirmed decisions

- Keep the utility panel at two top-level tabs: `Terminal | Artifacts`.
- Do not reintroduce Activity, Progress, Changes, or raw tool-history tabs.
- Keep PTYs in Picky.app using the pinned SwiftTerm dependency for v1.
- Support multiple terminals within one Pickle; do not add split panes in v1.
- A terminal created by the Pickle is shared with that Pickle by default.
- A terminal created by the user is private by default.
- A user-created terminal becomes agent-readable and agent-controllable only after explicit per-terminal opt-in.
- Mutating control is exclusive: user and Pickle writes must never be accepted concurrently.
- Hiding the panel preserves terminals; archiving the Pickle revokes the workspace and closes all terminals.
- Do not persist or restore PTY processes across Picky.app restart in v1.
- Do not add `node-pty`, `@xterm/headless`, generic `ctx.ui.custom`, or `interactive_shell` background/dispatch modes in v1.

## Design Decision Card

- **User goal:** manage several local shells inside one Pickle and let that Pickle operate the shells when explicitly allowed.
- **Target surface:** the existing Terminal utility tab below a Pickle conversation card.
- **First-glance information:** selected terminal, process status, terminal count, control permission, and active controller.
- **Primary actions:** select terminal, create terminal, type into terminal.
- **Secondary actions:** rename, grant/revoke Pickle control, hand mutation control to the Pickle, close terminal.
- **Required states:** empty, starting, running, exited, failed, private, shared, user-controlled, Pickle-controlled, disconnected, closing, limit reached.
- **Token plan:** reuse utility-panel tabs, `DS` colors/spacing/radii, `PickyHUDTypography`, SF Symbols, and existing terminal surface styling. Add no new foundation token unless implementation proves a missing semantic role.
- **Native behavior:** preserve macOS keyboard focus, terminal selection/copy/paste, drag-and-drop paths, IME handling, contextual menus, tooltips, and VoiceOver labels.
- **Performance constraint:** inactive terminals keep their PTY and buffer but must not add SwiftUI row tasks or repeatedly remount their `NSView`.
- **Security boundary:** private user terminals expose neither output nor mutation capability to the Pickle.
- **Explicit non-persistence:** terminal processes are app-lifetime resources, not durable Pickle session state.

## Current state

### Utility panel

`Picky/HUD/PickyHUDUtilityPanel.swift` currently declares only:

```swift
enum PickyHUDUtilityPanelTab {
    case terminal
    case artifacts
}
```

`PickyTests/PickyHUDUtilityPanelPolicyTests.swift` asserts that `activity`, `progress`, and `changes` are invalid persisted tab values. No Activity-tab removal work remains; implementation must preserve this contract.

### Single local shell per Pickle

`PickySessionViewModel.swift` stores one local shell session per Pickle:

```swift
private var shellTerminalSessionsBySessionID: [String: PickyShellTerminalSession] = [:]
```

`PickySessionExtendedTerminalView` calls `viewModel.shellTerminalSession(for:)`, which creates or returns that singleton. The shell process starts when the SwiftTerm `NSViewRepresentable` attaches, so a hidden agent-created terminal could not start independently under the current lifecycle.

### App-owned PTY

`PickyShellTerminalModel.startProcessIfNeeded` calls SwiftTerm's `LocalProcessTerminalView.startProcess`. `PickySwiftTermView` already subclasses `LocalProcessTerminalView` and can use the pinned SwiftTerm APIs needed by this plan:

- `open func dataReceived(slice:)` for output revision observation;
- `send(txt:)` / `send(_:)` / process input for agent writes;
- terminal buffer line/data access for rendered tail reads;
- `terminate()` and process delegate callbacks for closure and exit state.

### Missing agent control channel

The app-agentd protocol currently supports Pi transcript tail/sync commands, not local-shell PTY control. The existing reverse request pattern is `pickleBridgeRequested` → `completePickleBridgeRequest`, with app capability registration, request IDs, timeout handling, and disconnect cleanup. Terminal control should use the same transport pattern but a separate typed payload and state owner.

### `interactive_shell` relationship

The installed `interactive_shell` extension uses `node-pty`, `@xterm/headless`, a session registry, ordered writes, key encoding, bounded output reads, and background/attach modes. Picky's `ExtensionUiBridge` explicitly rejects generic `ctx.ui.custom` overlays, and Picky's packaged agentd does not ship `node-pty` or its macOS `spawn-helper`.

This plan borrows its bounded tool contract, named-key semantics, ordered mutations, and structured status errors. It does not depend on the user's installed extension or copy its PTY backend.

## Goals

1. Support multiple independent shell processes per Pickle.
2. Keep one clear selected terminal per Pickle workspace.
3. Start a Pickle-created terminal even when the utility panel is hidden.
4. Keep terminal process ownership independent from SwiftUI mount/unmount.
5. Give the owning Pickle an explicit, scoped, observable terminal tool.
6. Keep user-created terminals private until the user opts in.
7. Prevent user/agent input collisions with an exclusive mutation lease.
8. Make create/write/close safe against stale generation, duplicate request, archive, and disconnect races.
9. Keep reads bounded and distinguish rendered snapshots from raw incremental streams.
10. Preserve local-first behavior and avoid a new native Node dependency.

## Non-goals

- No Activity/Progress tab redesign.
- No split panes, draggable pane layouts, or tmux-style layouts.
- No durable PTY restoration after app restart.
- No remote terminal access or network listener.
- No generic Pi TUI overlay implementation.
- No `interactive`, `hands-free`, `dispatch`, attach/detach, or completion notification modes from `interactive_shell`.
- No raw hex input in the initial Pickle tool.
- No arbitrary cross-Pickle session ID parameter in the tool.
- No automatic tab switch or panel opening when the Pickle creates a terminal.
- No shell command policy in Picky; Pi remains responsible for deciding what to run.

## Core invariants

### Ownership

- `PickyTerminalWorkspaceController` is the single mutable owner of app-side workspace state and terminal process adapters.
- `PickySessionViewModel` stores or delegates to workspaces but does not duplicate selection, permission, or lease rules.
- Views project state and send user intents; they do not mutate terminal dictionaries directly.
- The router translates protocol requests and scopes them to a child connection; it does not own terminal lifecycle.

### Scope

- Every workspace belongs to one Pickle `sessionID`.
- The `picky_terminal` tool is registered only for child-daemon Pickle runtimes in v1.
- The tool does not accept a Pickle session ID.
- Every reverse RPC includes the child-configured `sessionID` for defense in depth.
- `PickyAgentClientRouter` verifies that the event's session ID matches the child connection key before invoking the workspace controller.
- A primary-daemon terminal request is rejected until a separately designed main-agent terminal feature exists.

### Capability

- Private terminals are omitted from normal tool listings; the tool may return only a `privateTerminalCount`.
- Shared terminals expose bounded metadata and rendered output to their owning Pickle.
- Revoking permission immediately blocks future reads and mutations and invalidates queued mutations.

### Mutation safety

- User and Pickle mutations are mutually exclusive.
- Every mutating request targets an explicit terminal ID and carries workspace generation and lease epoch.
- Terminal IDs are monotonic within a workspace generation and are never reused.
- Archive/revoke increments workspace generation before closing processes.
- Late requests and late completions are idempotent no-ops or structured stale errors.

## Recommended architecture

```text
Pickle Pi runtime
  └─ picky_terminal tool
       └─ child AgentdServer.requestTerminalControlFromApp(...)
            └─ terminalControlRequested(requestId, sessionId, operation)
                 └─ PickyAgentClientRouter verifies child ownership
                      └─ PickyTerminalWorkspaceController
                           ├─ pure workspace policy
                           ├─ PickyShellTerminalSession instances
                           └─ SwiftTerm LocalProcessTerminalView PTYs
                 └─ completeTerminalControlRequest(requestId, result/error)
       └─ bounded tool result
```

### Why app-owned PTY is the v1 choice

- Reuses the current terminal renderer, font, IME, drag/drop, keyboard, and AppKit focus behavior.
- Avoids shipping and signing a new native Node addon and macOS helper executable.
- Avoids continuously streaming terminal bytes over JSON WebSocket messages.
- Allows rendered tail reads directly from SwiftTerm's canonical screen/scrollback state.
- Fits the current lifecycle: agentd is already an app child process, so moving the PTY does not provide app-independent persistence.

### When to reconsider agentd-owned PTYs

Revisit `node-pty` only if a later requirement needs one or more of:

- terminal survival while Picky.app is not running;
- reconnectable screen restoration after an app crash;
- headless dispatch completion and quiet-time notifications;
- continuous raw terminal streaming to multiple clients;
- a single terminal backend shared by native UI and non-Picky clients.

That redesign would require native-addon packaging/signing, flow control, resize propagation, remote rendering, output replay/snapshot, reconnect authority, and process-tree lifecycle work. It is not a prerequisite for this feature.

## App-side domain model

Exact names may be adjusted during implementation, but the responsibilities must remain separate.

```swift
struct PickyTerminalWorkspaceState: Equatable {
    let sessionID: String
    var generation: UInt64
    var orderedTerminalIDs: [String]
    var selectedTerminalID: String?
    var nextTerminalOrdinal: Int
    var isRevoked: Bool
}

struct PickyTerminalInstanceState: Equatable, Identifiable {
    enum Origin: Equatable { case user, pickle }
    enum Permission: Equatable { case privateToUser, sharedWithPickle }
    enum Controller: Equatable { case user, pickle }
    enum ProcessStatus: Equatable { case starting, running, exited(Int32?), failed(String), closing }

    let id: String
    var name: String
    let origin: Origin
    var permission: Permission
    var controller: Controller
    var leaseEpoch: UInt64
    var outputRevision: UInt64
    var processStatus: ProcessStatus
    var cwd: String
}
```

`PickyTerminalWorkspaceController` owns:

- `[sessionID: Workspace]`;
- a monotonic generation tombstone per session ID, retained after workspace removal;
- terminal process adapters keyed by `(sessionID, terminalID)`;
- resource-limit accounting;
- mutation chains and idempotency results;
- archive/revoke and child-lifecycle transitions;
- request handling on `@MainActor`.

A pure `PickyTerminalWorkspacePolicy` decides:

- insertion order and selected-terminal fallback;
- monotonic terminal IDs such as `term-1`, `term-2`;
- permission transitions;
- controller/lease transitions;
- stale generation and stale lease rejection;
- resource-limit errors;
- workspace revoke effects.

Process spawning, SwiftTerm reads/writes, WebSocket replies, and timers remain adapters/effects outside the pure policy.

## Process and view lifecycle

### Creation

User creation:

- lazily create the first user terminal when the user opens an empty Terminal workspace or presses `+`;
- set `origin = user`, `permission = privateToUser`, `controller = user`;
- start the PTY immediately after workspace insertion.

Pickle creation:

- create even if the utility panel is closed or Artifacts is selected;
- set `origin = pickle`, `permission = sharedWithPickle`, `controller = pickle`;
- start the PTY before returning success to the tool;
- do not auto-open the utility panel or steal keyboard focus.

### Decouple start from mount

Refactor `PickyShellTerminalModel` so process startup is an explicit operation, not a side effect of `NSViewRepresentable.makeNSView`.

- `PickyShellTerminalSession.start()` prepares deterministic initial terminal geometry and starts the process once.
- `attach()` only mounts/configures the existing SwiftTerm view and updates terminal size.
- hidden terminals have a valid initial row/column size before spawn.
- repeated view mounts never start another process.

### Selection and attachment

- One selected terminal ID is shared across every projection of a Pickle workspace.
- Preserve the existing invariant that one SwiftTerm `NSView` cannot attach to multiple parents.
- Generalize attachment identity from Pickle session only to `(sessionID, terminalID, attachmentID)`.
- Switching tabs detaches the old selected terminal view and attaches the new selected terminal without restarting either process.
- Inactive terminal processes and buffers remain alive.

### Closure

- User closure is always allowed and invalidates pending Pickle mutations before terminating the PTY.
- Pickle closure requires shared permission, Pickle controller lease, matching generation, and matching lease epoch.
- Closing the selected terminal selects the nearest remaining terminal deterministically.
- Closing the last terminal shows an empty state; it does not immediately create a replacement.
- Process exit keeps a lightweight exited tab until the user closes it, allowing output inspection.

### Archive and deletion

Archive is an atomic revoke boundary:

1. mark workspace revoked and increment generation;
2. cancel/fail pending terminal RPCs;
3. invalidate every Pickle lease;
4. close all terminal processes;
5. retain the incremented generation as a tombstone, then remove the workspace after process teardown has been scheduled;
6. continue the existing archive flow.

Unarchive starts with no terminals and allocates a generation strictly newer than the retained tombstone. A late child request from the pre-archive generation cannot recreate a hidden workspace or collide with a newly unarchived workspace.

### Child-daemon lifecycle

- Transient WebSocket disconnect: keep terminal processes, fail in-flight RPCs, revoke active Pickle mutation leases, and show control unavailable.
- Child process exit/crash: keep terminals available to the user, downgrade shared terminals to user controller, and require explicit hand-back after a replacement child connects.
- Explicit child release after archive/delete: workspace is already revoked and closes normally.
- App termination: existing app lifecycle terminates app-owned PTYs; no durable restoration is attempted.

## Permission and controller model

Permission answers whether the Pickle may observe or operate the terminal. Controller answers who may currently mutate it.

| Origin | Default permission | Default controller | Pickle read | Pickle write/close |
| --- | --- | --- | --- | --- |
| User | Private | User | No | No |
| Pickle | Shared | Pickle | Yes | Yes |
| User after opt-in | Shared | User | Yes | No until hand-back |
| Shared after user takeover | Shared | User | Yes | No until hand-back |
| Shared after explicit hand-back | Shared | Pickle | Yes | Yes |

### User takeover

- Clicking/focusing a Pickle-controlled terminal presents a clear takeover action instead of silently merging control.
- Once the user takes control, increment `leaseEpoch` before accepting user input.
- Queued Pickle mutations carrying the old epoch fail with `stale_control_lease`.
- The controller remains `user` until the user explicitly chooses `Hand Control to Pickle`.
- Do not automatically return control on blur or idle; Picky cannot reliably prove that a partially typed shell line is safe to merge.

### Permission revocation

- `Disable Pickle Control` changes permission to private, changes controller to user, increments lease epoch, and clears any pending read waiters.
- Existing process output remains visible to the user.
- The agent tool no longer receives terminal name, cwd, status details, or output for that terminal.

## Terminal UI

### Top-level utility tabs

Keep the current top-level tab bar unchanged:

```text
Terminal | Artifacts
```

The Terminal tab may show a count badge when more than one terminal exists. Agent-created terminal activity must not auto-select or auto-open the tab.

### Inner terminal strip

Add a compact horizontal terminal strip above the selected terminal body:

```text
[ Terminal 1 ] [ server ● ] [ tests × ]  [+]
```

Each item exposes:

- terminal name;
- non-color process status indicator;
- selected state;
- private/shared/controller status through icon/help/accessibility value;
- close action through a context menu or compact close control.

Use a horizontally scrollable strip if needed; do not shrink labels below existing minimum HUD typography.

### Header actions

The selected terminal header exposes only applicable actions:

- `Allow Pickle Control` for a private user terminal;
- `Disable Pickle Control` for a shared terminal;
- `Take Control` when the Pickle holds the mutation lease;
- `Hand Control to Pickle` when permission is shared and the user holds the lease;
- Rename;
- Close.

Agent actions remain visible in ordinary tool activity. While a terminal mutation request is executing, show a concise `Pickle controlling` status without animation that competes with terminal content.

### Empty and error states

- Empty: explain that terminals are local to this Pickle and provide `New Terminal`.
- Limit reached: keep existing terminals usable and explain the cap.
- Child unavailable: preserve user terminal access and explain that Pickle control is temporarily unavailable.
- Start failure: keep a failed tab with retry/close actions; do not silently remove it.

### Accessibility

- Every terminal tab has a label, selected trait, process status value, and control-permission value.
- Icon-only actions have help and VoiceOver labels.
- Status is never communicated by color alone.
- Keyboard navigation can select tabs and reach create/control/close actions.
- Existing terminal IME, selection, paste, file drop, and line-editing shortcuts remain intact.

## Pickle tool contract

Add one Pickle-only tool named `picky_terminal` under `agentd/src/application/terminal-control-tool.ts`.

The description and prompt guidance remain language-neutral and explain that the tool controls only terminal tabs belonging to the current Pickle.

Proposed operations:

```text
list
create(name?, cwd?)
read(terminalId, generation, lines?, maxChars?, afterRevision?, waitForOutputMs?, quietPeriodMs?)
write(terminalId, generation, leaseEpoch, input?/inputKeys?/inputPaste?)
close(terminalId, generation, leaseEpoch)
```

### Deliberately excluded in v1

- arbitrary `sessionId`;
- raw `inputHex`;
- attach/background/dispatch modes;
- process signal selection;
- resize control;
- arbitrary screen-buffer offset pagination;
- continuous streaming callbacks.

### List result

Return:

- workspace generation;
- shared terminal IDs, names, status, controller, lease epoch, cwd, and output revision;
- selected terminal ID only when that terminal is shared;
- private terminal count without private names or metadata;
- resource-limit values and remaining capacity.

### Create result

Return only after the PTY start attempt has produced `running` or structured `failed` state. A Pickle-created terminal is shared and Pickle-controlled by default.

### Read result

Read returns a rendered terminal tail rather than raw PTY bytes:

```text
terminalId
generation
outputRevision
status
lines
truncated
timedOut
settled
```

Bounds for v1:

- default 20 lines;
- maximum 200 lines;
- default 5 KiB;
- maximum 50 KiB;
- maximum wait 5 seconds.

If `afterRevision` is supplied, wait until output revision advances or the timeout expires. After the first change, `quietPeriodMs` may wait for a short bounded quiet interval before capturing the rendered tail. The wait must yield the MainActor and must not block terminal input or other workspaces.

Do not expose raw incremental cursors in v1. Raw ring trimming, UTF-8 chunk boundaries, alternate-screen transitions, and lost offsets require a separate protocol.

### Write result

A write:

1. validates permission, generation, controller, and lease epoch;
2. serializes behind prior mutations for that terminal;
3. sends exactly one normalized input payload;
4. returns the accepted output revision and current status;
5. instructs the model to use `read(afterRevision:)` when it needs resulting output.

Named keys borrow `interactive_shell` semantics for a small documented set such as `enter`, `escape`, `tab`, arrows, `ctrl+c`, `ctrl+d`, `ctrl+l`, `ctrl+z`, and `alt+x`. Keep the encoder in a pure tested module.

### Close result

Close invalidates the terminal before process termination, returns the current workspace generation and updated selection snapshot, and treats a duplicate operation ID as the same completion rather than closing another terminal.

## Reverse RPC protocol

### Capability handshake

Add `terminalControl` to app capabilities.

To preserve compatibility with older daemons:

1. register existing capabilities first using the current command;
2. register `terminalControl` in a second command;
3. change new agentd capability registration from replacement to set union;
4. tolerate the second command being rejected by an older daemon without losing existing capability registration.

The Pickle tool returns a structured unavailable result when no connected app client has `terminalControl`.

### Event

Proposed app-directed event:

```json
{
  "type": "terminalControlRequested",
  "requestId": "terminal-...",
  "sessionId": "pickle-session-id",
  "operationId": "pi-tool-call-id",
  "operation": {
    "type": "write",
    "terminalId": "term-2",
    "generation": 4,
    "leaseEpoch": 7,
    "inputKeys": ["ctrl+c"]
  }
}
```

### Completion command

```json
{
  "type": "completeTerminalControlRequest",
  "requestId": "terminal-...",
  "operationId": "pi-tool-call-id",
  "result": { "...": "bounded typed result" }
}
```

Errors use stable codes plus a user/model-readable message:

- `terminal_control_unavailable`
- `workspace_not_found`
- `workspace_revoked`
- `terminal_not_found`
- `terminal_private`
- `user_has_control`
- `stale_workspace_generation`
- `stale_control_lease`
- `terminal_limit_reached`
- `terminal_exited`
- `request_timeout`
- `outcome_unknown`

Do not include terminal output in structured logs or error diagnostics.

### Request lifetime

- Use a bounded timeout, default 5 seconds for non-waiting operations and slightly above the requested read wait for waiting reads.
- Disconnect rejects pending requests.
- Abort removes the daemon waiter, but a mutation already dispatched to the app may have completed; report outcome as unknown rather than retrying automatically.
- The tool should reconcile unknown create/write/close outcomes through `list` or `read`, not issue blind retries.

### Idempotency

- Use the Pi tool call ID as `operationId` for mutations.
- App-side controller caches recent mutation results by `(sessionID, workspaceGeneration, operationId)` with a bounded TTL/count.
- Repeating the same operation ID returns the cached result.
- `requestId` correlates one transport attempt; `operationId` identifies the logical mutation.
- A new tool call ID is a new explicit mutation, not an automatic retry.

## Ordering and race handling

### Per-terminal mutation serialization

Serialize create/write/close mutations through workspace/terminal command chains. Reads may observe current state concurrently but must take one atomic MainActor snapshot of generation, revision, status, and rendered tail.

### Write versus close

- Close first invalidates terminal generation/state, then schedules process termination.
- A queued write revalidates generation and lease immediately before sending bytes.
- A late write fails rather than targeting an exited or replacement terminal.

### User takeover versus queued Pickle write

- User takeover increments lease epoch synchronously.
- Every queued Pickle write checks epoch immediately before process input.
- A stale write fails with no bytes sent.

### Archive versus active request

- Archive revokes and increments workspace generation before yielding.
- Pending reads wake with `workspace_revoked`.
- Pending mutations revalidate and fail.
- A late completion cannot recreate workspace state.

### Read-after-write

A write result does not imply process output has arrived. The supported sequence is:

```text
write -> accepted outputRevision
read(afterRevision: acceptedRevision, waitForOutputMs: ...)
```

This prevents the tool from treating a transport acknowledgment as command completion.

## Resource policy

Initial safe caps:

- maximum 4 terminals per Pickle;
- maximum 8 live shell terminals across the app;
- bounded idempotency cache per workspace;
- bounded rendered read output as specified above;
- existing SwiftTerm scrollback preserved initially, with memory measured under the maximum live-terminal scenario before release.

If profiling shows unacceptable memory, add a shell-terminal-specific scrollback limit rather than lowering inline Pi TUI history globally.

Creation failures are structured and visible. Do not evict or kill an existing terminal automatically to make room.

## Swift concurrency and performance

- Keep workspace state, SwiftTerm objects, protocol request handling, and UI projection on `@MainActor`.
- Use a lock only for the minimal output-revision counter if SwiftTerm calls `dataReceived` off MainActor; do not mutate observable UI state from that callback.
- Query rendered terminal state on MainActor.
- Waiting reads use bounded async suspension; never block with semaphores.
- Avoid one `Task` per terminal row or per output chunk.
- Do not publish terminal output chunks through the main session view model.
- Publish only coarse state changes: terminal list, selection, process status, permission/controller, and output revision when a waiting reader requires it.
- Profile utility-panel mount/switch behavior according to `docs/perf-profiling.md`; preserve stable SwiftTerm view identity.

## Agentd design

### Tool composition

In `agentd/src/bootstrap.ts`:

- add an app terminal-control reference similar to the existing app handoff/bridge references;
- register `createPickyTerminalTool(...)` only when `config.mode === "child"`;
- bind the closure to `config.sessionId` so the tool never chooses a Pickle session;
- leave the primary main-agent tool set unchanged.

### Server bridge

In `agentd/src/server.ts`:

- add pending terminal request storage;
- choose only an app client with `terminalControl` capability;
- send typed requests and correlate completions;
- reject pending requests on recipient disconnect and server stop;
- handle unknown/duplicate completions idempotently;
- support timeout derived from bounded read wait;
- never auto-retry mutations after disconnect.

### Protocol schema

In `agentd/src/protocol.ts`:

- add discriminated terminal operation/result schemas;
- add the new event and completion command;
- add `terminalControl` app capability;
- keep optional/additive fields backward compatible;
- bound every string/array/count accepted from the model and app.

### Prompt/tool presentation

- Tool activity should show terminal operation, terminal ID/name when shared, and success/failure.
- Do not journal full terminal output in logs or long-lived Pickle summaries beyond the normal bounded tool result already entering Pi context.
- Do not add terminal command policy to Picky prompts.

## Swift app design

### Workspace controller

Create a focused controller outside `PickySessionViewModel.swift` so the session facade only forwards lifecycle events and exposes projections.

Suggested files:

- `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspaceState.swift`
- `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspacePolicy.swift`
- `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspaceController.swift`
- `Picky/Sessions/TerminalWorkspace/PickyTerminalControlModels.swift`
- `Picky/Sessions/TerminalWorkspace/PickyTerminalKeyEncoder.swift`

### Terminal process adapter

Refactor `PickyShellTerminalSession`/`PickyShellTerminalModel` to support explicit start, attach, rendered snapshot, agent input, status observation, and close. Keep SwiftTerm-specific behavior in the adapter rather than the workspace policy.

Extend `PickySwiftTermView` only at stable override points:

- output revision observation through `dataReceived(slice:)`;
- explicit agent-input path that does not masquerade as user takeover;
- existing IME, drag/drop, line-editing, font, appearance, and scrollback behavior unchanged.

### Router bridge

In `PickyAgentClientRouter.swift`:

- expose an injected terminal-control handler owned by the workspace controller;
- handle `terminalControlRequested` before general event broadcast;
- derive expected session ID from `child:<sessionID>` and require payload equality;
- reply on the same child client that sent the request;
- register the new capability additively;
- return typed errors if the controller is unavailable during startup/shutdown.

### Session lifecycle wiring

In `PickySessionViewModel.swift`:

- replace the one-shell dictionary with workspace-controller access;
- route archive/delete/session-removal/child-exit events into revoke or downgrade operations;
- preserve inline Pi terminal and detached Pi terminal overlay behavior;
- do not merge local shell control with terminal transcript sync/tail state.

## File-by-file change map

### Swift app

- `Picky/HUD/PickyHUDUtilityPanel.swift`
  - preserve two top-level tabs
  - project terminal count badge
  - host multi-terminal workspace view
- `Picky/HUD/Conversation/PickySessionExtendedTerminalView.swift`
  - split shell process adapter from one-terminal presentation
  - add selected-terminal workspace content
- `Picky/Sessions/PickyTerminalOverlay.swift`
  - extend `PickySwiftTermView` output revision and agent-input hooks without changing overlay behavior
- `Picky/Domain/PickyTerminalAttachmentCoordinator.swift`
  - generalize attachment identity to include terminal instance
- `Picky/PickySessionViewModel.swift`
  - delegate shell workspace lifecycle
  - remove the single-shell dictionary and forwarding methods after characterization coverage
- `Picky/PickyAgentProtocol.swift`
  - terminal request/result/operation models
  - new event and completion command
  - capability value
- `Picky/PickyAgentClient.swift`
  - decode/log summary for the new event without output content
- `Picky/PickyAgentClientRouter.swift`
  - child-scoped reverse RPC handler and capability registration
- `Picky/Resources/Localizable.xcstrings`
  - terminal tabs, permission/controller actions, empty/error/limit states, accessibility labels
- new `Picky/Sessions/TerminalWorkspace/` files listed above

### Agentd

- `agentd/src/application/terminal-control-tool.ts`
  - tool schema, bounded result formatting, operationId use
- `agentd/src/application/terminal-control-tool.test.ts`
  - tool contract and error behavior
- `agentd/src/bootstrap.ts`
  - child-only tool registration and server callback reference
- `agentd/src/server.ts`
  - reverse request lifecycle, capability, timeout, disconnect, completion
- `agentd/src/server.test.ts`
  - bridge integration and race/error cases
- `agentd/src/protocol.ts`
  - request/result/event/command schemas
- `agentd/src/protocol.test.ts`
  - parsing, bounds, optional compatibility

### Contracts

Add representative fixtures under `contracts/protocol/`, including:

- terminal control capability registration;
- list request/event and completion;
- write request/event and completion;
- private/stale/limit error completion;
- older capability registration without terminal control.

Update:

- `PickyTests/ProtocolContractTests.swift`
- `agentd/src/protocol.test.ts`

### Swift tests

Suggested focused suites:

- `PickyTests/PickyTerminalWorkspacePolicyTests.swift`
- `PickyTests/PickyTerminalWorkspaceControllerTests.swift`
- `PickyTests/PickyTerminalControlPermissionTests.swift`
- `PickyTests/PickyTerminalOutputSnapshotTests.swift`
- `PickyTests/PickyTerminalKeyEncoderTests.swift`
- `PickyTests/PickyTerminalAttachmentCoordinatorTests.swift`
- `PickyTests/PickyTerminalLifecycleTests.swift`
- `PickyTests/PickyHUDUtilityPanelPolicyTests.swift`
- `PickyTests/PickyAgentClientRouterTests.swift`
- `PickyTests/ProtocolContractTests.swift`

## Test Plan Card

- **Change target:** local shell workspace, terminal utility UI, app-child reverse RPC, Pickle terminal tool.
- **User/system contract:** several terminals remain independently usable; only the owning Pickle can access explicitly shared terminals; user/agent mutations never merge; archive and disconnect cannot resurrect or misroute terminal operations.
- **Related Picky invariants:** local-first operation, explicit session routing, observable failure, single mutable owner, cross-language protocol parity, stable HUD identity.
- **Selected layers:**
  - Pure Swift policy for ordering, selection, permission, lease, generation, limits, and revoke effects.
  - Swift orchestration with fake terminal drivers and fake router replies.
  - Lightweight view projection for labels/actions/badges; no new XCUI harness.
  - Agentd unit tests for tool schema/key/result behavior.
  - Agentd integration tests for server capability/request/completion/disconnect.
  - Cross-language protocol fixtures and both parsers.
  - Targeted real SwiftTerm lifecycle coverage only where fake drivers cannot prove start/exit behavior.
- **Excluded layers:**
  - No packaged runtime smoke because no new native dependency is added.
  - No real `~/.pi`, installed extension, or running-daemon dependency.
  - No full UI snapshot/golden testing.
- **Fake boundaries:** terminal process driver, clock, operation ID, WebSocket app client, child connection key, read-wait scheduler.
- **Race cases:** duplicate mutation ID, lost reply, write-vs-close, takeover-vs-queued-write, archive-vs-request, disconnect-vs-completion, stale generation, stale lease, private terminal access.

### Required automated scenarios

1. Existing utility top-level tabs remain exactly Terminal and Artifacts.
2. Opening an empty workspace creates one private user terminal.
3. Creating multiple terminals preserves deterministic order and selection.
4. Closing selected/middle/last terminals chooses the documented fallback.
5. Terminal IDs are monotonic and never reused.
6. Archive/unarchive allocates a generation newer than the retained tombstone.
7. Per-Pickle and global limits reject creation without evicting terminals.
8. Pickle-created hidden terminal starts before tool success and does not steal focus.
9. Switching selected terminals does not restart processes.
10. Hiding the panel and switching to Artifacts preserve every process.
11. User-created terminal is absent from shared list metadata and rejects read/write/close.
12. Explicit permission grant allows read but leaves user controller until hand-back.
13. User takeover increments lease and invalidates queued Pickle writes.
14. Permission revocation invalidates reads and mutations immediately.
15. Pickle-created terminal begins shared and Pickle-controlled.
16. Rendered read respects line/character limits and truncation metadata.
17. `read(afterRevision:)` waits for a change, settles after bounded quiet, and times out deterministically.
18. Write returns accepted revision without claiming command completion.
19. Named keys encode to expected terminal bytes.
20. Duplicate operation ID returns the cached mutation result.
21. Write queued before close sends no bytes after close invalidation.
22. Archive revokes before any late create/write can execute.
23. Transient disconnect fails requests but keeps terminals alive for the user.
24. Child exit downgrades control and requires explicit hand-back after reconnect.
25. Router rejects a terminal request whose payload session differs from its child key.
26. Primary-daemon terminal requests are rejected in v1.
27. Missing app capability returns a structured tool error without waiting indefinitely.
28. Capability registration remains compatible with older capability sets.
29. Disconnect and server stop reject pending requests exactly once.
30. Unknown/late completion does not mutate pending request state.
31. Protocol fixtures decode in Swift and validate in TypeScript.
32. Existing inline Pi terminal and detached terminal overlay tests remain unchanged.
33. VoiceOver projection exposes selection, status, permission, and controller without color-only meaning.

## Implementation sequence

### Task 1: Characterize current shell behavior

**Files:**

- modify `PickyTests/PickyTerminalLifecycleTests.swift`
- modify `PickyTests/PickyHUDUtilityPanelPolicyTests.swift`
- modify `PickyTests/PickyTerminalAttachmentCoordinatorTests.swift`

**Work:**

- prove the current terminal survives utility-tab switching and view remount;
- prove one process starts once per shell session;
- preserve the two-tab utility policy;
- document current archive closure behavior.

**Validation:** targeted terminal/utility suites must pass before structural changes.

### Task 2: Add pure workspace state and policy

**Files:**

- create `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspaceState.swift`
- create `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspacePolicy.swift`
- create `PickyTests/PickyTerminalWorkspacePolicyTests.swift`

**Work:**

- implement deterministic order/selection;
- monotonic IDs;
- permission/controller/lease transitions;
- generation tombstones and revoke/unarchive behavior;
- per-workspace limit decisions and explicit effects.

**Validation:** pure policy suite only.

### Task 3: Extract terminal process adapter and explicit start

**Files:**

- modify `Picky/HUD/Conversation/PickySessionExtendedTerminalView.swift`
- modify `Picky/Sessions/PickyTerminalOverlay.swift`
- modify `PickyTests/PickyTerminalLifecycleTests.swift`

**Work:**

- separate `start` from `attach`;
- introduce a fakeable process/session protocol;
- preserve process delegate ownership, IME, drag/drop, font, appearance, and close behavior;
- add output revision observation and rendered snapshot API.

**Validation:** lifecycle and output snapshot suites.

### Task 4: Add workspace controller

**Files:**

- create `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspaceController.swift`
- create `Picky/Sessions/TerminalWorkspace/PickyTerminalControlModels.swift`
- create `PickyTests/PickyTerminalWorkspaceControllerTests.swift`

**Work:**

- own terminal process adapters;
- enforce global limits;
- serialize mutations;
- implement idempotency cache;
- implement read wait/quiet logic;
- implement revoke and child lifecycle transitions.

**Validation:** orchestration suite with fake driver/clock/scheduler.

### Task 5: Replace single-shell ViewModel storage

**Files:**

- modify `Picky/PickySessionViewModel.swift`
- modify `Picky/Domain/PickyTerminalAttachmentCoordinator.swift`
- modify `PickyTests/PickySessionViewModelTests.swift`
- modify `PickyTests/PickyTerminalAttachmentCoordinatorTests.swift`

**Work:**

- route shell access through the workspace controller;
- preserve inline and detached Pi terminal paths;
- wire archive, remove, child exit, and cleanup;
- generalize attachment identity.

**Validation:** ViewModel lifecycle and attachment suites.

### Task 6: Implement multi-terminal utility UI

**Files:**

- modify `Picky/HUD/PickyHUDUtilityPanel.swift`
- modify `Picky/HUD/Conversation/PickySessionExtendedTerminalView.swift`
- modify `Picky/Resources/Localizable.xcstrings`
- add focused view-projection tests

**Work:**

- inner terminal strip, count badge, create/select/rename/close;
- permission/controller actions and status projection;
- empty, failure, disconnected, and limit states;
- keyboard/accessibility behavior;
- prevent hidden or Pickle-controlled terminals from stealing focus.

**Validation:** policy/projection tests, macOS build, HUD signpost comparison.

### Task 7: Add cross-language terminal protocol

**Files:**

- modify `agentd/src/protocol.ts`
- modify `Picky/PickyAgentProtocol.swift`
- add `contracts/protocol/terminal-control-*.json`
- modify both protocol test suites

**Work:**

- schemas, bounds, capability, event, completion, errors;
- mixed capability registration behavior;
- additive/optional compatibility.

**Validation:** `test:contracts` plus Swift protocol contract suite.

### Task 8: Add agentd reverse RPC bridge

**Files:**

- modify `agentd/src/server.ts`
- modify `agentd/src/server.test.ts`

**Work:**

- pending request owner, timeout, disconnect, stop, completion;
- additive capability registration;
- operation/request id correlation;
- no mutation auto-retry.

**Validation:** focused server tests, typecheck, lint.

### Task 9: Add Swift router handling

**Files:**

- modify `Picky/PickyAgentClient.swift`
- modify `Picky/PickyAgentClientRouter.swift`
- modify `PickyTests/PickyAgentClientTests.swift`
- modify `PickyTests/PickyAgentClientRouterTests.swift`

**Work:**

- decode event;
- verify child connection ownership;
- invoke workspace handler;
- reply on the same child client;
- register capability without regressing older daemon behavior.

**Validation:** client/router suites and protocol contracts.

### Task 10: Add Pickle-only tool

**Files:**

- create `agentd/src/application/terminal-control-tool.ts`
- create `agentd/src/application/terminal-control-tool.test.ts`
- modify `agentd/src/bootstrap.ts`
- update tool settings/user guide only if the tool is user-configurable

**Work:**

- child-only registration;
- bounded operation schema;
- language-neutral prompt text;
- structured results/errors;
- operationId derived from Pi tool call ID.

**Validation:** focused tool/bootstrap tests and agentd typecheck/lint/build.

### Task 11: Race and lifecycle hardening

**Files:**

- extend workspace, router, server, and tool tests

**Work:**

- duplicate/lost acknowledgment;
- user takeover with queued write;
- write/close ordering;
- archive during request;
- transient disconnect and permanent child exit;
- stale generation and stale lease;
- private terminal data non-disclosure.

**Validation:** targeted suites followed by full serial agentd tests and relevant Swift suites.

### Task 12: Manual acceptance and documentation

**Files:**

- update `docs/user-manual.md`
- update this plan status only after validation

**Work:**

- manually verify multiple terminals, IME, copy/paste, drag/drop, hidden process continuity, permission/controller transitions, archive, and child restart;
- profile Terminal/Artifacts switching and terminal tab selection;
- record resource usage at maximum configured terminal count.

**Constraint:** do not restart the running Picky app without explicit user approval.

## Validation commands

Run the narrowest suites first; exact suite names should match files landed by the implementation.

```bash
# Swift focused suites
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" test \
  -only-testing:PickyTests/PickyTerminalWorkspacePolicyTests \
  -only-testing:PickyTests/PickyTerminalWorkspaceControllerTests \
  -only-testing:PickyTests/PickyTerminalLifecycleTests \
  -only-testing:PickyTests/PickyTerminalAttachmentCoordinatorTests \
  -only-testing:PickyTests/PickyHUDUtilityPanelPolicyTests \
  -only-testing:PickyTests/PickyAgentClientRouterTests \
  -only-testing:PickyTests/ProtocolContractTests

# Agentd focused files
pnpm --dir agentd exec vitest run \
  src/application/terminal-control-tool.test.ts \
  src/server.test.ts \
  src/protocol.test.ts

# Contract and static validation
pnpm --dir agentd run test:contracts
pnpm --dir agentd run typecheck
pnpm --dir agentd run lint
pnpm --dir agentd run build

# Broader validation
pnpm --dir agentd run test:serial
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO test
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" build
git diff --check
```

No packaged Node/native-addon smoke is required for this design because it deliberately adds no new agentd native dependency. A normal packaged-app smoke remains appropriate before release because the bundled app and agentd protocol change together.

## Manual acceptance scenarios

### Multiple user terminals

1. Open the Terminal utility tab and create four terminals.
2. Run distinct long-lived commands in each.
3. Switch terminals and then switch to Artifacts and back.
4. Confirm every process and scroll state remains intact.
5. Close a middle terminal, selected terminal, and final terminal; confirm deterministic selection and empty state.

### Pickle-created hidden terminal

1. Keep the utility panel closed.
2. Ask the Pickle to create a terminal and start a long-running process.
3. Confirm tool success does not open the panel or steal focus.
4. Open the Terminal tab and confirm the process was already running with retained output.

### Permission and takeover

1. Create a user terminal and enter sensitive-looking placeholder text.
2. Confirm `picky_terminal list/read/write/close` cannot identify or access it.
3. Enable Pickle control; confirm read is available but write is blocked while the user controls it.
4. Hand control to the Pickle and confirm write works.
5. Take control while a Pickle write is queued and confirm stale bytes are not sent.
6. Revoke permission and confirm reads/mutations fail immediately.

### Archive and child lifecycle

1. Start several terminals, including one Pickle-controlled process.
2. Archive while a terminal tool request is active.
3. Confirm every PTY closes and no late request recreates a workspace.
4. In a separate non-archive scenario, terminate/restart the child daemon only with explicit test approval.
5. Confirm terminals remain usable by the user, Pickle mutation control is revoked, and explicit hand-back is required after reconnect.

### Input compatibility

Verify Korean IME input, command-arrow/delete line editing, copy/paste, bracketed paste, file drag/drop, Ctrl-C, alternate screen TUIs, and terminal focus routing across terminal-tab switches.

## Observability

Add scalar structured logs for:

- workspace create/revoke/remove;
- terminal create/start/exit/close with session ID and terminal ID only;
- permission/controller/lease transition;
- request start/finish/error code/latency;
- duplicate operation result reuse;
- stale generation/lease rejection;
- resource-limit rejection;
- disconnect/child-exit downgrade.

Do not log:

- terminal output;
- terminal input or command text;
- pasted content;
- terminal names when private;
- environment variables;
- cwd if existing logging privacy rules would exclude it.

Suggested performance markers:

```text
terminal_workspace_mount
terminal_instance_switch
terminal_process_start
terminal_rendered_tail_snapshot
terminal_control_rpc
```

## Rollout and rollback

### Compatibility

- The tool is capability-gated; without a supporting app it returns unavailable.
- Terminal events are emitted only to clients that registered `terminalControl`.
- New app capability registration must not erase existing capabilities or break older daemons.
- App and bundled agentd ship together, but contract tests still cover missing/new capability combinations.

### Rollback

A safe rollback may:

- disable child registration of `picky_terminal`;
- stop registering `terminalControl` capability;
- retain the multi-terminal user UI and app-owned workspaces;
- keep the additive protocol schemas ignored while the capability is absent.

Do not roll back by granting the Pickle unrestricted access to all user terminals or by merging terminal control into generic `pickleBridge` payloads.

## Definition of done

- Utility panel remains exactly Terminal and Artifacts.
- A Pickle can own multiple independent local shell processes.
- User and Pickle can create terminals without unintended focus changes.
- User-created terminals are private by default.
- Shared permission and exclusive controller state are visible and accessible.
- User and Pickle writes cannot merge under tested takeover races.
- Pickle operations are scoped to the owning child session and explicit terminal ID.
- Reads are bounded rendered snapshots with explicit revision/wait semantics.
- Mutations are generation/lease checked, serialized, and idempotent by operation ID.
- Archive, disconnect, child exit, duplicate completion, and lost acknowledgment paths are safe and observable.
- Protocol schemas, fixtures, Swift decoding, TypeScript validation, and both contract suites agree.
- Existing inline Pi terminal and detached terminal overlay behavior remains intact.
- Targeted tests, full agentd validation, relevant Swift tests, and macOS build pass.
- HUD terminal switching is profiled and does not introduce material mount/layout regression.
- Manual IME, paste, drag/drop, long-running process, permission, and lifecycle scenarios are recorded.
- The running Picky app was not restarted without explicit user approval.

## Technical review record

This design was reviewed from verifier, reviewer, and challenger perspectives before documentation.

Common conclusions:

- app-owned SwiftTerm is the lower-risk v1 backend;
- the feature is a capability/concurrency protocol, not only a tab UI;
- user-created terminals need explicit opt-in;
- process startup must be independent from view mounting;
- resource limits are mandatory;
- archive must revoke before closing;
- raw incremental output should be omitted until it has loss-aware cursor semantics;
- request IDs alone do not provide mutation idempotency;
- user takeover requires a lease/epoch that invalidates queued agent writes.

Residual risk:

- SwiftTerm focus and input-origin behavior still require runtime verification;
- memory use at maximum terminal count must be measured;
- read quiet-time defaults may need adjustment against real shells and TUIs;
- mixed app/daemon capability registration requires explicit contract tests.

## Reference map

- Product and architecture constraints: `AGENTS.md`, `ARCHITECTURE.md`
- Utility-panel decision: `docs/utility-panel-activity-artifacts-plan.md`
- Design direction: `design/DESIGN.md`, `design/PRINCIPLES.md`, `design/COMPONENTS.md`
- Refactoring ownership and protocol rules: `docs/refactoring-principles.md`
- Swift async ownership: `docs/swift-concurrency.md`
- HUD performance: `docs/perf-profiling.md`
- Current utility panel: `Picky/HUD/PickyHUDUtilityPanel.swift`
- Current local shell: `Picky/HUD/Conversation/PickySessionExtendedTerminalView.swift`
- Shared SwiftTerm view and detached overlay: `Picky/Sessions/PickyTerminalOverlay.swift`
- Current shell state owner: `Picky/PickySessionViewModel.swift`
- App-daemon protocol: `Picky/PickyAgentProtocol.swift`, `agentd/src/protocol.ts`
- Child routing and reverse bridge: `Picky/PickyAgentClientRouter.swift`, `agentd/src/server.ts`, `agentd/src/bootstrap.ts`
- `interactive_shell` reference implementation: `~/.pi/agent/extensions/interactive-shell/`
- SwiftTerm official source/docs: https://github.com/migueldeicaza/SwiftTerm
- node-pty official source/docs: https://github.com/microsoft/node-pty
