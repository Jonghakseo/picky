import Combine
import Foundation

/// A history snapshot binds visible calls to the Pi file they came from.
struct PickyToolHistorySnapshot: Equatable {
    let tools: [PickyToolActivity]
    let sessionFilePath: String?
}

typealias PickyToolHistoryDetailLoader = @MainActor (
    _ toolCallID: String, _ expectedSessionFile: String,
    _ part: PickyToolHistoryDetailPart, _ cursor: String?
) async throws -> PickyToolHistoryDetailResult

/// Owns only the currently displayed page. Full results never enter the session projection.
@MainActor
final class PickyToolHistoryDetailModel: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle, loading, ready, pending, unavailable, sourceChanged, unsupported, failed
    }

    let id = UUID()
    let toolName: String
    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""
    @Published private(set) var part: PickyToolHistoryDetailPart = .result
    @Published private(set) var pageNumber = 1
    @Published private(set) var attachmentsOmitted = false
    @Published private(set) var canLoadNextPage = false

    private var nextCursor: String?
    private var currentCursor: String?
    private var generation = 0
    private var request: Task<Void, Never>?
    private let loader: @MainActor (PickyToolHistoryDetailPart, String?) async throws -> PickyToolHistoryDetailResult
    private let retryDelay: @MainActor () async throws -> Void

    init(
        toolName: String,
        retryDelay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) },
        loader: @escaping @MainActor (PickyToolHistoryDetailPart, String?) async throws -> PickyToolHistoryDetailResult
    ) {
        self.toolName = toolName
        self.retryDelay = retryDelay
        self.loader = loader
    }

    @discardableResult
    func load(part: PickyToolHistoryDetailPart) -> Task<Void, Never> {
        start(part: part, cursor: nil, page: 1)
    }

    @discardableResult
    func loadNextPage() -> Task<Void, Never>? {
        guard state == .ready, let nextCursor else { return nil }
        return start(part: part, cursor: nextCursor, page: pageNumber + 1)
    }

    @discardableResult
    func retry() -> Task<Void, Never> {
        start(part: part, cursor: currentCursor, page: pageNumber)
    }

    func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        clearPage()
        state = .idle
    }

    func invalidateSource() {
        cancel()
        state = .sourceChanged
    }

    private func start(part: PickyToolHistoryDetailPart, cursor: String?, page: Int) -> Task<Void, Never> {
        guard state != .sourceChanged else { return Task {} }
        cancel()
        let generation = generation
        self.part = part
        currentCursor = cursor
        pageNumber = page
        state = .loading
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.fetch(part: part, cursor: cursor, generation: generation)
        }
        request = task
        return task
    }

    private func fetch(part: PickyToolHistoryDetailPart, cursor: String?, generation: Int) async {
        do {
            for attempt in 0..<3 {
                try Task.checkCancellation()
                let result = try await loader(part, cursor)
                guard self.generation == generation, !Task.isCancelled else { return }
                if result.status == .pending && attempt < 2 {
                    try await retryDelay()
                    continue
                }
                apply(result)
                request = nil
                return
            }
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            state = .failed
            request = nil
        }
    }

    private func apply(_ result: PickyToolHistoryDetailResult) {
        switch result.status {
        case .ready:
            text = result.text ?? ""
            nextCursor = result.nextCursor
            canLoadNextPage = result.nextCursor != nil
            attachmentsOmitted = result.attachmentsOmitted == true
            state = .ready
        case .pending: state = .pending
        case .unavailable: state = .unavailable
        case .sourceChanged: state = .sourceChanged
        case .unsupported: state = .unsupported
        }
    }

    private func clearPage() {
        text = ""
        nextCursor = nil
        canLoadNextPage = false
        attachmentsOmitted = false
    }
}
