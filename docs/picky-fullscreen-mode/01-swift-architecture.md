# 01. Swift architecture

Status: design only.

## Architecture principles

1. **Single source of truth**: fullscreen reads from the existing `PickySessionListViewModel`. Do not create a second session model.
2. **Coordinator owns AppKit lifecycle**: SwiftUI views must not create, retain, or close AppKit windows directly.
3. **Views are pure renderers**: SwiftUI views receive state and closures. They do not perform session selection side effects except through injected actions.
4. **Protocol seams at UI boundaries**: use small protocols for HUD visibility, fullscreen state persistence, and AppKit window coordination.
5. **Strong ownership for windows**: fullscreen window must be retained by a coordinator/window controller. No `weak var window`.
6. **Main actor isolation**: windowing, view-model observation, and UI state changes are `@MainActor`.
7. **No speculative abstraction**: create only seams required to safely coordinate HUD/fullscreen mode, composer lifecycle, and tests.

## Recommended module tree

```text
Picky/Fullscreen/
  PickyFullscreenCoordinator.swift
  PickyFullscreenWindowController.swift
  PickyFullscreenWindow.swift
  PickyFullscreenModeController.swift
  PickyFullscreenStateStore.swift

  Views/
    PickyFullscreenWorkspaceView.swift
    PickyFullscreenSidebarView.swift
    PickyFullscreenConversationPaneView.swift
    PickyFullscreenConversationListView.swift
    PickyFullscreenTurnView.swift
    PickyFullscreenChangedFilesCardView.swift
    PickyFullscreenWorkInfoPanelView.swift
    PickyFullscreenHeaderView.swift

  Domain/
    PickyFullscreenSessionSelection.swift
    PickyFullscreenTurnPolicy.swift
    PickyFullscreenAssistantRunResolver.swift
    PickyFullscreenWorkInfoSnapshot.swift
```

Use subfolders only if project organization allows them in Xcode without churn. If Xcode project edits become too noisy, keep the same logical names under `Picky/Fullscreen/` first.

## Responsibility map

| Module | Responsibility | Must not do |
| --- | --- | --- |
| `PickyFullscreenCoordinator` | Public API: `open(sessionID:)`, `close()`, `toggle(sessionID:)`; orchestrates mode transition | Render SwiftUI details; mutate sessions |
| `PickyFullscreenWindowController` | Owns `PickyFullscreenWindow`, hosts SwiftUI root, handles close notifications | Decide business rules; hide HUD directly without coordinator |
| `PickyFullscreenWindow` | `NSWindow` subclass, fullscreen/window style, `PickyScreenCaptureExcludedWindow` conformance | Store session state |
| `PickyFullscreenModeController` | Tiny state machine for dock/fullscreen visibility sequencing | Own AppKit windows |
| `PickyFullscreenStateStore` | Persist selected session and right-panel visibility | Store session content |
| `PickyFullscreenWorkspaceView` | Top-level layout composition | Directly access AppKit or run side effects |
| `PickyFullscreenSidebarView` | Pickle list, local selection, new Pickle affordance | Call undocumented global selection APIs accidentally |
| `PickyFullscreenConversationPaneView` | Header, conversation scroll, drop target, composer slot | Reimplement composer behavior |
| `PickyFullscreenConversationListView` | Render message groups according to turn policy | Choose final answer ad hoc |
| `PickyFullscreenTurnPolicy` | Deterministic current/completed turn rendering policy | Depend on SwiftUI |
| `PickyFullscreenAssistantRunResolver` | Effective model/thinking fallback from current run or messages | Cycle model/thinking |
| `PickyFullscreenWorkInfoPanelView` | Read-only `작업 정보` panel | Invent unavailable data |
| `PickyFullscreenWorkInfoSnapshot` | View-ready projection of existing session data | Fetch external data |

## Public coordinator API

```swift
@MainActor
protocol PickyFullscreenCoordinating: AnyObject {
    func open(sessionID: String?)
    func close()
    func toggle(sessionID: String?)
}

@MainActor
final class PickyFullscreenCoordinator: NSObject, PickyFullscreenCoordinating {
    private let viewModel: PickySessionListViewModel
    private let stateStore: PickyFullscreenStateStore
    private let hudVisibility: PickyHUDVisibilityControlling
    private var windowController: PickyFullscreenWindowController?

    func open(sessionID: String?) { /* orchestrate only */ }
    func close() { /* orchestrate only */ }
    func toggle(sessionID: String?) { /* orchestrate only */ }
}
```

The coordinator is the only object that knows both HUD visibility and fullscreen window lifecycle.

## HUD visibility seam

```swift
@MainActor
protocol PickyHUDVisibilityControlling: AnyObject {
    var isHUDVisibleForFullscreen: Bool { get }
    func hideForFullscreen()
    func restoreAfterFullscreen()
}
```

Implementation can live in or wrap `PickyHUDOverlayManager`.

Requirements:

- hiding HUD must unmount compact card/composer before fullscreen composer mounts
- restore must happen after fullscreen composer unmounts
- operation should be idempotent
- no session cancellation

## Window ownership best practice

Prefer a retained `NSWindowController` over a bare retained `NSWindow`:

```swift
@MainActor
final class PickyFullscreenWindowController: NSWindowController, NSWindowDelegate {
    private let rootViewModel: PickySessionListViewModel
    private let stateStore: PickyFullscreenStateStore
    private let onClose: () -> Void

    init(rootViewModel: PickySessionListViewModel, stateStore: PickyFullscreenStateStore, onClose: @escaping () -> Void) {
        let window = PickyFullscreenWindow()
        self.rootViewModel = rootViewModel
        self.stateStore = stateStore
        self.onClose = onClose
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: makeRootView())
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

final class PickyFullscreenWindow: NSWindow, PickyScreenCaptureExcludedWindow {}
```

Why:

- AppKit has clear lifecycle expectations around `NSWindowController`.
- Strong ownership is explicit.
- Close handling is localized.
- Tests can instantiate coordinator with fake HUD visibility and fake state store.

A direct strong `private var window: PickyFullscreenWindow?` is acceptable only if simpler and consistently handled. A weak reference is not acceptable.

## Mode transition state machine

Represent presentation mode explicitly to avoid hidden boolean coupling:

```swift
enum PickyPresentationMode: Equatable {
    case dock
    case transitioningToFullscreen(sessionID: String?)
    case fullscreen(sessionID: String?)
    case transitioningToDock
}
```

This enum can initially be internal to `PickyFullscreenModeController`. It should not become a global app store unless another feature needs it.

Transition order:

```text
open(sessionID)
  guard mode == .dock else focus existing fullscreen
  mode = .transitioningToFullscreen(sessionID)
  resolve session
  hudVisibility.hideForFullscreen()
  create/show window controller
  mode = .fullscreen(resolvedSessionID)

window close / close()
  guard mode is fullscreen else return
  mode = .transitioningToDock
  save state
  release window controller
  hudVisibility.restoreAfterFullscreen()
  mode = .dock
```

## SwiftUI view design

Use dependency injection through initializer parameters. Avoid environment globals unless the project already standardizes on them.

Good shape:

```swift
struct PickyFullscreenWorkspaceView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    @ObservedObject var stateStore: PickyFullscreenStateStore

    let actions: PickyFullscreenActions

    var body: some View { ... }
}

struct PickyFullscreenActions {
    var close: () -> Void
    var selectFullscreenSession: (String) -> Void
    var submitFollowUp: (String, String) -> Void
    var cycleModelForward: (String) -> Void
    var cycleModelBackward: (String) -> Void
    var cycleThinkingLevel: (String) -> Void
}
```

Rules:

- no `AnyView` unless required by API constraints
- no business logic in `body`
- extract derived state into small pure helpers
- keep animations scoped with explicit `value:`
- avoid implicit animations on entire workspace/session arrays
- keep Markdown rendering inside row views, not parent layout

## Domain helpers

### `PickyFullscreenTurnPolicy`

Pure helper that decides what to render.

```swift
struct PickyFullscreenTurnPolicy {
    func groups(from session: PickySessionListViewModel.SessionCard) -> [PickyFullscreenTurnGroup]
    func finalAnswerMessage(for group: PickyTurnGroup) -> PickySessionMessage?
    func visibleMessages(for group: PickyTurnGroup, isCurrent: Bool, isRunning: Bool) -> [PickySessionMessage]
}
```

Rules:

- running/current turn may show live activity and progress
- completed/non-current turn shows final assistant answer only
- final answer selector prefers last `agent_text`, then last `agent_error`
- completion/failure system messages are separate status rows
- do not blindly use `PickyTurnGroup.collapsedRepresentativeMessage`

### `PickyFullscreenAssistantRunResolver`

```swift
struct PickyFullscreenAssistantRunResolver {
    func effectiveAssistantRun(for session: PickySessionListViewModel.SessionCard) -> PickyAssistantRun? {
        session.currentAssistantRun ?? session.messages.reversed().compactMap(\.assistantRun).first
    }
}
```

Use this for model/thinking display so restored/completed sessions still show metadata.

### `PickyFullscreenWorkInfoSnapshot`

A view-ready projection, not a new data source.

```swift
struct PickyFullscreenWorkInfoSnapshot: Equatable {
    var status: PickyAgentSessionStatus
    var updatedAt: Date
    var notifyMainOnCompletion: Bool
    var runtime: RuntimeSummary
    var contextUsage: PickyContextUsage?
    var activity: ActivitySummary?
    var tools: [PickyToolInvocation]
    var changedFiles: [PickyChangedFile]
    var artifacts: [PickyArtifact]
    var pendingInput: PendingInputSummary
}
```

Every field must be derived from `SessionCard`.

## Persistence

```swift
@MainActor
final class PickyFullscreenStateStore: ObservableObject {
    @Published var selectedSessionID: String?
    @Published var isWorkInfoPanelVisible: Bool
}
```

Backed by `UserDefaults` or existing app settings store.

MVP persistence:

- selected fullscreen session ID
- right-panel visibility
- optional window frame if cheap

Do not persist session content here.

## Testing strategy by architecture

- Pure helpers get fast unit tests.
- Coordinator gets tests with fake HUD visibility and fake window factory if practical.
- Views get compile/build coverage and focused snapshot/manual QA first.
- Avoid testing AppKit fullscreen behavior only through brittle UI tests.

## Anti-patterns

Avoid:

- `weak var window`
- hidden global booleans for presentation mode
- duplicate `PickyConversationComposerView` instances for one session
- reimplementing composer logic
- right panel data fetched from current desktop context
- hard-coded model/thinking fallback logic in multiple views
- broad `.animation(...)` on the whole workspace
- session mutation during UI mode transitions
