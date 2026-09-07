//
//  PickyHubStatisticsStore.swift
//  Picky
//
//  Fetches the unfiltered statistics snapshot from picky-agentd
//  (`getHubStatistics` -> `hubStatisticsResult`) and caches it for the
//  dashboard and statistics page. The daemon owns aggregation; this store
//  only owns loading/error state and the shared filter.
//

import Combine
import Foundation

@MainActor
final class PickyHubStatisticsStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(PickyHubStatisticsSnapshot)
        case failed(String)

        var snapshot: PickyHubStatisticsSnapshot? {
            if case .loaded(let snapshot) = self { return snapshot }
            return nil
        }
    }

    enum FetchError: LocalizedError, Equatable {
        case failed(String)
        case timedOut
        case disconnected

        var errorDescription: String? {
            switch self {
            case .failed(let message): message
            case .timedOut: L10n.t("hub.stats.error.timedOut")
            case .disconnected: L10n.t("hub.stats.error.disconnected")
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// Filter shared by the dashboard summary and the statistics page so both
    /// always describe the same slice.
    @Published var filter = PickyHubStatisticsFilter()
    @Published private(set) var isResetting = false
    @Published private(set) var lastRefreshedAt: Date?

    private let client: any PickyAgentClient
    private var refreshTask: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    init(client: any PickyAgentClient, timeoutNanoseconds: UInt64 = 30_000_000_000) {
        self.client = client
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    var snapshot: PickyHubStatisticsSnapshot { state.snapshot ?? .empty }
    var isLoading: Bool { state == .loading }

    func refreshIfNeeded() {
        guard state == .idle || state.isFailed else { return }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        if state.snapshot == nil { state = .loading }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.request(type: .getHubStatistics)
            guard !Task.isCancelled else { return }
            self.apply(result)
        }
    }

    /// Wipes the daemon-side classification cache and reloads.
    func resetClassifications() async {
        isResetting = true
        defer { isResetting = false }
        let result = await request(type: .resetHubStatistics)
        apply(result)
    }

    private func apply(_ result: Result<PickyHubStatisticsSnapshot, FetchError>) {
        switch result {
        case .success(let snapshot):
            state = .loaded(snapshot)
            lastRefreshedAt = Date()
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    private func request(type: PickyCommandType) async -> Result<PickyHubStatisticsSnapshot, FetchError> {
        let command = PickyCommandEnvelope(type: type)
        let stream = client.events
        do {
            try await client.send(command)
            let snapshot = try await withThrowingTaskGroup(of: PickyHubStatisticsSnapshot.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            guard case .hubStatisticsResult(let result) = envelope.event, result.commandId == command.id else { continue }
                            guard result.ok, let snapshot = result.snapshot else {
                                throw FetchError.failed(result.errorMessage ?? L10n.t("hub.stats.error.generic"))
                            }
                            return snapshot
                        case .disconnected:
                            throw FetchError.disconnected
                        case .connected, .sessionProjectionBootstrapCompletion, .recoverableError:
                            continue
                        }
                    }
                    throw FetchError.disconnected
                }
                group.addTask { [timeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    try Task.checkCancellation()
                    throw FetchError.timedOut
                }
                guard let first = try await group.next() else { throw FetchError.disconnected }
                return first
            }
            return .success(snapshot)
        } catch let error as FetchError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}

private extension PickyHubStatisticsStore.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
