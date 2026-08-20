# Pickle Multi-Terminal Control Plan

_Status: Gate 0 design drafted; awaiting explicit approval; implementation blocked and not started_

_Last updated: 2026-08-20_

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
- Keep PTYs in Picky.app using SwiftTerm for v1; pin the package requirement to the currently verified revision before implementation begins.
- Support multiple terminals within one Pickle; do not add split panes in v1.
- A terminal created by the Pickle is shared with that Pickle by default.
- If that Pickle is currently active in the HUD when its terminal is inserted, expand its utility panel, select `Terminal`, and select the new terminal without moving keyboard focus or activating another Pickle.
- If the creating Pickle is not currently active, create the terminal without changing session selection, panel visibility, selected utility tab, or keyboard focus; do not queue a deferred reveal.
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
- **Primary actions:** select terminal, create terminal, type into terminal; an active Pickle's agent-created terminal reveals itself without stealing focus.
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

`PickyShellTerminalModel.startProcessIfNeeded` calls SwiftTerm's `LocalProcessTerminalView.startProcess`. `PickySwiftTermView` already subclasses `LocalProcessTerminalView`. The currently resolved SwiftTerm revision exposes the APIs needed by this plan, but the Xcode package requirement still follows `main`; Gate 0 requires pinning the verified revision before implementation:

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
3. Start a Pickle-created terminal independently of panel mounting and reveal it automatically only when its owning Pickle is currently active.
4. Keep terminal process ownership independent from SwiftUI mount/unmount.
5. Give the owning Pickle an explicit, scoped, observable terminal tool.
6. Keep user-created terminals private until the user opts in.
7. Prevent user/agent input collisions with an exclusive mutation lease.
8. Make create/write/close safe against stale workspace instance, generation, terminal incarnation, duplicate request, archive, app restart, and disconnect races.
9. Keep reads bounded and distinguish rendered snapshots from raw incremental streams.
10. Prevent terminal input, output, and private metadata from leaking through tool activity, protocol logs, snapshots, or persisted session state.
11. Preserve local-first behavior and avoid a new native Node dependency.

## Non-goals

- No Activity/Progress tab redesign.
- No split panes, draggable pane layouts, or tmux-style layouts.
- No durable PTY restoration after app restart.
- No remote terminal access or network listener.
- No generic Pi TUI overlay implementation.
- No `interactive`, `hands-free`, `dispatch`, attach/detach, or completion notification modes from `interactive_shell`.
- No raw hex input in the initial Pickle tool.
- No arbitrary cross-Pickle session ID parameter in the tool.
- No activation or deferred panel reveal for an inactive Pickle when it creates a terminal; active-Pickle creation follows the explicit reveal policy below.
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
- Every workspace receives an unpredictable `workspaceInstanceID`; it changes after app restart and whenever a new workspace incarnation is created.
- Every terminal process receives a `terminalIncarnation`; async start/exit callbacks must match it before mutating state.
- Every mutating request targets an explicit terminal ID and carries workspace instance ID, workspace generation, terminal incarnation when applicable, and lease epoch.
- Terminal IDs are monotonic within one workspace instance and generation and are never reused there.
- Archive/revoke increments workspace generation before closing processes.
- App restart invalidates every pre-restart terminal reference even if a later workspace reuses the same session ID, generation number, or terminal ID.
- The operation ledger reserves mutation IDs before the first suspension, coalesces identical in-flight duplicates, rejects the same ID with a different canonical payload fingerprint, and retains bounded completed outcomes.
- Every mutation revalidates workspace instance, generation, terminal incarnation, permission, controller, and lease immediately before its side effect.
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
    let workspaceInstanceID: String
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
    let terminalIncarnation: String
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

- `[sessionID: Workspace]` with an unpredictable workspace instance ID;
- a monotonic generation tombstone per session ID, retained after workspace removal for the app lifetime;
- terminal process adapters keyed by `(sessionID, workspaceInstanceID, terminalID, terminalIncarnation)`;
- resource-limit accounting that retains slots until confirmed process exit;
- mutation chains and a bounded in-flight/completed operation ledger keyed by workspace identity and operation ID;
- bounded read waiters with per-terminal and global caps and exactly-once settlement;
- archive/revoke and child-connection/process lifecycle transitions;
- request handling on `@MainActor`.

A pure `PickyTerminalWorkspacePolicy` decides:

- insertion order and selected-terminal fallback;
- monotonic terminal IDs such as `term-1`, `term-2`;
- permission transitions;
- controller/lease transitions;
- stale workspace instance, generation, terminal incarnation, and lease rejection;
- operation fingerprint collision behavior;
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
- at workspace insertion on `@MainActor`, check whether the owning Pickle is still the active HUD session;
- if active, expand that Pickle's utility panel, select `Terminal`, and select the new terminal while preserving the current first responder and without activating another app/window;
- if inactive, perform no UI reveal, Pickle activation, tab switch, focus change, or deferred reveal; the process continues and appears normally when the user later opens that Pickle.

### Decouple start from mount

Refactor `PickyShellTerminalModel` so process startup is an explicit operation, not a side effect of `NSViewRepresentable.makeNSView`.

- `PickyShellTerminalSession.start()` prepares deterministic initial terminal geometry and starts the process once.
- `attach()` only mounts/configures the existing SwiftTerm view and updates terminal size.
- hidden terminals have a valid initial row/column size before spawn.
- repeated view mounts never start another process.

### Selection and attachment

- One selected terminal ID is shared across every projection of a Pickle workspace.
- Preserve the existing invariant that one SwiftTerm `NSView` cannot attach to multiple parents.
- Replace the current globally active shell attachment record with attachment ownership keyed by terminal instance: `(sessionID, workspaceInstanceID, terminalID) -> attachmentID`.
- An attachment request also carries `terminalIncarnation` so a stale view cannot mount a replacement process.
- Switching tabs detaches the old selected terminal view and attaches the new selected terminal without restarting either process.
- Inactive terminal processes and buffers remain alive.

### Closure

- User closure is always allowed and invalidates pending Pickle mutations before terminating the PTY.
- Pickle closure requires shared permission, Pickle controller lease, matching workspace instance, generation, terminal incarnation, and lease epoch.
- Closing first marks the terminal unavailable to new input, then requests process termination.
- A live-terminal capacity slot is released only after the matching process incarnation confirms exit; a stale exit callback cannot release a replacement terminal's slot.
- The process adapter must define bounded termination escalation and a structured close-timeout outcome for an unresponsive shell rather than treating `terminate()` as confirmed death.
- Closing the selected terminal selects the nearest remaining terminal deterministically.
- Closing the last terminal shows an empty state; it does not immediately create a replacement.
- Natural process exit keeps a lightweight exited tab until the user closes it, allowing output inspection.

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

- Every connection/disconnect/exit callback carries the router's child connection generation; callbacks from an older child generation are ignored.
- Transient WebSocket disconnect: keep terminal processes, fail in-flight RPCs, revoke active Pickle mutation leases, settle pending reads, and show control unavailable.
- Child process exit/crash: keep terminals available to the user, downgrade shared terminals to user controller, and require explicit hand-back after a replacement child connects.
- Reconnect never restores Pickle mutation control automatically.
- Explicit child release after archive/delete: workspace is already revoked and closes normally.
- App termination: existing app lifecycle terminates app-owned PTYs; no durable restoration is attempted. A later app process creates a new unpredictable workspace instance ID, so pre-restart references are stale.

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
- Every byte headed to the PTY is classified as `user`, `agent`, or `terminalProtocol` and passes through one final sink gate.
- User-originated keyboard, IME commit, paste, drag/drop, and line-editing bytes require current user control immediately before forwarding.
- Agent input uses an explicitly tagged adapter path and requires matching workspace instance, generation, terminal incarnation, Pickle controller, and lease at the same sink.
- Terminal-protocol replies generated internally by SwiftTerm are never treated as user or agent input; they may pass only for the current running terminal incarnation. Task 1 characterization must prove whether SwiftTerm exposes enough origin information to enforce this classification without breaking TUIs.
- Handing control to the Pickle must resign terminal focus and resolve or cancel marked text before agent bytes are accepted.
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

The Terminal tab may show a count badge when more than one terminal exists. When the currently active Pickle creates a terminal, the app expands its utility panel, selects `Terminal`, and selects the new terminal without changing keyboard focus. Creation by an inactive Pickle does not activate that Pickle or change any visible panel/tab state and does not schedule a deferred reveal.

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
create(workspaceInstanceId, generation, name?, cwd?)
read(workspaceInstanceId, terminalId, terminalIncarnation, generation, lines?, maxChars?, afterRevision?, waitForOutputMs?, quietPeriodMs?)
write(workspaceInstanceId, terminalId, terminalIncarnation, generation, leaseEpoch, input?/inputKeys?/inputPaste?)
close(workspaceInstanceId, terminalId, terminalIncarnation, generation, leaseEpoch)
operationStatus(workspaceInstanceId, generation, operationId, operationFingerprint)
```

`list` is the discovery operation and returns the current workspace instance ID. For a live, non-archived Pickle session with no workspace yet, it may allocate an empty workspace identity without starting a process; it must never recreate an archived/revoked workspace. All later operations must echo the returned identity. `operationStatus` is read-only and reports the bounded ledger state for an outcome-unknown mutation without replaying the side effect.

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

- workspace instance ID and generation;
- shared terminal IDs, terminal incarnations, names, status, controller, lease epoch, cwd, and output revision;
- selected terminal ID only when that terminal is shared;
- private terminal count without private names or metadata;
- resource-limit values and remaining capacity.

### Create result

Return only after the PTY start attempt has produced `running` or structured `failed` state. A Pickle-created terminal is shared and Pickle-controlled by default. UI reveal is a separate app-side effect evaluated when the terminal is inserted: reveal/select it only if the owning Pickle is the current HUD selection, and otherwise make no visible or deferred UI change.

### Read result

Read returns a rendered terminal tail rather than raw PTY bytes:

```text
workspaceInstanceId
terminalId
terminalIncarnation
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

### Close and operation-status results

Close invalidates the terminal before process termination, returns the current workspace identity/generation and updated selection snapshot, and treats a duplicate operation ID as the same logical mutation rather than closing another terminal. Capacity remains occupied until the matching process incarnation confirms exit.

`operationStatus` returns `pending`, `succeeded`, `failed`, `outcome_unknown`, `not_found`, or `payload_mismatch` plus the original operation ID and fingerprint. It never exposes terminal input/output or private metadata and never executes a mutation.

## Reverse RPC protocol

### Capability handshake

Add `terminalControl` to app capabilities without changing the replacement semantics of the existing `registerAppCapabilities` command.

To preserve compatibility with older daemons and support explicit rollout/rollback:

1. register the existing legacy capability set using `registerAppCapabilities`;
2. add new `addAppCapabilities` and `removeAppCapabilities` commands in the new protocol;
3. after the app-side handler is ready and the local terminal-control feature gate is enabled, send `addAppCapabilities(["terminalControl"])`;
4. before handler teardown or feature disablement, send `removeAppCapabilities(["terminalControl"])` when possible;
5. tolerate an older daemon rejecting the new command while retaining the legacy capabilities registered by step 1;
6. scope capability state to one WebSocket connection so reconnect starts from an empty set.

The Pickle tool returns a structured unavailable result when no connected app client has `terminalControl`. Agent terminal control remains behind a default-off local feature gate until the automated, security, manual, and performance gates pass; this is not a user-facing preference.

### Event

Proposed app-directed event:

```json
{
  "type": "terminalControlRequested",
  "requestId": "terminal-...",
  "sessionId": "pickle-session-id",
  "operationId": "pi-tool-call-id",
  "operationFingerprint": "sha256-canonical-operation",
  "operation": {
    "type": "write",
    "workspaceInstanceId": "workspace-random-id",
    "terminalId": "term-2",
    "terminalIncarnation": "terminal-random-id",
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
  "operationFingerprint": "sha256-canonical-operation",
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
- `stale_workspace_instance`
- `stale_workspace_generation`
- `stale_terminal_incarnation`
- `stale_control_lease`
- `operation_payload_mismatch`
- `terminal_limit_reached`
- `terminal_exited`
- `terminal_closing`
- `read_waiter_limit_reached`
- `close_timeout`
- `request_timeout`
- `outcome_unknown`

Do not include terminal output in structured logs or error diagnostics.

### Request lifetime

- Use a bounded timeout, default 5 seconds for non-waiting operations and slightly above the requested read wait for waiting reads.
- Pending records bind the selected recipient WebSocket, configured child session ID, request ID, operation ID, and operation fingerprint.
- A completion is accepted only from the selected recipient WebSocket with every bound identity matching; foreign, late, and duplicate completions do not settle or mutate another request.
- Disconnect rejects pending requests exactly once.
- Abort removes the daemon waiter, but a mutation already dispatched to the app may have completed; report `outcome_unknown` with the operation ID/fingerprint rather than retrying automatically.
- Reconcile unknown create/write/close outcomes through `operationStatus`; `list` or `read` may provide context but are not authoritative proof of whether a side effect occurred.
- No transport layer automatically retries a mutation.

### Idempotency

- Use the Pi tool call ID as `operationId` for mutations and return it with the canonical operation fingerprint in mutation results and `outcome_unknown` errors.
- The app-side controller synchronously reserves the ledger entry before the first `await`.
- The ledger key includes `(sessionID, workspaceInstanceID, workspaceGeneration, operationId)` and stores the canonical operation fingerprint.
- Identical in-flight duplicates coalesce; completed duplicates return the bounded cached result; the same ID with a different fingerprint fails with `operation_payload_mismatch`.
- Ledger count/TTL eviction is deterministic and cannot permit an old operation to target a replacement workspace or terminal incarnation.
- `requestId` correlates one transport attempt; `operationId` identifies the logical mutation.
- A new tool call ID is a new explicit mutation, not an automatic retry.

## Ordering and race handling

### Per-terminal mutation serialization

Serialize create through a workspace command chain and write/close through terminal command chains. Reserve operation IDs before enqueueing. Reads may observe current state concurrently but must take one atomic MainActor snapshot of workspace instance, generation, terminal incarnation, revision, status, permission, and rendered tail.

### Write versus close

- Close first invalidates terminal state, then schedules process termination.
- A queued write revalidates workspace instance, generation, terminal incarnation, permission, controller, and lease at the final PTY byte sink immediately before sending bytes.
- User-originated input passes through the same exclusive-control sink rather than relying only on focus state.
- A late write fails rather than targeting an exited or replacement terminal.

### User takeover versus queued Pickle write

- User takeover increments lease epoch synchronously.
- Every queued Pickle write checks epoch immediately before process input.
- A stale write fails with no bytes sent.

### Archive versus active request

- Archive revokes and increments workspace generation before yielding.
- Pending reads settle exactly once with `workspace_revoked`.
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
- maximum 8 live or closing shell terminals across the app;
- bounded mutation ledger per workspace;
- bounded pending read waiters per terminal and across the app;
- bounded rendered read output as specified above;
- a shell-terminal-specific scrollback/image-resource policy set before agent control is enabled, without lowering inline Pi TUI history globally.

A closing terminal retains its capacity slot until the matching process incarnation confirms exit. Creation failures are structured and visible. Do not evict or kill an existing terminal automatically to make room.

Before enablement, run maximum-capacity soak/profiling with sustained output, long lines, ANSI redraw, alternate-screen TUIs, and supported terminal graphics payloads. Record memory and render responsiveness rather than assuming terminal count alone bounds resource use.

## Swift concurrency and performance

- Keep workspace state, SwiftTerm objects, protocol request handling, and UI projection on `@MainActor`.
- Use a lock only for the minimal output-revision counter if SwiftTerm calls `dataReceived` off MainActor; do not mutate observable UI state from that callback.
- Query rendered terminal state on MainActor.
- Waiting reads use bounded async suspension; never block with semaphores.
- A waiter is registered by opaque token only after an atomic revision check, rechecks immediately after registration, resets its quiet timer on later revisions, and settles exactly once on output, timeout, exit, close, permission revoke, workspace revoke, disconnect, or cancellation.
- Enforce explicit per-terminal and global waiter caps.
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

### Prompt/tool presentation and privacy

- Tool activity may show only the terminal operation, shared terminal ID/name, safe status/error code, and success/failure.
- `picky_terminal` start/update/end events receive terminal-specific normalization before generic previews are built.
- Never copy terminal input, pasted text, rendered output, private terminal name/cwd/status, environment, or full result text into tool activity, WebSocket snapshots, persisted session JSON, summaries, structured logs, or error diagnostics.
- Add integrated canary tests that scan normalized activity, runtime session state, outbound snapshots/events, persistence output, and logs. The bounded tool result may still enter Pi's immediate tool context as required for the model to continue.
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
- final user-input interception through `send(source:data:)`;
- explicit origin-tagged agent-input path;
- both paths delegate authorization to the shell adapter/controller immediately before forwarding bytes to the process;
- existing IME, drag/drop, line-editing, font, appearance, and scrollback behavior unchanged.

### Router bridge

In `PickyAgentClientRouter.swift`:

- expose an injected terminal-control handler owned by the workspace controller;
- handle `terminalControlRequested` before general event broadcast;
- derive expected session ID from `child:<sessionID>` and require payload equality;
- reply on the same child client that sent the request;
- add/remove the new capability only after the handler and default-off local feature gate are ready;
- forward transient socket disconnect and child process exit with the router child generation so stale lifecycle callbacks are ignored;
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
  - pin verified SwiftTerm assumptions in characterization coverage
  - extend `PickySwiftTermView` output revision and final input-gate hooks without changing overlay behavior
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
  - request/result/event/command schemas, including additive capability commands and operation-status lookup
- `agentd/src/protocol.test.ts`
  - parsing, bounds, optional compatibility
- `agentd/src/domain/pi-event-normalizer.ts` and its tests
  - terminal-specific activity redaction before generic previews or persistence

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
- **Fake boundaries:** terminal process driver, clock, workspace/terminal identity factory, operation ID/fingerprint, WebSocket app client, child connection key/generation, read-wait scheduler, activity persistence sink.
- **Race cases:** duplicate in-flight mutation ID, operation payload mismatch, lost reply and ledger lookup, write-vs-close, takeover-vs-user/agent queued bytes, archive-vs-request, app-restart ABA, disconnect-vs-completion, stale child callback, stale generation/incarnation/lease, waiter registration race, private terminal access and persistence.

### Required automated scenarios

1. Existing utility top-level tabs remain exactly Terminal and Artifacts.
2. Opening an empty workspace creates one private user terminal.
3. Creating multiple terminals preserves deterministic order and selection.
4. Closing selected/middle/last terminals chooses the documented fallback.
5. Terminal IDs are monotonic and never reused.
6. Archive/unarchive allocates a generation newer than the retained tombstone.
7. Per-Pickle and global limits reject creation without evicting terminals.
8. A terminal created by the active Pickle starts independently of view mounting, opens the utility panel on `Terminal`, selects the new terminal, and preserves the current first responder.
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
34. A pre-restart workspace reference cannot access a post-restart workspace even when session ID, generation, and terminal ID match.
35. A delayed start/exit callback for an old terminal incarnation cannot mutate or release capacity for its replacement.
36. User keyboard, IME commit, paste, drag/drop, line-editing shortcut, and agent writes are all rejected at the final PTY byte sink when their controller/lease is stale.
37. Simultaneous duplicate mutations send bytes or close a process exactly once; the same operation ID with a different fingerprint is rejected.
38. `operationStatus` reconciles a mutation whose side effect completed but transport completion was lost, without replaying it.
39. Output arriving between revision check and waiter registration is observed; every waiter settles exactly once on all terminal/workspace/permission/connection transitions.
40. A completion from a different capable app socket is rejected while the original recipient may still complete the request.
41. An old child generation's disconnect/exit callback cannot revoke control belonging to a replacement child.
42. Terminal tool start/update/end canary secrets are absent from normalized activity, runtime session state, snapshots/events, persistence, and logs.
43. Closing/unresponsive terminals retain capacity until confirmed exit and cannot release a replacement incarnation's slot.
44. Legacy capability registration survives rejection of additive terminal-control commands, and explicit removal stops new terminal events on the same socket.
45. Agent control remains unavailable while the local feature gate is off, even when protocol schemas and UI are present.
46. A terminal created by an inactive Pickle starts normally but causes no Pickle activation, panel/tab change, focus change, or deferred reveal.

## Gate 0 design approval gate

**Current state:** the following design contract is drafted but not approved. No implementation task below may start until the user explicitly approves Gate 0. Approval authorizes the implementation workflow; signed-app launches, Picky restarts, child-daemon restarts, and manual security tests still require their own explicit approval at the relevant gate.

### Gate 0 locked decisions

1. **Identity and stale barriers**
   - Add unpredictable `workspaceInstanceID` and per-process `terminalIncarnation`.
   - Carry them through state, protocol operations/results, callbacks, attachment ownership, mutation ledger keys, and tests.
   - Preserve generation and lease epoch as separate monotonic barriers within a workspace instance.

2. **Exclusive input enforcement**
   - Authorize bytes at the final PTY sink, not only in SwiftUI focus/action code.
   - Classify `user`, `agent`, and internally generated `terminalProtocol` bytes; revalidate the appropriate controller/lease/incarnation immediately before process input.
   - Characterize SwiftTerm's origin information before implementation; do not block required terminal-protocol replies or misclassify them as human input.
   - Hand-back to the Pickle resigns focus and resolves/cancels marked text before agent writes are allowed.

3. **Mutation ledger and unknown outcomes**
   - Reserve before the first suspension, coalesce identical in-flight duplicates, fingerprint canonical payloads, and bound completed outcomes.
   - Add read-only `operationStatus`; never reconcile a mutation by blind retry.

4. **Read waiter ownership**
   - Cap waiters per terminal and globally.
   - Use atomic revision checks around registration and exactly-once settlement for every output/timeout/lifecycle path.

5. **Connection and completion integrity**
   - Bind requests to recipient socket, child session, child generation, request ID, operation ID, and fingerprint.
   - Distinguish transient WebSocket disconnect from child process exit and ignore stale child-generation callbacks.

6. **Capability compatibility and rollout**
   - Keep `registerAppCapabilities` replacement semantics.
   - Add separate additive/removal commands for `terminalControl` and tolerate older-daemon rejection.
   - Keep agent terminal control behind a default-off local feature gate until final approval.

7. **Privacy boundary**
   - Redact terminal input/output and private metadata before generic tool preview normalization.
   - Require integrated canary scans across activity, snapshots, persistence, and logs.

8. **Process/resource lifecycle**
   - Pin the verified SwiftTerm revision before implementation.
   - Confirm process exit before releasing capacity; define bounded close escalation.
   - Set shell-specific scrollback/resource limits and record maximum-capacity soak results.

9. **Security and performance evidence**
   - Record a pre-change HUD signpost/mount baseline and agree on the acceptance threshold before UI implementation.
   - With explicit launch approval, compare protected-resource behavior of child agentd and an app-owned PTY in a signed build. If the app-owned PTY receives materially broader authority, stop and revisit the backend or least-privileged helper boundary.

10. **Frozen cross-lane interfaces**
    - Tool name: `picky_terminal`.
    - Freeze the tool-to-server callback signature, operation/result/error types, redaction allowlist, and feature-gate behavior before isolated workers branch.
    - One owner controls Swift/TypeScript protocol schemas and fixtures as one atomic contract set.

11. **Agent-created terminal reveal policy**
    - "Active Pickle" means the current HUD session selection, not merely a live child runtime or unarchived session.
    - Evaluate that selection at terminal workspace insertion on `@MainActor`.
    - For the active Pickle, expand the utility panel, select `Terminal`, and select the new terminal without changing first responder or activating another app/window.
    - For an inactive Pickle, create the terminal with no session activation, panel/tab/focus mutation, or deferred reveal.

### Gate 0 approval checklist

- [ ] Product owner approves the identity, lease, privacy, capability, rollout, and active-Pickle reveal contracts above.
- [ ] The performance baseline scenario and threshold are written down.
- [ ] The SwiftTerm revision to pin is recorded.
- [ ] The signed TCC/security spike is approved separately before it is run.
- [ ] Isolated worktrees/checkpoint commits are approved, or implementation is restricted to one writer at a time on the main worktree.
- [ ] No implementation, app restart, daemon restart, or manual acceptance run has occurred.

### Adaptive implementation workflow after approval

```text
Gate 0 approval
  -> Wave 1 parallel: adapter characterization | pure policy | cross-language contract | activity redaction
  -> Gate 1 integrated green checkpoint
  -> Wave 2 parallel: workspace controller | agentd reverse RPC | tool core (not registered)
  -> Gate 2 integrated green checkpoint
  -> sequential ViewModel/lifecycle integration
  -> parallel router integration | terminal UI
  -> tool/capability enablement behind default-off feature gate
  -> Gate 3 fake end-to-end integration
  -> verifier + reviewer + challenger + security-auditor, maximum two hardening cycles
  -> Gate 4 broad automated validation
  -> Gate 5 explicit manual/security/performance approval and feature enablement
```

Rules:

- The main orchestrator alone integrates lane checkpoints and reruns the integrated gate before downstream workers branch.
- Parallel workers never edit the same file; dependent lanes branch only from a recorded green checkpoint.
- Review agents report findings but do not modify production code; fixes return to the owning implementation lane.
- Private-data disclosure, cross-session routing, stale bytes after revoke/takeover, process resurrection, or protocol mismatch blocks progression.
- Deterministic barriers/fake clocks enumerate race interleavings; repeated test runs alone are not accepted as concurrency proof.
- Maximum two hardening cycles. If P0/P1 findings remain, stop at the last green checkpoint and request a design decision.

Lane ownership after approval:

| Lane | Scope | Exclusive ownership while active |
| --- | --- | --- |
| Adapter characterization | Task 1 and Task 3 | `PickySessionExtendedTerminalView.swift`, minimal `PickyTerminalOverlay.swift` hooks, lifecycle/output tests |
| Pure app domain | Task 2, then Task 4 after Gate 1 | new `Picky/Sessions/TerminalWorkspace/` policy/controller files and tests |
| Cross-language contract | Task 7 | Swift protocol, TypeScript protocol, fixtures, both contract suites as one atomic set |
| Activity privacy | redaction portion of Tasks 10–11 | `pi-event-normalizer` and activity/persistence canary tests |
| Agentd bridge | Task 8 | `server.ts` and server tests |
| Tool core | Task 10 before enablement | terminal tool files/tests; no `bootstrap.ts` until Gate 3 |
| App lifecycle integration | Task 5 | `PickySessionViewModel.swift`, attachment coordinator, lifecycle tests |
| Router integration | Task 9 | client/router files and tests |
| Terminal UI | Task 6 after adapter ownership releases | utility panel, terminal presentation, localization, projection tests |
| Hardening | Task 11 | tests first; production fixes return to the owning lane |

Never parallel-edit `PickySessionExtendedTerminalView.swift`, either protocol schema, `PickySessionViewModel.swift`, `PickyAgentClientRouter.swift`, `agentd/src/server.ts`, or `agentd/src/bootstrap.ts`.

## Implementation sequence

**Approval hold:** all tasks below are pending Gate 0 approval. The task numbers remain as the file-level implementation map; execution follows the adaptive waves above rather than treating Tasks 1–12 as one uninterrupted linear worker.

### Task 1: Pin and characterize the current shell boundary

**Files:**

- modify the SwiftTerm package requirement in `Picky.xcodeproj/project.pbxproj`
- modify `PickyTests/PickyTerminalLifecycleTests.swift`
- modify `PickyTests/PickyHUDUtilityPanelPolicyTests.swift`
- modify `PickyTests/PickyTerminalAttachmentCoordinatorTests.swift`

**Work:**

- pin the verified SwiftTerm revision and record the required override points;
- characterize whether SwiftTerm distinguishes user input from internally generated terminal-protocol replies at the final send path;
- introduce only the minimal fakeable characterization seam needed before structural refactoring;
- prove the current terminal survives utility-tab switching and view remount;
- prove one process starts once per shell session;
- preserve the two-tab utility policy;
- document current archive closure behavior;
- capture the pre-change terminal mount/switch signpost baseline.

**Validation:** targeted terminal/utility suites and package resolution must pass before structural changes.

### Task 2: Add pure workspace state and policy

**Files:**

- create `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspaceState.swift`
- create `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspacePolicy.swift`
- create `PickyTests/PickyTerminalWorkspacePolicyTests.swift`

**Work:**

- implement deterministic order/selection;
- unpredictable workspace instance IDs, terminal incarnations, and monotonic terminal IDs;
- permission/controller/lease transitions;
- generation tombstones and revoke/unarchive/app-restart behavior;
- operation fingerprint mismatch decisions;
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
- gate all user and agent bytes at the final PTY sink with explicit origin and lease/incarnation revalidation;
- preserve process delegate ownership, IME, drag/drop, font, appearance, and close behavior;
- add output revision observation and rendered snapshot API;
- define confirmed-exit closure, bounded termination escalation, and stale callback rejection.

**Validation:** lifecycle and output snapshot suites.

### Task 4: Add workspace controller

**Files:**

- create `Picky/Sessions/TerminalWorkspace/PickyTerminalWorkspaceController.swift`
- create `Picky/Sessions/TerminalWorkspace/PickyTerminalControlModels.swift`
- create `PickyTests/PickyTerminalWorkspaceControllerTests.swift`

**Work:**

- own terminal process adapters;
- enforce global limits through confirmed process exit;
- serialize mutations;
- implement the pre-suspension mutation ledger, payload fingerprinting, and operation-status lookup;
- implement bounded read waiters and deterministic wait/quiet logic;
- implement revoke and child lifecycle transitions using child connection generations.

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
- wire archive, remove, transient disconnect, child exit, and cleanup with composable lifecycle callbacks;
- generalize attachment ownership per workspace/terminal incarnation rather than retaining one global active shell attachment.

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
- reveal a newly created terminal only for the currently active Pickle by expanding the panel and selecting `Terminal`/the new tab;
- preserve first responder during active-Pickle reveal and make inactive-Pickle creation produce no visible UI change or deferred reveal.

**Validation:** policy/projection tests, macOS build, HUD signpost comparison.

### Task 7: Add cross-language terminal protocol

**Files:**

- modify `agentd/src/protocol.ts`
- modify `Picky/PickyAgentProtocol.swift`
- add `contracts/protocol/terminal-control-*.json`
- modify both protocol test suites

**Work:**

- schemas and bounds for workspace instance, terminal incarnation, operation fingerprint/status, capability, event, completion, and errors;
- `addAppCapabilities`/`removeAppCapabilities` while preserving legacy replacement registration;
- fixture names ending in `.request.json` or `.event.json` so both contract harnesses execute them;
- mixed capability registration behavior and additive/optional compatibility.

**Validation:** `test:contracts` plus Swift protocol contract suite.

### Task 8: Add agentd reverse RPC bridge

**Files:**

- modify `agentd/src/server.ts`
- modify `agentd/src/server.test.ts`

**Work:**

- pending request owner, timeout, disconnect, stop, abort, and exactly-once completion;
- additive/removal capability handling without changing legacy replacement semantics;
- recipient-socket, child-session, request/operation ID, and fingerprint correlation;
- operation-status reconciliation and no mutation auto-retry.

**Validation:** focused server tests, typecheck, lint.

### Task 9: Add Swift router handling

**Files:**

- modify `Picky/PickyAgentClient.swift`
- modify `Picky/PickyAgentClientRouter.swift`
- modify `PickyTests/PickyAgentClientTests.swift`
- modify `PickyTests/PickyAgentClientRouterTests.swift`

**Work:**

- decode event;
- verify child connection ownership and child generation;
- invoke workspace handler;
- reply on the same child client;
- add/remove capability only when the default-off local feature gate and handler are ready;
- forward transient disconnect separately from child process exit without regressing older daemon behavior.

**Validation:** client/router suites and protocol contracts.

### Task 10: Add Pickle-only tool

**Files:**

- create `agentd/src/application/terminal-control-tool.ts`
- create `agentd/src/application/terminal-control-tool.test.ts`
- modify `agentd/src/bootstrap.ts`
- update tool settings/user guide only if the tool is user-configurable

**Work:**

- build and test the child-only tool core before registration;
- bounded operation schema including operation-status lookup;
- language-neutral prompt text;
- structured redacted activity/results/errors;
- operationId derived from Pi tool call ID;
- edit `bootstrap.ts` only after router scope tests and Gate 3 integration pass, and keep registration behind the default-off local feature gate.

**Validation:** focused tool/bootstrap tests and agentd typecheck/lint/build.

### Task 11: Race and lifecycle hardening

**Files:**

- extend workspace, router, server, and tool tests

**Work:**

- duplicate in-flight operation and payload mismatch;
- lost acknowledgment and operation-status reconciliation;
- user takeover with queued user/agent bytes at every input path;
- write/close ordering and unresponsive process termination;
- archive or app restart during request;
- transient disconnect, permanent child exit, and stale child-generation callback;
- stale workspace instance, generation, terminal incarnation, and lease;
- waiter registration/settlement races;
- private terminal data non-disclosure across activity, snapshots, persistence, and logs.

**Validation:** targeted suites followed by full serial agentd tests and relevant Swift suites.

### Task 12: Manual acceptance and documentation

**Files:**

- update `docs/user-manual.md`
- update this plan status only after validation

**Work:**

- with explicit approval, run the signed security spike comparing protected-resource behavior of child agentd and an app-owned PTY;
- manually verify multiple terminals, IME, copy/paste, drag/drop, hidden process continuity, permission/controller transitions, archive, and child restart;
- profile Terminal/Artifacts switching and terminal tab selection against the Gate 0 baseline/threshold;
- record resource usage and responsiveness at maximum configured terminal count under sustained/graphical output;
- enable terminal control by default only after automated, security, manual, and performance evidence is approved.

**Constraint:** do not launch/restart the running Picky app or child daemon without explicit user approval.

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
  src/domain/pi-event-normalizer.test.ts \
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

### Active Pickle creates a terminal

1. Keep the active Pickle's utility panel closed or leave it on Artifacts, with keyboard focus in another eligible control.
2. Ask that Pickle to create a terminal and start a long-running process.
3. Confirm the utility panel expands, `Terminal` becomes selected, and the new terminal tab is selected while the prior first responder remains unchanged.
4. Confirm the process started independently of the terminal view mount and retained its output.

### Inactive Pickle creates a terminal

1. Keep another Pickle active and record its panel, selected tab, and first responder.
2. Let an inactive Pickle create a terminal.
3. Confirm the inactive Pickle is not activated and the visible panel/tab/focus state does not change.
4. Later open that Pickle manually and confirm the terminal was already running; no deferred reveal action should fire.

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

Verify Korean IME input, command-arrow/delete line editing, copy/paste, bracketed paste, file drag/drop, Ctrl-C, alternate screen TUIs, and terminal focus routing across terminal-tab switches. Exercise takeover/hand-back while each input source is queued or marked and confirm the final PTY gate sends no stale bytes.

### Signed privilege-boundary spike

With explicit approval to launch a signed test build, run equivalent protected-resource probes from the existing child agentd path and an app-owned PTY. Record the responsible process and observed access without capturing private user data. If the app-owned PTY receives materially broader TCC authority, stop rollout and revisit agentd ownership or a least-privileged helper boundary before enabling Pickle terminal control.

## Observability

Add scalar structured logs for:

- workspace create/revoke/remove with session ID and non-secret instance identifiers;
- terminal create/start/exit/close with session ID, terminal ID, and non-secret incarnation identifier only;
- permission/controller/lease transition;
- request start/finish/error code/latency;
- duplicate operation result reuse;
- stale workspace instance/generation/terminal incarnation/lease rejection;
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
- Agent terminal control is also behind a default-off local feature gate until Gate 5 approval.
- Terminal events are emitted only to clients that added `terminalControl` after the app handler became ready.
- The existing replacement registration remains unchanged; additive/removal commands must not erase legacy capabilities and may be rejected safely by older daemons.
- App and bundled agentd ship together, but contract tests still cover old/new app-daemon combinations, same-socket removal, and reconnect from an empty capability set.

### Rollback

A safe rollback may:

- leave the local feature gate off or return it to off;
- disable child registration of `picky_terminal`;
- remove or stop adding the `terminalControl` capability;
- retain the multi-terminal user UI and app-owned workspaces;
- keep the additive protocol schemas ignored while the capability is absent.

Do not roll back by granting the Pickle unrestricted access to all user terminals or by merging terminal control into generic `pickleBridge` payloads.

## Definition of done

- Utility panel remains exactly Terminal and Artifacts.
- A Pickle can own multiple independent local shell processes.
- User and Pickle can create terminals without unintended focus changes; active-Pickle agent creation reveals the new terminal, while inactive-Pickle creation makes no visible UI change.
- User-created terminals are private by default.
- Shared permission and exclusive controller state are visible and accessible.
- User and Pickle writes cannot merge under tested takeover races.
- Pickle operations are scoped to the owning child session, workspace instance, explicit terminal ID, and terminal incarnation.
- Reads are bounded rendered snapshots with explicit revision/wait semantics and bounded exactly-once waiter ownership.
- User and agent bytes are authorized at the final PTY sink.
- Mutations are workspace-instance/generation/incarnation/lease checked, serialized, fingerprinted, and idempotent by operation ID.
- Unknown mutation outcomes are reconciled through read-only operation status, never blind retry.
- Archive, app restart, disconnect, stale child callback, child exit, duplicate/foreign completion, and lost acknowledgment paths are safe and observable.
- Terminal activity, snapshots, persisted state, logs, and errors contain no terminal input/output or private metadata.
- Protocol schemas, fixtures, Swift decoding, TypeScript validation, and both contract suites agree.
- Existing inline Pi terminal and detached terminal overlay behavior remains intact.
- Targeted tests, full agentd validation, relevant Swift tests, and macOS build pass.
- SwiftTerm is pinned to the characterized revision before feature implementation.
- HUD terminal switching is profiled against an approved baseline/threshold and does not introduce material mount/layout regression.
- Maximum-capacity terminal memory/render soak and signed privilege-boundary results are recorded and approved.
- Manual IME, paste, drag/drop, long-running process, permission, and lifecycle scenarios are recorded.
- Agent terminal control remains default-off until Gate 5 approval.
- The running Picky app or child daemon was not launched/restarted without explicit user approval.

## Technical review record

This design was reviewed from four independent worker perspectives (Swift architecture, concurrency/state machine, agentd/protocol/privacy, and delivery DAG), then independently checked by verifier and challenger roles. Gate 0 remains awaiting explicit user approval; no implementation has started.

Common conclusions:

- app-owned SwiftTerm is the lower-risk v1 backend;
- the feature is a capability/concurrency protocol, not only a tab UI;
- user-created terminals need explicit opt-in;
- process startup must be independent from view mounting;
- resource limits are mandatory;
- archive must revoke before closing;
- raw incremental output should be omitted until it has loss-aware cursor semantics;
- request IDs alone do not provide mutation idempotency;
- user takeover requires a lease/epoch and a final PTY byte-sink gate that invalidates queued user/agent writes;
- workspace instance and terminal incarnation identities are required to prevent app-restart and async-callback ABA;
- terminal tool activity requires pre-preview redaction and integrated persistence canaries;
- foreign socket completions and stale child-generation callbacks must be rejected;
- unknown mutation outcomes need read-only ledger status rather than list/read heuristics;
- capability rollout should use separate additive/removal commands while preserving legacy replacement semantics;
- implementation should proceed through integrated green checkpoints and independent hardening gates.

Residual risk:

- SwiftTerm focus, marked-text, final input-gate, close, and process-tree behavior still require runtime verification against the pinned revision;
- app-owned PTY versus child-agentd TCC authority requires an explicitly approved signed-build comparison;
- memory/render behavior at maximum terminal count and terminal graphics output must be measured;
- read quiet-time defaults may need adjustment against real shells and TUIs;
- mixed app/daemon capability add/remove behavior requires explicit contract tests;
- the concrete feature-gate implementation must remain local-only and non-user-facing until rollout approval.

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
- Verified SwiftTerm local-process source: https://github.com/migueldeicaza/SwiftTerm/blob/86456ca32aaa81cadb4ca8dbe8be4546ffbccd18/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift
- Apple responsible-process/TCC context: https://developer.apple.com/forums/thread/731504
- node-pty official source/docs: https://github.com/microsoft/node-pty
