import Foundation
import Testing
@testable import Picky

struct PickySettingsPersistenceCoordinatorTests {
    @MainActor
    @Test func workerRunsSettingsMutationOffMainThreadAndPreservesQueuedPatches() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let persistence = PickySettingsPersistenceCoordinator(store: store)

        persistence.enqueue {
            guard !Thread.isMainThread else { throw WorkerTestError.ranOnMainThread }
            $0.appearance = .light
        }
        persistence.enqueue {
            guard !Thread.isMainThread else { throw WorkerTestError.ranOnMainThread }
            $0.cursor.showPiCursor = false
        }
        await persistence.flush()

        let saved = try store.loadStrict()
        #expect(saved.appearance == .light)
        #expect(!saved.cursor.showPiCursor)
    }

    @MainActor
    @Test func durableMutationCompletesAfterAtomicFileWriteAndInvalidJSONFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let persistence = PickySettingsPersistenceCoordinator(store: store)

        let committed = try await persistence.persist {
            $0.notifications.notifyOnCompleted = true
        }
        #expect(committed.notifications.notifyOnCompleted)
        #expect(try store.loadStrict().notifications.notifyOnCompleted)

        let invalid = Data("not json".utf8)
        try invalid.write(to: store.url, options: .atomic)
        do {
            _ = try await persistence.persist { $0.appearance = .light }
            Issue.record("Expected an invalid existing settings file to fail closed")
        } catch {}
        #expect(try Data(contentsOf: store.url) == invalid)
    }

    @MainActor
    @Test func missingSettingsFileUsesDefaultsBeforeApplyingPatch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let persistence = PickySettingsPersistenceCoordinator(store: store)

        let committed = try await persistence.persist { $0.appearance = .light }

        #expect(committed.appearance == .light)
        #expect(try store.loadStrict().appearance == .light)
    }

    @MainActor
    @Test func failedWriteDoesNotEmitSettingsDidSaveNotification() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let persistence = PickySettingsPersistenceCoordinator(store: store)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url, options: .atomic)
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .pickySettingsDidSave,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        persistence.enqueue(notification: .settingsDidSave) { $0.appearance = .light }
        await persistence.flush()

        #expect(notificationCount == 0)
        #expect(try Data(contentsOf: store.url) == Data("not json".utf8))
    }

    @MainActor
    @Test func delayedFirstWritePreservesFIFOAndFlushHighWaterMark() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let gate = TransactionGate()
        let persistence = PickySettingsPersistenceCoordinator(store: store, transactionObserver: { gate.observe() })
        let firstFlush = CallbackLatch()
        let allFlush = CallbackLatch()

        persistence.enqueue { $0.appearance = .light }
        await gate.waitUntilStarted(1)
        persistence.flush { firstFlush.signal() }
        persistence.enqueue { $0.appearance = .dark }

        gate.releaseOne()
        await firstFlush.wait()
        #expect(try store.loadStrict().appearance == .light)

        await gate.waitUntilStarted(2)
        persistence.flush { allFlush.signal() }
        gate.releaseOne()
        await allFlush.wait()
        #expect(try store.loadStrict().appearance == .dark)
    }

    @MainActor
    @Test func quiescentDrainIncludesAdmissionsMadeWhileDrainIsActive() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let gate = TransactionGate()
        let persistence = PickySettingsPersistenceCoordinator(store: store, transactionObserver: { gate.observe() })
        let drainLatch = CallbackLatch()
        var drainSucceeded: Bool?

        persistence.enqueue { $0.appearance = .light }
        await gate.waitUntilStarted(1)
        persistence.drain { result in
            drainSucceeded = (try? result.get()) != nil
            drainLatch.signal()
        }
        persistence.enqueue { $0.cursor.showPiCursor = false }

        gate.releaseOne()
        await gate.waitUntilStarted(2)
        await Task.yield()
        #expect(!drainLatch.isSignaled)

        gate.releaseOne()
        await drainLatch.wait()
        #expect(drainSucceeded == true)
        #expect(!(try store.loadStrict().cursor.showPiCursor))
    }

    @MainActor
    @Test func quiescentDrainReportsWorkerFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url, options: .atomic)
        let persistence = PickySettingsPersistenceCoordinator(store: store)
        let drainLatch = CallbackLatch()
        var drainSucceeded: Bool?

        persistence.enqueue { $0.appearance = .light }
        persistence.drain { result in
            drainSucceeded = (try? result.get()) != nil
            drainLatch.signal()
        }
        await drainLatch.wait()

        #expect(drainSucceeded == false)
        #expect(try Data(contentsOf: store.url) == Data("not json".utf8))
    }

    @MainActor
    @Test func rapidRecentFolderAdmissionsReturnWorkerSnapshotsInOrder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let persistence = PickySettingsPersistenceCoordinator.shared(for: store)
        let recentStore = PickySettingsRecentPickleFolderStore(settingsStore: store)
        var snapshots: [[String]] = []

        recentStore.record(cwd: "/tmp/first") { result in
            if case .success(let recent) = result { snapshots.append(recent) }
        }
        recentStore.record(cwd: "/tmp/second") { result in
            if case .success(let recent) = result { snapshots.append(recent) }
        }
        await persistence.flush()

        #expect(snapshots == [["/tmp/first"], ["/tmp/second", "/tmp/first"]])
        #expect(try store.loadStrict().recentPickleCwds == ["/tmp/second", "/tmp/first"])
    }

    @MainActor
    @Test func durableDockGroupMutationWaitsForSettingsWrite() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = PickySettingsStore(appSupportRoot: root)
        let dockStore = PickySettingsDockLayoutStore(settingsStore: settingsStore)
        let controller = PickySessionDockLayoutController(store: dockStore)

        let groupID = try await controller.createGroupPersisting(name: "Research", withMemberIDs: ["pickle-1"])

        let savedGroup = try #require(settingsStore.loadStrict().dockLayout.group(withID: groupID))
        #expect(savedGroup.memberSessionIDs == ["pickle-1"])
    }

    @MainActor
    @Test func settingsViewModelRebasesEditMadeWhileEarlierSaveIsInFlight() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let gate = TransactionGate()
        let persistence = PickySettingsPersistenceCoordinator(store: store, transactionObserver: { gate.observe() })
        let viewModel = PickySettingsViewModel(store: store, persistence: persistence)

        let firstFlush = CallbackLatch()
        let allFlush = CallbackLatch()
        viewModel.settings.notifications.notifyOnCompleted = true
        viewModel.save()
        await gate.waitUntilStarted(1)
        persistence.flush { firstFlush.signal() }

        viewModel.settings.cursor.showPiCursor = false
        viewModel.save()
        #expect(viewModel.isSaving)

        gate.releaseOne()
        await firstFlush.wait()
        #expect(viewModel.isSaving)
        #expect(viewModel.settings.notifications.notifyOnCompleted)
        #expect(!viewModel.settings.cursor.showPiCursor)
        #expect(try store.loadStrict().cursor.showPiCursor)

        await gate.waitUntilStarted(2)
        persistence.flush { allFlush.signal() }
        gate.releaseOne()
        await allFlush.wait()
        #expect(!viewModel.isSaving)
        #expect(!(try store.loadStrict().cursor.showPiCursor))
    }

    @MainActor
    @Test func settingsViewModelPersistsRapidReversalToDurableValue() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let gate = TransactionGate()
        let persistence = PickySettingsPersistenceCoordinator(store: store, transactionObserver: { gate.observe() })
        let viewModel = PickySettingsViewModel(store: store, persistence: persistence)
        let allFlush = CallbackLatch()

        #expect(viewModel.settings.cursor.showPiCursor)
        viewModel.settings.cursor.showPiCursor = false
        viewModel.save()
        await gate.waitUntilStarted(1)

        viewModel.settings.cursor.showPiCursor = true
        viewModel.save()
        persistence.flush { allFlush.signal() }

        gate.releaseOne()
        await gate.waitUntilStarted(2)
        gate.releaseOne()
        await allFlush.wait()

        #expect(try store.loadStrict().cursor.showPiCursor)
    }

    @MainActor
    @Test func settingsViewModelPreservesNewerExternalLeafDuringOverlappingSave() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickySettingsStore(appSupportRoot: root)
        let gate = TransactionGate()
        let persistence = PickySettingsPersistenceCoordinator(store: store, transactionObserver: { gate.observe() })
        let viewModel = PickySettingsViewModel(store: store, persistence: persistence)
        let allFlush = CallbackLatch()

        viewModel.settings.cursor.showPiCursor = false
        viewModel.save()
        await gate.waitUntilStarted(1)

        persistence.enqueue { $0.cursor.showPiCursor = true }
        viewModel.settings.appearance = .light
        viewModel.save()
        persistence.flush { allFlush.signal() }

        gate.releaseOne()
        await gate.waitUntilStarted(2)
        gate.releaseOne()
        await gate.waitUntilStarted(3)
        gate.releaseOne()
        await allFlush.wait()

        let committed = try store.loadStrict()
        #expect(committed.cursor.showPiCursor)
        #expect(committed.appearance == .light)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private enum WorkerTestError: Error {
        case ranOnMainThread
    }
}

private final class TransactionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let permits = DispatchSemaphore(value: 0)
    private var startedCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func observe() {
        lock.lock()
        startedCount += 1
        let ready = waiters.filter { $0.count <= startedCount }
        waiters.removeAll { $0.count <= startedCount }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
        permits.wait()
    }

    func waitUntilStarted(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if startedCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func releaseOne() {
        permits.signal()
    }
}

@MainActor
private final class CallbackLatch {
    private(set) var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }
}
