import Foundation

/// Identity remains stable across progress/revision updates and distinct across provider restarts.
struct PickyAsyncTaskShelfIdentity: Hashable {
    let owner: PickyAsyncTaskOwner
    let taskID: String

    init(owner: PickyAsyncTaskOwner, taskID: String) {
        self.owner = owner
        self.taskID = taskID
    }

    init(_ task: PickyAsyncTask) {
        owner = task.owner
        taskID = task.taskId
    }
}

enum PickyAsyncTaskShelfAction {
    case cancel(owner: PickyAsyncTaskOwner, taskID: String)
    case detail(owner: PickyAsyncTaskOwner, taskID: String)
}

/// Supplied by the command owner. The view never derives provider support from a task's kind.
enum PickyAsyncTaskCancelAvailability: Equatable {
    case available
    case unsupported
    case unavailable(String)
    case pending
    case failed(String)

    var isAvailable: Bool {
        switch self {
        case .available, .failed: true // Keep the rejected/unknown result visible while allowing an explicit retry.
        case .unsupported, .unavailable, .pending: false
        }
    }

    var explanation: String? {
        switch self {
        case .available: nil
        case .unsupported: L10n.t("hud.asyncTasks.cancelUnsupported")
        case .unavailable(let reason), .failed(let reason): reason
        case .pending: L10n.t("hud.asyncTasks.cancelPending")
        }
    }
}

enum PickyAsyncTaskShelfPresentation {
    static func roots(in detail: PickyAsyncTaskDetail) -> [PickyAsyncTask] {
        detail.tasks.filter { $0.taskId == $0.rootTaskId && $0.parentTaskId == nil }
            .filter { root in
                let members = members(of: root, in: detail)
                return members.contains { hasWork($0) || $0.execution == .failed || $0.execution == .interrupted }
                    || hasPendingResult(root, in: detail)
            }
            .sorted { left, right in
                let leftCurrent = members(of: left, in: detail).contains(where: hasWork) || hasPendingResult(left, in: detail)
                let rightCurrent = members(of: right, in: detail).contains(where: hasWork) || hasPendingResult(right, in: detail)
                if leftCurrent != rightCurrent { return leftCurrent }
                return left.createdAt > right.createdAt
            }
    }

    static func isVisible(summary: PickyAsyncWorkSummary, detail: PickyProjectionSectionState<PickyAsyncTaskDetail>) -> Bool {
        if summary.tracking != .ready || summary.activeRootCount > 0 || summary.pendingCompletionCount > 0
            || summary.uncertainExecutionCount > 0 || summary.attentionCount > 0 { return true }
        switch detail {
        case .unavailable: return true
        case .loaded(let value): return !roots(in: value).isEmpty
        }
    }

    private static func hasWork(_ task: PickyAsyncTask) -> Bool {
        task.presence != .settled || [.queued, .running, .cancelling].contains(task.execution)
            || [.reserved, .approved].contains(task.registration)
    }

    private static func hasPendingResult(_ root: PickyAsyncTask, in detail: PickyAsyncTaskDetail) -> Bool {
        tickets(for: root, in: detail).contains { $0.state != .handled && $0.state != .suppressed }
    }

    /// A detail fetch may add provider notes, but it never owns current lifecycle or ticket state.
    static func supplementalLines(for root: PickyAsyncTask, in fetched: PickyAsyncTaskDetail?) -> [String] {
        guard let fetchedRoot = fetched?.tasks.first(where: { $0.shelfIdentity == root.shelfIdentity }),
              fetchedRoot.providerRevision == root.providerRevision,
              fetchedRoot.controlGeneration == root.controlGeneration,
              fetchedRoot.updatedAt == root.updatedAt else { return detailLines(root) }
        var enriched = root
        enriched.details = fetchedRoot.details ?? root.details
        return detailLines(enriched)
    }

    static func members(of root: PickyAsyncTask, in detail: PickyAsyncTaskDetail) -> [PickyAsyncTask] {
        detail.tasks.filter { $0.owner == root.owner && $0.rootTaskId == root.taskId }
    }

    static func tickets(for root: PickyAsyncTask, in detail: PickyAsyncTaskDetail) -> [PickyCompletionTicket] {
        detail.tickets.filter { $0.owner == root.owner && $0.rootTaskId == root.taskId }
    }

    static func canCancel(_ root: PickyAsyncTask, in detail: PickyAsyncTaskDetail,
                          summary: PickyAsyncWorkSummary, availability: PickyAsyncTaskCancelAvailability) -> Bool {
        guard summary.tracking == .ready, availability.isAvailable,
              root.parentTaskId == nil, root.taskId == root.rootTaskId else { return false }
        return members(of: root, in: detail).contains {
            $0.execution != .cancelling && ($0.presence != .settled || [.reserved, .approved].contains($0.registration))
        } && root.execution != .cancelling
    }

    static func detailLines(_ task: PickyAsyncTask) -> [String] {
        (task.details ?? [:]).keys.sorted().compactMap { key in
            guard let value = task.details?[key] else { return nil }
            let text: String
            if case .string(let string) = value { text = string }
            else if let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) {
                text = json
            } else { return nil }
            return "\(key): \(text)"
        }
    }

    static func executionKey(_ task: PickyAsyncTask) -> String {
        if task.presence == .unknown { return "hud.asyncTasks.execution.unknown" }
        return "hud.asyncTasks.execution.\(task.execution.rawValue)"
    }

    static func primaryStateKey(_ root: PickyAsyncTask, tickets: [PickyCompletionTicket]) -> String {
        if root.presence == .settled, root.execution == .succeeded, let result = resultKey(tickets) { return result }
        return executionKey(root)
    }

    static func resultKey(_ tickets: [PickyCompletionTicket]) -> String? {
        if tickets.contains(where: { $0.state == .failed || $0.state == .unknown }) {
            return "hud.asyncTasks.result.failed"
        }
        if tickets.contains(where: { $0.state == .processing }) { return "hud.asyncTasks.result.processing" }
        if tickets.contains(where: { [.pending, .submitted, .observed].contains($0.state) }) {
            return "hud.asyncTasks.result.pending"
        }
        return nil
    }
}
