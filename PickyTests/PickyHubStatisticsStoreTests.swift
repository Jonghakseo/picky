import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyHubStatisticsStoreTests {
    @Test func resetAppliesTheCorrelatedSnapshotRatherThanAnUnrelatedReply() async {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run {
                client.emit(Self.reply(commandID: "unrelated", ok: false, error: "wrong reply"))
                client.emit(Self.reply(commandID: command.id))
            }
        }
        let store = PickyHubStatisticsStore(client: client)
        await store.resetClassifications()
        #expect(store.state == .loaded(.empty))
        #expect(store.isResetting == false)
        #expect(store.lastRefreshedAt != nil)
        #expect(client.sentCommands.map(\.type) == [.resetHubStatistics])
    }

    @Test func resetReportsDaemonRejectionWithoutWaitingForTimeout() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            client.emit(.protocolEvent(PickyEventEnvelope(
                id: "rejection", protocolVersion: pickyAgentProtocolVersion, timestamp: Date(),
                event: .error(PickyErrorEvent(code: "UNAVAILABLE", message: "Statistics unavailable", commandId: command.id))
            )))
        }
        let store = PickyHubStatisticsStore(client: client, timeoutNanoseconds: 10_000_000_000)
        try await withPickyTestTimeout("statistics rejection", timeout: .seconds(2)) {
            await store.resetClassifications()
        }
        #expect(store.state == .failed("Statistics unavailable"))
        #expect(!store.isResetting)
    }

    @Test func resetSurfacesConnectionLoss() async {
        let client = FakePickyAgentClient()
        client.beforeSend = { _ in client.disconnect() }
        let store = PickyHubStatisticsStore(client: client)
        await store.resetClassifications()
        #expect(store.state == .failed(PickyHubStatisticsStore.FetchError.disconnected.localizedDescription))
        #expect(!store.isResetting)
    }

    @Test func resetDoesNotSendDuplicateCommandsWhilePending() async throws {
        let client = FakePickyAgentClient()
        let store = PickyHubStatisticsStore(client: client)
        let first = Task { await store.resetClassifications() }
        try await waitUntil(timeoutMs: 2_000) { client.sentCommands.count == 1 }
        let command = try #require(client.sentCommands.first)
        await store.resetClassifications()
        store.refresh()
        #expect(client.sentCommands.count == 1)
        client.emit(Self.reply(commandID: command.id))
        await first.value
        #expect(store.state == .loaded(.empty))
        #expect(!store.isResetting)
    }

    @Test func resetTimesOutAndClearsBusyState() async {
        let store = PickyHubStatisticsStore(client: FakePickyAgentClient(), timeoutNanoseconds: 1_000_000)
        await store.resetClassifications()
        #expect(store.state == .failed(PickyHubStatisticsStore.FetchError.timedOut.localizedDescription))
        #expect(!store.isResetting)
    }

    @Test func classificationToggleAppliesOnlyItsCorrelatedDaemonSnapshot() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run {
                switch command.type {
                case .getHubStatistics:
                    client.emit(Self.reply(commandID: command.id, snapshot: Self.snapshot(classificationEnabled: false)))
                case .configureHubStatistics:
                    client.emit(Self.reply(commandID: "unrelated", snapshot: Self.snapshot(classificationEnabled: true)))
                    client.emit(Self.reply(commandID: command.id, snapshot: Self.snapshot(classificationEnabled: true)))
                default:
                    break
                }
            }
        }
        let store = PickyHubStatisticsStore(client: client)
        store.refresh()
        try await waitUntil(timeoutMs: 2_000) { !store.isRefreshing }

        await store.setClassificationEnabled(true)

        #expect(store.classificationEnabled)
        #expect(!store.isUpdatingClassification)
        #expect(store.classificationUpdateError == nil)
        #expect(client.sentCommands.map(\.type) == [.getHubStatistics, .configureHubStatistics])
        #expect(client.sentCommands.last?.classificationEnabled == true)
    }

    @Test func failedClassificationToggleKeepsTheLastConfirmedConsentAndShowsError() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run {
                if command.type == .getHubStatistics {
                    client.emit(Self.reply(commandID: command.id, snapshot: Self.snapshot(classificationEnabled: false)))
                } else if command.type == .configureHubStatistics {
                    client.emit(Self.reply(commandID: command.id, ok: false, error: "Could not save consent"))
                }
            }
        }
        let store = PickyHubStatisticsStore(client: client)
        store.refresh()
        try await waitUntil(timeoutMs: 2_000) { !store.isRefreshing }

        await store.setClassificationEnabled(true)

        #expect(!store.classificationEnabled)
        #expect(store.classificationUpdateError == "Could not save consent")
        #expect(!store.isUpdatingClassification)
    }

    @Test func refreshAndResetCannotSupersedeAnInFlightConsentUpdate() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run {
                if command.type == .getHubStatistics {
                    client.emit(Self.reply(commandID: command.id, snapshot: Self.snapshot(classificationEnabled: true)))
                }
            }
        }
        let store = PickyHubStatisticsStore(client: client)
        store.refresh()
        try await waitUntil(timeoutMs: 2_000) { !store.isRefreshing }
        let update = Task { await store.setClassificationEnabled(false) }
        try await waitUntil(timeoutMs: 2_000) { client.sentCommands.count == 2 }
        let command = try #require(client.sentCommands.last)
        store.refresh()
        store.refreshIfNeeded()
        await store.resetClassifications()
        #expect(client.sentCommands.count == 2)
        #expect(store.isUpdatingClassification)
        client.emit(Self.reply(commandID: command.id, snapshot: Self.snapshot(classificationEnabled: false)))
        await update.value
        #expect(!store.isUpdatingClassification)
        #expect(!store.classificationEnabled)
    }

    @Test func failedRefreshDoesNotPresentPreviouslyEnabledClassificationAsOff() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run {
                client.emit(Self.reply(commandID: command.id, snapshot: Self.snapshot(classificationEnabled: true)))
            }
        }
        let store = PickyHubStatisticsStore(client: client)
        store.refresh()
        try await waitUntil(timeoutMs: 2_000) { !store.isRefreshing }
        client.beforeSend = { command in
            await MainActor.run { client.emit(Self.reply(commandID: command.id, ok: false, error: "Unavailable")) }
        }
        store.refresh()
        try await waitUntil(timeoutMs: 2_000) { !store.isRefreshing }
        #expect(store.classificationEnabled)
        #expect(store.state.snapshot == nil)
    }

    @Test func successfulSnapshotsRefreshAfterTheirFreshnessWindowWithoutDuplicatingInflightRequests() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run { client.emit(Self.reply(commandID: command.id)) }
        }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PickyHubStatisticsStore(client: client, freshnessInterval: 30, now: { now })
        store.refreshIfNeeded()
        store.refreshIfNeeded()
        try await waitUntil(timeoutMs: 2_000) { !store.isRefreshing }
        #expect(client.sentCommands.count == 1)
        now.addTimeInterval(29)
        store.refreshIfNeeded()
        #expect(client.sentCommands.count == 1)
        now.addTimeInterval(2)
        store.refreshIfNeeded()
        try await waitUntil(timeoutMs: 2_000) { client.sentCommands.count == 2 && !store.isRefreshing }
        #expect(store.lastRefreshedAt == now)
    }

    @Test func statisticsPollingRunsOnlyForVisibleStatisticsSurfaces() {
        let navigator = PickyHubNavigator()
        #expect(!navigator.shouldRefreshStatistics)
        navigator.isWindowVisible = true
        #expect(navigator.shouldRefreshStatistics)
        navigator.select(.settings)
        #expect(!navigator.shouldRefreshStatistics)
        navigator.select(.statistics)
        #expect(navigator.shouldRefreshStatistics)
        navigator.isWindowVisible = false
        #expect(!navigator.shouldRefreshStatistics)
    }

    private func waitUntil(timeoutMs: Int, _ condition: @escaping @MainActor () -> Bool) async throws {
        try await withPickyTestTimeout("statistics command sent", timeout: .milliseconds(timeoutMs)) {
            while !(await condition()) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private static func snapshot(classificationEnabled: Bool) -> PickyHubStatisticsSnapshot {
        PickyHubStatisticsSnapshot(
            generatedAt: Date(),
            records: [],
            usageSamples: [],
            pendingClassificationCount: 0,
            classificationEnabled: classificationEnabled
        )
    }

    private static func reply(
        commandID: String,
        ok: Bool = true,
        error: String? = nil,
        snapshot: PickyHubStatisticsSnapshot? = nil
    ) -> PickyClientEvent {
        .protocolEvent(PickyEventEnvelope(
            id: UUID().uuidString, protocolVersion: pickyAgentProtocolVersion, timestamp: Date(),
            event: .hubStatisticsResult(PickyHubStatisticsResultEvent(
                commandId: commandID,
                ok: ok,
                errorMessage: error,
                snapshot: ok ? snapshot ?? .empty : nil
            ))
        ))
    }
}
