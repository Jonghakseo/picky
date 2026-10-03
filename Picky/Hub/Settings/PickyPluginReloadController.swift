//
//  PickyPluginReloadController.swift
//  Picky
//
//  Applies plugin changes as soon as an install, update, removal, or MCP
//  change succeeds by sending `reloadPlugins` to picky-agentd. The daemons
//  reload idle sessions right away and busy ones at their next safe point
//  without interrupting them, so the user never has to reload by hand. Each
//  daemon answers with a broadcast `pluginsReloaded` event; this controller
//  merges them to clear the pending state.
//
//  Changes made while a reload is in flight are applied by one more reload
//  after it finishes. Failures are not retried automatically: the View shows
//  the error with a retry action.
//

import Combine
import Foundation

@MainActor
final class PickyPluginReloadController: ObservableObject {
    /// True after the user installs/uninstalls a plugin, until the daemon
    /// confirms a successful `pluginsReloaded`.
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
    private var watchdogTask: Task<Void, Never>?
    private let reloadTimeoutSeconds: TimeInterval
    private var changeGeneration = 0
    private var inFlightGeneration = 0
    private var inFlightCommandId: String?
    /// The last apply failed because the daemon was unreachable, not because a session failed
    /// to reload. Only that kind is re-applied automatically when the daemon reconnects.
    private var lastFailureWasTransport = false
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
        var failedCount: Int = 0
    }

    // Daemons reload every live session one by one; the apply is automatic, so a
    // tight timeout would surface a false failure while the work still finishes.
    init(client: any PickyAgentClient, reloadTimeoutSeconds: TimeInterval = 60) {
        self.client = client
        self.reloadTimeoutSeconds = reloadTimeoutSeconds
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
        watchdogTask?.cancel()
    }

    func installCuratedPackage(source: String) async -> Result<Void, PickyCuratedPluginInstaller.CommandError> {
        await PickyCuratedPluginInstaller.install(source: source, client: client)
    }

    func removeCuratedPackage(source: String) async -> Result<Void, PickyCuratedPluginInstaller.CommandError> {
        await PickyCuratedPluginInstaller.remove(source: source, client: client)
    }

    func checkCuratedPackageUpdates() async -> Result<PickyAvailablePackageUpdates, PickyCuratedPluginInstaller.CommandError> {
        await PickyCuratedPluginInstaller.checkUpdates(client: client)
    }

    func inspectCuratedPackageConflicts(sources: [String]) async -> Result<[PickyPackageConflict], PickyCuratedPluginInstaller.CommandError> {
        await PickyCuratedPluginInstaller.inspectConflicts(sources: sources, client: client)
    }

    func updateCuratedPackage(source: String) async -> Result<Void, PickyCuratedPluginInstaller.CommandError> {
        await PickyCuratedPluginInstaller.update(source: source, client: client)
    }

    func setupCuratedPackage(source: String) async -> Result<Void, PickyCuratedPluginInstaller.CommandError> {
        await PickyCuratedPluginInstaller.setup(source: source, client: client)
    }

    /// The automatic apply failed and the change is still pending; the View
    /// offers a retry. In-flight applies stay silent because they finish fast.
    var needsAttention: Bool {
        hasPendingChanges && !isReloading && lastError != nil
    }

    /// Called by the plugin manager when an install/uninstall completes
    /// successfully. Applies the change right away; a change made while an
    /// apply is in flight is picked up by one more apply when it finishes.
    func notePluginsChanged() {
        changeGeneration += 1
        hasPendingChanges = true
        lastResult = nil
        lastError = nil
        guard !isReloading else { return }
        Task { await reload() }
    }

    /// Send `reloadPlugins` to the daemon. Returns immediately after `send`
    /// resolves; the broadcast `pluginsReloaded` event clears `isReloading`.
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        inFlightGeneration = changeGeneration
        lastError = nil
        lastFailureWasTransport = false
        let command = PickyCommandEnvelope(type: .reloadPlugins)
        let myCommandId = command.id
        inFlightCommandId = myCommandId
        // Capture the upper-bound target count BEFORE awaiting `broadcast` so a
        // fast daemon that replies before `broadcast` returns still finds the
        // aggregation slot ready and merges into it.
        aggregation = ReloadAggregation(
            commandId: myCommandId,
            generationAtStart: inFlightGeneration,
            expectedReplies: client.broadcastTargetCount
        )
        startWatchdog(for: myCommandId)
        do {
            let deliveredCount = try await client.broadcast(command)
            guard inFlightCommandId == myCommandId else { return }
            // Tighten the expected reply count down to what the router
            // actually delivered. If a child daemon's `send` failed, we
            // shouldn't wait forever for an event it never received.
            if var agg = aggregation, agg.commandId == myCommandId {
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
            guard inFlightCommandId == myCommandId else { return }
            cancelWatchdog()
            aggregation = nil
            isReloading = false
            inFlightCommandId = nil
            lastError = error.localizedDescription
            lastFailureWasTransport = true
        }
    }

    private func startWatchdog(for commandId: String) {
        watchdogTask?.cancel()
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        let interval = min(max(0, reloadTimeoutSeconds), maxSeconds)
        let nanos = UInt64(interval * 1_000_000_000)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.timeOutReload(for: commandId) }
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func timeOutReload(for commandId: String) {
        guard isReloading, inFlightCommandId == commandId else { return }
        aggregation = nil
        isReloading = false
        inFlightCommandId = nil
        lastError = L10n.t("status.extensions.reload.error.timeout")
        lastFailureWasTransport = true
        watchdogTask = nil
    }

    /// Publish the aggregated summary and clear in-flight state. Called when
    /// every expected reply has arrived, or when the broadcast delivered to
    /// zero daemons (so there is nothing to wait for).
    private func finishReloadFromAggregation() {
        cancelWatchdog()
        guard let agg = aggregation else { return }
        let summary = PickyPluginsReloadedEvent(
            requestId: agg.commandId,
            pickyReloaded: agg.pickyReloaded,
            pickleReloadedCount: agg.pickleReloadedCount,
            pickleAbortedCount: agg.pickleAbortedCount,
            pickleDeferredCount: agg.pickleDeferredCount,
            failedCount: agg.failedCount
        )
        aggregation = nil
        let changedDuringApply = changeGeneration > inFlightGeneration
        // A session that failed to reload still runs the old plugins: keep the change pending
        // and ask the user to retry instead of looping on a persistent failure.
        hasPendingChanges = changedDuringApply || agg.failedCount > 0
        isReloading = false
        inFlightCommandId = nil
        lastResult = summary
        lastError = agg.failedCount > 0 ? L10n.t("status.extensions.reload.error.sessions") : nil
        if changedDuringApply {
            Task { await reload() }
        }
    }

    private func handle(_ event: PickyClientEvent) {
        switch event {
        case .protocolEvent(let envelope):
            handle(envelope.event)
        case .disconnected:
            guard isReloading else { return }
            cancelWatchdog()
            aggregation = nil
            isReloading = false
            inFlightCommandId = nil
            lastError = L10n.t("status.extensions.reload.error.disconnected")
            lastFailureWasTransport = true
        case .recoverableError(let message):
            guard isReloading else { return }
            cancelWatchdog()
            aggregation = nil
            isReloading = false
            inFlightCommandId = nil
            lastError = message
            lastFailureWasTransport = true
        case .connected:
            // A change that failed to apply because the daemon went away is
            // applied once it is back, without waiting for the user to retry.
            if hasPendingChanges && !isReloading && lastFailureWasTransport {
                Task { await reload() }
            }
        case .sessionProjectionBootstrapCompletion:
            break
        }
    }

    private func handle(_ event: PickyEvent) {
        switch event {
        case .pluginsReloaded(let summary):
            applyReloadedSummary(summary)
        case .error(let errorEvent):
            guard isReloading, errorEvent.commandId == inFlightCommandId else { return }
            cancelWatchdog()
            aggregation = nil
            isReloading = false
            inFlightCommandId = nil
            lastError = errorEvent.message
        default:
            break
        }
    }

    /// Merge an incoming per-daemon summary into the in-flight aggregation.
    private func applyReloadedSummary(_ summary: PickyPluginsReloadedEvent) {
        guard var agg = aggregation else { return }
        if let requestId = summary.requestId, requestId != agg.commandId { return }
        agg.receivedReplies += 1
        if summary.pickyReloaded { agg.pickyReloaded = true }
        agg.pickleReloadedCount += summary.pickleReloadedCount
        agg.pickleAbortedCount += summary.pickleAbortedCount
        agg.pickleDeferredCount += summary.pickleDeferredCount
        agg.failedCount += summary.failedCount ?? 0
        aggregation = agg
        if agg.expectedReplies > 0 && agg.receivedReplies >= agg.expectedReplies {
            finishReloadFromAggregation()
        }
    }
}
