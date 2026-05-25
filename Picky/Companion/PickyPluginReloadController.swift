//
//  PickyPluginReloadController.swift
//  Picky
//
//  Owns the "pending plugin reload" state for the plugin manager and exposes
//  a single async action that sends `reloadPlugins` to picky-agentd. The
//  daemon answers with a broadcast `pluginsReloaded` event; this controller
//  listens for it on the shared agent client to clear the pending flag and
//  surface a summary the View can render.
//
//  The controller is intentionally minimal:
//    * No knowledge of session counts. The View computes busy snapshots from
//      `PickySessionListViewModel` and `CompanionManager` so the controller
//      stays decoupled from those view models.
//    * No retries. A failed `send` clears `isReloading` and stores the error
//      so the View can show it; the user re-clicks Reload.
//

import Combine
import Foundation

@MainActor
final class PickyPluginReloadController: ObservableObject {
    /// True after the user installs/uninstalls a plugin, until the daemon
    /// confirms a successful `pluginsReloaded`. The View uses this to gate the
    /// reload banner on the plugin page header.
    @Published private(set) var hasPendingChanges = false
    /// True while a reload is in flight. Disables the Reload button so a
    /// double-click cannot enqueue two reloads.
    @Published private(set) var isReloading = false
    /// Last summary received from the daemon, used to render a toast after the
    /// reload completes. Cleared when the user makes a new plugin change.
    @Published private(set) var lastResult: PickyPluginsReloadedEvent?
    /// Last transport error encountered while sending `reloadPlugins`. The
    /// pluginsReloaded event clears it on success.
    @Published private(set) var lastError: String?

    private let client: any PickyAgentClient
    private var eventTask: Task<Void, Never>?

    init(client: any PickyAgentClient) {
        self.client = client
        let stream = client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard case .protocolEvent(let envelope) = event,
                      case .pluginsReloaded(let summary) = envelope.event else { continue }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hasPendingChanges = false
                    self.isReloading = false
                    self.lastResult = summary
                    self.lastError = nil
                }
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    /// Called by the plugin manager when an install/uninstall completes
    /// successfully. Idempotent: re-noting while the banner is already showing
    /// just keeps it visible.
    func notePluginsChanged() {
        hasPendingChanges = true
        lastResult = nil
        lastError = nil
    }

    /// Send `reloadPlugins` to the daemon. Returns immediately after `send`
    /// resolves; the broadcast `pluginsReloaded` event clears `isReloading`.
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        lastError = nil
        do {
            try await client.send(PickyCommandEnvelope(type: .reloadPlugins))
            // `isReloading` stays true until the daemon confirms via
            // `pluginsReloaded`. If the daemon never answers (disconnect),
            // the next event-loop tick of `connect`/`disconnect` should
            // surface the failure through the regular error channel; we
            // do NOT clear `isReloading` here on the optimistic path.
        } catch {
            isReloading = false
            lastError = error.localizedDescription
        }
    }
}
