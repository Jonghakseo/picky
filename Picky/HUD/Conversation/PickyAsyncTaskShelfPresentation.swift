import Foundation

/// Identity remains stable across progress/revision updates and distinct across provider restarts.
struct PickyAsyncTaskShelfIdentity: Hashable {
    let owner: PickyAsyncTaskOwner
    let taskID: String

    init(_ task: PickyAsyncTask) {
        owner = task.owner
        taskID = task.taskId
    }
}

enum PickyAsyncTaskShelfAction {
    case cancel(owner: PickyAsyncTaskOwner, taskID: String)
}

/// Supplied by the command owner. The view never derives provider support from a task's kind.
enum PickyAsyncTaskCancelAvailability: Equatable {
    case available
    case unsupported
    case unavailable(String)
    case pending
    case failed(String)

    var isAvailable: Bool { self == .available }

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
    }

    static func isVisible(summary: PickyAsyncWorkSummary, detail: PickyProjectionSectionState<PickyAsyncTaskDetail>) -> Bool {
        if summary.tracking != .ready || summary.activeRootCount > 0 || summary.pendingCompletionCount > 0
            || summary.uncertainExecutionCount > 0 || summary.attentionCount > 0 { return true }
        switch detail {
        case .unavailable: return true
        case .loaded(let value): return !roots(in: value).isEmpty
        }
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

    static func executionKey(_ task: PickyAsyncTask) -> String {
        if task.presence == .unknown { return "hud.asyncTasks.execution.unknown" }
        return "hud.asyncTasks.execution.\(task.execution.rawValue)"
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
