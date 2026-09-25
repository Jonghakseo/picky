import Observation

/// Detail omission is unavailable, never evidence that no execution remains.
@MainActor
@Observable
final class PickySessionAsyncTaskStore {
    private(set) var detailState: PickyProjectionSectionState<PickyAsyncTaskDetail> = .unavailable
    private(set) var controlState: PickyProjectionSectionState<PickyAsyncControlState> = .unavailable

    func replace(tasks: [PickyAsyncTask]?, tickets: [PickyCompletionTicket]?, control: PickyAsyncControlState?) {
        if let tasks, let tickets {
            replaceDetail(.init(tasks: tasks, tickets: tickets))
        } else {
            replaceDetail(nil)
        }
        replaceControl(control)
    }

    func replaceDetail(_ detail: PickyAsyncTaskDetail?) {
        detailState = detail.map(PickyProjectionSectionState.loaded) ?? .unavailable
    }

    func replaceControl(_ control: PickyAsyncControlState?) {
        controlState = control.map(PickyProjectionSectionState.loaded) ?? .unavailable
    }
}
