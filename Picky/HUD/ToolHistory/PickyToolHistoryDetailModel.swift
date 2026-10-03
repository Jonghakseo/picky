import Combine
import Foundation

/// A history snapshot binds visible calls to the Pi file they came from.
struct PickyToolHistorySnapshot: Equatable {
    let tools: [PickyToolActivity]
    let sessionFilePath: String?
    let workingDirectory: String?

    init(tools: [PickyToolActivity], sessionFilePath: String?, workingDirectory: String? = nil) {
        self.tools = tools
        self.sessionFilePath = sessionFilePath
        self.workingDirectory = workingDirectory
    }
}

typealias PickyToolHistoryDetailLoader = @MainActor (
    _ toolCallID: String, _ expectedSessionFile: String,
    _ part: PickyToolHistoryDetailPart, _ cursor: String?
) async throws -> PickyToolHistoryDetailResult

/// Owns on-demand detail text. Full results never enter the session projection.
@MainActor
final class PickyToolHistoryDetailModel: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle, loading, ready, pending, unavailable, sourceChanged, unsupported, failed
    }

    let id = UUID()
    let toolName: String
    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""
    @Published private(set) var structuredResult: String?
    @Published private(set) var part: PickyToolHistoryDetailPart = .result
    @Published private(set) var pageNumber = 1
    @Published private(set) var attachmentsOmitted = false
    @Published private(set) var canLoadNextPage = false

    let loadsAllPages: Bool
    private var nextCursor: String?
    private var currentCursor: String?
    private var generation = 0
    private var request: Task<Void, Never>?
    private let loader: @MainActor (PickyToolHistoryDetailPart, String?) async throws -> PickyToolHistoryDetailResult
    private let retryDelay: @MainActor () async throws -> Void

    init(
        toolName: String,
        loadsAllPages: Bool = false,
        retryDelay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) },
        loader: @escaping @MainActor (PickyToolHistoryDetailPart, String?) async throws -> PickyToolHistoryDetailResult
    ) {
        self.toolName = toolName
        self.loadsAllPages = loadsAllPages
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
        // Index eviction or daemon restart can invalidate a continuation. Start fresh
        // instead of trapping the user in a loop with the same rejected cursor.
        if loadsAllPages || state == .unavailable { return load(part: part) }
        return start(part: part, cursor: currentCursor, page: pageNumber)
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
            var cursor = cursor
            var combined = ""
            var omitted = false
            var structured: String?
            repeat {
                var result: PickyToolHistoryDetailResult?
                for attempt in 0..<3 {
                    try Task.checkCancellation()
                    let response = try await loader(part, cursor)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    result = response
                    if response.status == .pending && attempt < 2 {
                        try await retryDelay()
                    } else {
                        break
                    }
                }
                guard let result else { return }
                if loadsAllPages && result.status == .ready {
                    combined += result.text ?? ""
                    if cursor == nil { structured = result.structuredResult }
                    omitted = omitted || result.attachmentsOmitted == true
                    cursor = result.nextCursor
                    if cursor != nil { continue }
                    apply(result)
                    text = combined
                    attachmentsOmitted = omitted
                    structuredResult = structured
                } else {
                    apply(result)
                }
                request = nil
                return
            } while true
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
            structuredResult = result.structuredResult
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
        structuredResult = nil
        nextCursor = nil
        canLoadNextPage = false
        attachmentsOmitted = false
    }
}
