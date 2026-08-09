import Foundation

/// Generation-safe stale-while-revalidate cache for background Git status probes.
///
/// The cache owns only immutable status values and timestamps. It never retains
/// views, sessions, or callbacks. Duplicate callers for the same cwd/generation
/// share one loader invocation; invalidation advances the generation and wakes
/// old waiters so stale completions cannot repopulate the cache or publish into
/// the current UI.
final class PickyGitRepositoryStatusRefreshCache: @unchecked Sendable {
    typealias Clock = @Sendable () -> TimeInterval
    typealias Loader = @Sendable (_ cwd: String?) async -> PickyGitRepositoryStatus?

    private struct Entry {
        let value: PickyGitRepositoryStatus?
        let refreshedAt: TimeInterval
        let generation: UInt64
    }

    private struct RefreshKey: Hashable {
        let cwd: String
        let generation: UInt64
    }

    private enum RefreshOutcome {
        case value(PickyGitRepositoryStatus?)
        case retry
    }

    private let lock = NSLock()
    private let clock: Clock
    private let loader: Loader
    private var entries: [String: Entry] = [:]
    private var generations: [String: UInt64] = [:]
    private var waiters: [RefreshKey: [CheckedContinuation<RefreshOutcome, Never>]] = [:]

    init(
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        loader: @escaping Loader
    ) {
        self.clock = clock
        self.loader = loader
    }

    func cached(cwd: String?) -> PickyGitRepositoryStatus? {
        guard let key = Self.cacheKey(cwd: cwd) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.value
    }

    func load(cwd: String?, maximumAge: TimeInterval) async -> PickyGitRepositoryStatus? {
        guard let key = Self.cacheKey(cwd: cwd) else { return nil }
        while true {
            guard !Task.isCancelled else { return nil }
            switch await refreshOnce(cwd: cwd, key: key, maximumAge: maximumAge) {
            case .value(let value):
                return value
            case .retry:
                continue
            }
        }
    }

    func prefetchIfNeeded(cwd: String?) {
        guard let key = Self.cacheKey(cwd: cwd) else { return }
        lock.lock()
        let generation = generations[key, default: 0]
        let alreadyAvailable = entries[key]?.generation == generation
        let alreadyRefreshing = waiters[RefreshKey(cwd: key, generation: generation)] != nil
        lock.unlock()
        guard !alreadyAvailable, !alreadyRefreshing else { return }

        Task { [self] in
            _ = await load(cwd: cwd, maximumAge: .greatestFiniteMagnitude)
        }
    }

    func inFlightWaiterCount(cwd: String?) -> Int {
        guard let key = Self.cacheKey(cwd: cwd) else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return waiters
            .filter { $0.key.cwd == key }
            .reduce(0) { $0 + $1.value.count }
    }

    func invalidate(cwd: String?) {
        guard let key = Self.cacheKey(cwd: cwd) else { return }
        lock.lock()
        generations[key, default: 0] &+= 1
        entries.removeValue(forKey: key)
        let staleRefreshKeys = waiters.keys.filter { $0.cwd == key }
        let staleWaiters = staleRefreshKeys.flatMap { waiters.removeValue(forKey: $0) ?? [] }
        lock.unlock()

        // Resume outside the lock. Each caller loops and either joins or starts
        // the new generation, while the old subprocess may finish harmlessly.
        staleWaiters.forEach { $0.resume(returning: .retry) }
    }

    private func refreshOnce(
        cwd: String?,
        key: String,
        maximumAge: TimeInterval
    ) async -> RefreshOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            let generation = generations[key, default: 0]
            if maximumAge > 0,
               let entry = entries[key],
               entry.generation == generation,
               max(0, clock() - entry.refreshedAt) <= maximumAge {
                let value = entry.value
                lock.unlock()
                continuation.resume(returning: .value(value))
                return
            }

            let refreshKey = RefreshKey(cwd: key, generation: generation)
            if waiters[refreshKey] != nil {
                waiters[refreshKey, default: []].append(continuation)
                lock.unlock()
                return
            }

            waiters[refreshKey] = [continuation]
            lock.unlock()

            Task { [self] in
                let value = await loader(cwd)
                complete(refreshKey: refreshKey, value: value)
            }
        }
    }

    private func complete(refreshKey: RefreshKey, value: PickyGitRepositoryStatus?) {
        lock.lock()
        guard let refreshWaiters = waiters.removeValue(forKey: refreshKey) else {
            lock.unlock()
            return
        }
        let isCurrentGeneration = generations[refreshKey.cwd, default: 0] == refreshKey.generation
        if isCurrentGeneration {
            entries[refreshKey.cwd] = Entry(
                value: value,
                refreshedAt: clock(),
                generation: refreshKey.generation
            )
        }
        lock.unlock()

        let outcome: RefreshOutcome = isCurrentGeneration ? .value(value) : .retry
        refreshWaiters.forEach { $0.resume(returning: outcome) }
    }

    private static func cacheKey(cwd: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmedCwd).standardizedFileURL.path
    }
}
