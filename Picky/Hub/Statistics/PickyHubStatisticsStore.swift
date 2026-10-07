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
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUpdatingClassification = false
    @Published private(set) var classificationUpdateError: String?
    @Published private(set) var classificationEnabled = false
    @Published private(set) var lastRefreshedAt: Date?
    /// Badges already earned, kept so a badge never disappears once shown.
    @Published private(set) var earnedBadges: [PickyHubBadgeKind: Date] = [:]

    private let client: any PickyAgentClient
    private var refreshTask: Task<Void, Never>?
    private var requestGeneration = 0
    private let timeoutNanoseconds: UInt64
    private let now: () -> Date
    private let freshnessInterval: TimeInterval
    private let defaults: UserDefaults
    static let earnedBadgesKey = "PickyHubEarnedBadges"

    init(
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        freshnessInterval: TimeInterval = 30,
        defaults: UserDefaults = PickyRuntimeEnvironment.userDefaults,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.timeoutNanoseconds = timeoutNanoseconds
        self.freshnessInterval = freshnessInterval
        self.defaults = defaults
        self.now = now
        earnedBadges = Self.loadEarnedBadges(from: defaults)
    }

    var snapshot: PickyHubStatisticsSnapshot { state.snapshot ?? .empty }
    var isLoading: Bool { state == .loading }

    func refreshIfNeeded() {
        guard !isRefreshing, !isResetting, !isUpdatingClassification else { return }
        let isStale = lastRefreshedAt.map { now().timeIntervalSince($0) >= freshnessInterval } ?? true
        guard state == .idle || state.isFailed || isStale else { return }
        refresh()
    }

    func refresh() {
        guard !isResetting, !isUpdatingClassification else { return }
        refreshTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        isRefreshing = true
        if state.snapshot == nil { state = .loading }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.request(type: .getHubStatistics)
            guard !Task.isCancelled, self.requestGeneration == generation else { return }
            self.apply(result)
            self.isRefreshing = false
        }
    }

    /// Reset owns the snapshot until the daemon replies; earlier refreshes
    /// cannot replace the reset result and repeated clicks send no command.
    func resetClassifications() async {
        guard !isResetting, !isUpdatingClassification else { return }
        classificationUpdateError = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        requestGeneration += 1
        isResetting = true
        defer { isResetting = false }
        let result = await request(type: .resetHubStatistics)
        apply(result)
    }

    /// The toggle remains bound to the last daemon-confirmed snapshot. A failed
    /// command therefore never renders an optimistic consent state.
    func setClassificationEnabled(_ enabled: Bool) async {
        guard !isResetting, !isUpdatingClassification else { return }
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        requestGeneration += 1
        let generation = requestGeneration
        isUpdatingClassification = true
        classificationUpdateError = nil
        defer { isUpdatingClassification = false }

        let result = await request(type: .configureHubStatistics, classificationEnabled: enabled)
        guard requestGeneration == generation, !Task.isCancelled else { return }
        switch result {
        case .success:
            apply(result)
        case .failure(let error):
            classificationUpdateError = error.localizedDescription
            // A lost reply may follow a committed update. Hide the toggle until
            // a fresh snapshot confirms the durable value, rather than claiming off.
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(_ result: Result<PickyHubStatisticsSnapshot, FetchError>) {
        switch result {
        case .success(let snapshot):
            state = .loaded(snapshot)
            classificationEnabled = snapshot.classificationEnabled
            lastRefreshedAt = now()
            recordEarnedBadges(from: snapshot)
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    private func request(
        type: PickyCommandType,
        classificationEnabled: Bool? = nil
    ) async -> Result<PickyHubStatisticsSnapshot, FetchError> {
        let command = PickyCommandEnvelope(type: type, classificationEnabled: classificationEnabled)
        let stream = client.events
        do {
            try await client.send(command)
            let snapshot = try await withThrowingTaskGroup(of: PickyHubStatisticsSnapshot.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            if case .error(let error) = envelope.event, error.commandId == command.id {
                                throw FetchError.failed(error.message)
                            }
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

extension PickyHubStatisticsStore {
    /// Adds newly earned badges and keeps every earlier date. Writes only on change.
    private func recordEarnedBadges(from snapshot: PickyHubStatisticsSnapshot) {
        let board = PickyHubBadgePolicy.board(snapshot: snapshot, earned: earnedBadges, now: now())
        var next = earnedBadges
        for badge in board.badges {
            guard let earnedAt = badge.earnedAt else { continue }
            next[badge.kind] = min(next[badge.kind] ?? earnedAt, earnedAt)
        }
        guard next != earnedBadges else { return }
        earnedBadges = next
        defaults.set(
            Dictionary(uniqueKeysWithValues: next.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
            forKey: Self.earnedBadgesKey
        )
    }

    private static func loadEarnedBadges(from defaults: UserDefaults) -> [PickyHubBadgeKind: Date] {
        let stored = defaults.dictionary(forKey: earnedBadgesKey) as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            PickyHubBadgeKind(rawValue: key).map { ($0, Date(timeIntervalSince1970: value)) }
        })
    }
}

private extension PickyHubStatisticsStore.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
