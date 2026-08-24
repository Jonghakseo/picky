//
//  PickySettingsPersistenceCoordinator.swift
//  Picky
//
//  Process-wide admission boundary for settings.json writes. AppKit-facing
//  callers stay on the main actor; all file work runs on one serial queue.
//

import Foundation

extension PickySettingsStore {
    /// Loads the current settings without treating an unreadable existing file
    /// as defaults. Writers use this so a corrupt file is never overwritten.
    func loadStrict() throws -> PickySettings {
        let appSupportRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        guard fileManager.fileExists(atPath: url.path) else {
            return .defaults(appSupportRoot: appSupportRoot)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PickySettings.self, from: data)
    }
}

@MainActor
final class PickySettingsPersistenceCoordinator {
    enum NotificationPolicy {
        case none
        case settingsDidSave
    }

    typealias Mutation = (inout PickySettings) throws -> Void

    typealias Completion = @MainActor (Result<PickySettings, Error>) -> Void
    typealias DrainCompletion = @MainActor (Result<Void, Error>) -> Void

    private struct Admission {
        let notificationPolicy: NotificationPolicy
        let continuation: CheckedContinuation<PickySettings, Error>?
        let completion: Completion?
    }

    private static var coordinators: [URL: PickySettingsPersistenceCoordinator] = [:]

    /// Returns the one coordinator for a settings path. This lets default-built
    /// auxiliary presenters share production ordering while temp stores used by
    /// tests remain isolated.
    static func shared(for store: PickySettingsStore = PickySettingsStore()) -> PickySettingsPersistenceCoordinator {
        let key = store.url.standardizedFileURL
        if let existing = coordinators[key] { return existing }
        let coordinator = PickySettingsPersistenceCoordinator(store: store)
        coordinators[key] = coordinator
        return coordinator
    }

    private struct DrainWaiter {
        var firstError: Error?
        let completion: DrainCompletion
    }

    private let worker: Worker
    private var nextTicket: UInt64 = 0
    private var completedTicket: UInt64 = 0
    private var completions: [UInt64: Admission] = [:]
    private var flushWaiters: [(watermark: UInt64, completion: @MainActor () -> Void)] = []
    private var drainWaiters: [DrainWaiter] = []

    init(
        store: PickySettingsStore,
        transactionObserver: @escaping () -> Void = {}
    ) {
        self.worker = Worker(store: store, transactionObserver: transactionObserver)
    }

    /// Admits a mutation before returning. Its file transaction is FIFO with
    /// every other mutation for this coordinator, but callers need not await it.
    @discardableResult
    func enqueue(
        notification: NotificationPolicy = .none,
        mutation: @escaping Mutation,
        completion: Completion? = nil
    ) -> UInt64 {
        admit(notification: notification, continuation: nil, completion: completion, mutation: mutation)
    }

    /// Completes only after the worker has validated, encoded, and atomically
    /// written this mutation. Notification delivery remains main-actor bound.
    func persist(
        notification: NotificationPolicy = .none,
        mutation: @escaping Mutation
    ) async throws -> PickySettings {
        try await withCheckedThrowingContinuation { continuation in
            _ = admit(notification: notification, continuation: continuation, completion: nil, mutation: mutation)
        }
    }

    var hasPendingWork: Bool {
        completedTicket < nextTicket
    }

    /// Registers a completion for exactly the work admitted before this call.
    /// The registration itself is synchronous, so a later admission cannot
    /// extend this high-water mark.
    func flush(completion: @escaping @MainActor () -> Void) {
        let watermark = nextTicket
        guard completedTicket < watermark else {
            completion()
            return
        }
        flushWaiters.append((watermark, completion))
    }

    /// Async convenience for callers that need to await a fixed high-water
    /// boundary. This reports completion regardless of individual results;
    /// durable callers receive their own error from `persist`.
    func flush() async {
        await withCheckedContinuation { continuation in
            flush { continuation.resume() }
        }
    }

    /// Waits until the coordinator becomes quiescent, including mutations
    /// admitted while the drain is active. Unlike `flush`, a worker failure
    /// during this drain is returned so clean termination can be cancelled.
    func drain(completion: @escaping DrainCompletion) {
        guard hasPendingWork else {
            completion(.success(()))
            return
        }
        drainWaiters.append(DrainWaiter(firstError: nil, completion: completion))
    }

    private func admit(
        notification: NotificationPolicy,
        continuation: CheckedContinuation<PickySettings, Error>?,
        completion: Completion?,
        mutation: @escaping Mutation
    ) -> UInt64 {
        nextTicket += 1
        let ticket = nextTicket
        completions[ticket] = Admission(notificationPolicy: notification, continuation: continuation, completion: completion)
        worker.submit(ticket: ticket, mutation: mutation) { [weak self] ticket, result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(ticket, result: result)
                }
            }
        }
        return ticket
    }

    private func finish(_ ticket: UInt64, result: Result<PickySettings, Error>) {
        guard let admission = completions.removeValue(forKey: ticket) else { return }
        // The worker is FIFO, and its main-queue callbacks retain that order.
        completedTicket = ticket
        switch result {
        case .success(let settings):
            if admission.notificationPolicy == .settingsDidSave {
                NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
            }
            admission.continuation?.resume(returning: settings)
        case .failure(let error):
            PickyLog.notice(
                .sessionUI,
                prefix: "⚠️ Picky settings persistence failed",
                message: "ticket=\(ticket) error=\(error.localizedDescription)"
            )
            admission.continuation?.resume(throwing: error)
            for index in drainWaiters.indices where drainWaiters[index].firstError == nil {
                drainWaiters[index].firstError = error
            }
        }
        admission.completion?(result)
        let ready = flushWaiters.filter { $0.watermark <= completedTicket }
        flushWaiters.removeAll { $0.watermark <= completedTicket }
        ready.forEach { $0.completion() }

        if !hasPendingWork, !drainWaiters.isEmpty {
            let readyDrains = drainWaiters
            drainWaiters.removeAll()
            readyDrains.forEach { waiter in
                if let error = waiter.firstError {
                    waiter.completion(.failure(error))
                } else {
                    waiter.completion(.success(()))
                }
            }
        }
    }

    private final class Worker {
        private let store: PickySettingsStore
        private let transactionObserver: () -> Void
        private let queue = DispatchQueue(label: "com.jonghakseo.picky.settings.persistence", qos: .utility)

        init(store: PickySettingsStore, transactionObserver: @escaping () -> Void) {
            self.store = store
            self.transactionObserver = transactionObserver
        }

        func submit(
            ticket: UInt64,
            mutation: @escaping Mutation,
            completion: @escaping (UInt64, Result<PickySettings, Error>) -> Void
        ) {
            queue.async { [store, transactionObserver] in
                let result = Result { () throws -> PickySettings in
                    transactionObserver()
                    var latest = try store.loadStrict()
                    try mutation(&latest)
                    try store.save(latest)
                    return latest.normalizedPaths()
                }
                completion(ticket, result)
            }
        }
    }
}
