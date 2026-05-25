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
    private var changeGeneration = 0
    private var inFlightGeneration = 0
    private var inFlightCommandId: String?
    /// Running aggregation for the in-flight reload. Picky's router fans the
    /// `reloadPlugins` command out to the primary daemon and every active
    /// child daemon, so we receive one `pluginsReloaded` event per daemon.
    /// We hold the partial sums here until every expected reply has arrived
    /// (or the broadcast delivered to zero daemons), then publish the merged
    /// summary as `lastResult` so the banner shows totals across all daemons.
    private var aggregation: ReloadAggregation?

    private struct ReloadAggregation {
        let commandId: String
        let generationAtStart: Int
        var expectedReplies: Int
        var receivedReplies: Int = 0
        var pickyReloaded: Bool = false
        var pickleReloadedCount: Int = 0
        var pickleAbortedCount: Int = 0
        var pickleDeferredCount: Int = 0
    }

    init(client: any PickyAgentClient) {
        self.client = client
        let stream = client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                await MainActor.run { [weak self] in
                    self?.handle(event)
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
        changeGeneration += 1
        hasPendingChanges = true
        lastResult = nil
        lastError = nil
    }

    /// Send `reloadPlugins` to the daemon. Returns immediately after `send`
    /// resolves; the broadcast `pluginsReloaded` event clears `isReloading`.
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        inFlightGeneration = changeGeneration
        lastError = nil
        let command = PickyCommandEnvelope(type: .reloadPlugins)
        inFlightCommandId = command.id
        // Capture the upper-bound target count BEFORE awaiting `broadcast` so a
        // fast daemon that replies before `broadcast` returns still finds the
        // aggregation slot ready and merges into it.
        aggregation = ReloadAggregation(
            commandId: command.id,
            generationAtStart: inFlightGeneration,
            expectedReplies: client.broadcastTargetCount
        )
        do {
            let deliveredCount = try await client.broadcast(command)
            // Tighten the expected reply count down to what the router
            // actually delivered. If a child daemon's `send` failed, we
            // shouldn't wait forever for an event it never received.
            if var agg = aggregation, agg.commandId == command.id {
                agg.expectedReplies = deliveredCount
                aggregation = agg
                if deliveredCount == 0 || agg.receivedReplies >= deliveredCount {
                    finishReloadFromAggregation()
                }
            }
            // `isReloading` stays true until every daemon confirms via
            // `pluginsReloaded`. If a daemon never answers (disconnect),
            // the .disconnected / .recoverableError handlers release it.
        } catch {
            aggregation = nil
            isReloading = false
            inFlightCommandId = nil
            lastError = error.localizedDescription
        }
    }

    /// Publish the aggregated summary and clear in-flight state. Called when
    /// every expected reply has arrived, or when the broadcast delivered to
    /// zero daemons (so there is nothing to wait for).
    private func finishReloadFromAggregation() {
        guard let agg = aggregation else { return }
        let summary = PickyPluginsReloadedEvent(
            pickyReloaded: agg.pickyReloaded,
            pickleReloadedCount: agg.pickleReloadedCount,
            pickleAbortedCount: agg.pickleAbortedCount,
            pickleDeferredCount: agg.pickleDeferredCount
        )
        aggregation = nil
        hasPendingChanges = changeGeneration > inFlightGeneration
        isReloading = false
        inFlightCommandId = nil
        lastResult = summary
        lastError = nil
    }

    private func handle(_ event: PickyClientEvent) {
        switch event {
        case .protocolEvent(let envelope):
            handle(envelope.event)
        case .disconnected:
            guard isReloading else { return }
            isReloading = false
            inFlightCommandId = nil
            lastError = L10n.t("status.extensions.reload.error.disconnected")
        case .recoverableError(let message):
            guard isReloading else { return }
            isReloading = false
            inFlightCommandId = nil
            lastError = message
        case .connected:
            break
        }
    }

    private func handle(_ event: PickyEvent) {
        switch event {
        case .pluginsReloaded(let summary):
            applyReloadedSummary(summary)
        case .error(let errorEvent):
            guard isReloading, errorEvent.commandId == inFlightCommandId else { return }
            aggregation = nil
            isReloading = false
            inFlightCommandId = nil
            lastError = errorEvent.message
        default:
            break
        }
    }

    /// Merge an incoming per-daemon summary into the in-flight aggregation.
    /// When no aggregation is active (legacy path, out-of-band event after the
    /// controller already settled) we fall back to publishing the summary as-is
    /// so older tests and any future single-daemon clients keep their behavior.
    private func applyReloadedSummary(_ summary: PickyPluginsReloadedEvent) {
        guard var agg = aggregation else {
            hasPendingChanges = changeGeneration > inFlightGeneration
            isReloading = false
            inFlightCommandId = nil
            lastResult = summary
            lastError = nil
            return
        }
        agg.receivedReplies += 1
        if summary.pickyReloaded { agg.pickyReloaded = true }
        agg.pickleReloadedCount += summary.pickleReloadedCount
        agg.pickleAbortedCount += summary.pickleAbortedCount
        agg.pickleDeferredCount += summary.pickleDeferredCount
        aggregation = agg
        if agg.expectedReplies > 0 && agg.receivedReplies >= agg.expectedReplies {
            finishReloadFromAggregation()
        }
    }
}
