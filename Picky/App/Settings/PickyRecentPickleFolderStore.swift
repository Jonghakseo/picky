import Foundation

@MainActor
protocol PickyRecentPickleFolderStoring {
    var recentPickleCwds: [String] { get }
    var pinnedPickleCwds: [String] { get }
    func record(cwd: String, completion: @escaping @MainActor (Result<[String], Error>) -> Void)
    func remove(cwd: String, completion: @escaping @MainActor (Result<[String], Error>) -> Void)
    func pin(cwd: String, completion: @escaping @MainActor (Result<(pinned: [String], recent: [String]), Error>) -> Void)
    func unpin(cwd: String, completion: @escaping @MainActor (Result<(pinned: [String], recent: [String]), Error>) -> Void)
    func reorderPinned(cwds: [String], completion: @escaping @MainActor (Result<[String], Error>) -> Void)
}

@MainActor
struct PickyNoopRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    nonisolated init() {}

    var recentPickleCwds: [String] { [] }
    var pinnedPickleCwds: [String] { [] }
    func record(cwd: String, completion: @escaping @MainActor (Result<[String], Error>) -> Void) { completion(.success([])) }
    func remove(cwd: String, completion: @escaping @MainActor (Result<[String], Error>) -> Void) { completion(.success([])) }
    func pin(cwd: String, completion: @escaping @MainActor (Result<(pinned: [String], recent: [String]), Error>) -> Void) { completion(.success(([], []))) }
    func unpin(cwd: String, completion: @escaping @MainActor (Result<(pinned: [String], recent: [String]), Error>) -> Void) { completion(.success(([], []))) }
    func reorderPinned(cwds: [String], completion: @escaping @MainActor (Result<[String], Error>) -> Void) { completion(.success([])) }
}

/// Admits every mutation synchronously into the shared settings FIFO. UI state
/// is updated only from the committed worker snapshot, so rapid actions cannot
/// project a stale on-disk snapshot while earlier writes are queued.
@MainActor
struct PickySettingsRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    var settingsStore: PickySettingsStore = PickySettingsStore()

    private var persistence: PickySettingsPersistenceCoordinator {
        .shared(for: settingsStore)
    }

    var recentPickleCwds: [String] {
        settingsStore.load().recentPickleCwds
    }

    var pinnedPickleCwds: [String] {
        settingsStore.load().pinnedPickleCwds
    }

    func record(cwd: String, completion: @escaping @MainActor (Result<[String], Error>) -> Void) {
        persistence.enqueue(
            mutation: { $0.recordRecentPickleCwd(cwd) },
            completion: { completion($0.map(\.recentPickleCwds)) }
        )
    }

    func remove(cwd: String, completion: @escaping @MainActor (Result<[String], Error>) -> Void) {
        persistence.enqueue(
            mutation: { $0.removeRecentPickleCwd(cwd) },
            completion: { completion($0.map(\.recentPickleCwds)) }
        )
    }

    func pin(cwd: String, completion: @escaping @MainActor (Result<(pinned: [String], recent: [String]), Error>) -> Void) {
        persistence.enqueue(
            mutation: { $0.pinPickleCwd(cwd) },
            completion: { completion($0.map { ($0.pinnedPickleCwds, $0.recentPickleCwds) }) }
        )
    }

    func unpin(cwd: String, completion: @escaping @MainActor (Result<(pinned: [String], recent: [String]), Error>) -> Void) {
        persistence.enqueue(
            mutation: { $0.unpinPickleCwd(cwd) },
            completion: { completion($0.map { ($0.pinnedPickleCwds, $0.recentPickleCwds) }) }
        )
    }

    func reorderPinned(cwds: [String], completion: @escaping @MainActor (Result<[String], Error>) -> Void) {
        persistence.enqueue(
            mutation: { $0.reorderPinnedPickleCwds(cwds) },
            completion: { completion($0.map(\.pinnedPickleCwds)) }
        )
    }
}
