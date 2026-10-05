//
//  PickyUsageLimitsStore.swift
//  Picky
//
//  Owns subscription plan limits for the whole app. Polls the primary daemon
//  every five minutes (sooner after a failure), refreshes immediately on a
//  manual request, and remembers which providers the user pinned to the menu
//  bar. The Hub cards, menu bar items, and HUD context popover all read this
//  one store so they never disagree.
//

import Combine
import Foundation

@MainActor
final class PickyUsageLimitsStore: ObservableObject {
    static let pollInterval: TimeInterval = 5 * 60
    static let retryInterval: TimeInterval = 30
    private static let pinnedProvidersKey = "picky.usageLimits.menuBarProviders"

    @Published private(set) var snapshot: PickyUsageLimitsSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var pinnedProviders: Set<PickyUsageLimitsProviderID>

    /// Set by the app: opens Hub > Statistics > AI usage.
    var openUsageInHub: (() -> Void)?

    private let client: any PickyAgentClient
    private let defaults: UserDefaults
    private let timeoutNanoseconds: UInt64
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var pollTask: Task<Void, Never>?
    private var requestGeneration = 0

    init(
        client: any PickyAgentClient,
        defaults: UserDefaults = PickyRuntimeEnvironment.userDefaults,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.client = client
        self.defaults = defaults
        self.timeoutNanoseconds = timeoutNanoseconds
        self.sleep = sleep
        let stored = defaults.stringArray(forKey: Self.pinnedProvidersKey) ?? []
        pinnedProviders = Set(stored.compactMap(PickyUsageLimitsProviderID.init(rawValue:)))
    }

    /// Subscribed providers in display order.
    var providers: [PickyUsageLimitsProvider] {
        let providers = snapshot?.providers ?? []
        return PickyUsageLimitsProviderID.allCases.compactMap { id in providers.first { $0.provider == id } }
    }

    func provider(_ id: PickyUsageLimitsProviderID) -> PickyUsageLimitsProvider? {
        snapshot?.provider(id)
    }

    /// Pinned providers that currently have limits to show, in display order.
    var menuBarProviders: [PickyUsageLimitsProvider] {
        providers.filter { pinnedProviders.contains($0.provider) }
    }

    func isPinned(_ id: PickyUsageLimitsProviderID) -> Bool {
        pinnedProviders.contains(id)
    }

    func setPinned(_ pinned: Bool, for id: PickyUsageLimitsProviderID) {
        var next = pinnedProviders
        if pinned { next.insert(id) } else { next.remove(id) }
        guard next != pinnedProviders else { return }
        pinnedProviders = next
        defaults.set(PickyUsageLimitsProviderID.allCases.filter(next.contains).map(\.rawValue), forKey: Self.pinnedProvidersKey)
    }

    /// Starts the five-minute poll. The first check runs immediately.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let succeeded = await self.load(force: false)
                let delay = succeeded ? Self.pollInterval : Self.retryInterval
                do { try await self.sleep(delay) } catch { return }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Manual refresh: bypasses the daemon's short reuse window.
    func refresh() {
        Task { await load(force: true) }
    }

    @discardableResult
    func load(force: Bool) async -> Bool {
        requestGeneration += 1
        let generation = requestGeneration
        isRefreshing = true
        let result = await request(force: force)
        guard generation == requestGeneration else { return (try? result.get()) != nil }
        isRefreshing = false
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            lastErrorMessage = nil
            return true
        case .failure(let error):
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private enum FetchError: LocalizedError {
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

    private func request(force: Bool) async -> Result<PickyUsageLimitsSnapshot, FetchError> {
        var command = PickyCommandEnvelope(type: .getUsageLimits)
        command.force = force
        let stream = client.events
        do {
            try await client.send(command)
            let snapshot = try await withThrowingTaskGroup(of: PickyUsageLimitsSnapshot.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            if case .error(let error) = envelope.event, error.commandId == command.id {
                                throw FetchError.failed(error.message)
                            }
                            guard case .usageLimitsResult(let result) = envelope.event, result.commandId == command.id else { continue }
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
