//
//  PickySessionNotificationPolicy.swift
//  Picky
//
//  Notification eligibility and dedupe-key policy for Pickle sessions.
//  Notification copy is localized through an injectable closure so tests and
//  callers can keep the decision rules independent from global locale state.
//

struct PickySessionNotificationPolicy {
    struct Input: Equatable {
        struct PendingRequest: Equatable {
            var id: String
            var title: String?
            var prompt: String?
        }

        var sessionID: String
        var title: String
        var status: PickySessionStatus
        var lastSummary: String = ""
        var pendingRequest: PendingRequest?
        var pinned: Bool = false
    }

    struct Notification: Equatable {
        var key: String
        var title: String
        var body: String
    }

    static func notification(
        for input: Input,
        preferences: PickyNotificationPreferences,
        localizer: (String) -> String = { L10n.t($0) }
    ) -> Notification? {
        switch input.status {
        case .completed:
            guard !input.pinned else { return nil }
            guard preferences.notifyOnCompleted else { return nil }
            return Notification(
                key: "\(input.sessionID):completed",
                title: localizer("notif.session.completed.title"),
                body: input.lastSummary.isEmpty ? input.title : input.lastSummary
            )
        case .failed:
            guard preferences.notifyOnFailed else { return nil }
            return Notification(
                key: "\(input.sessionID):failed",
                title: localizer("notif.session.failed.title"),
                body: input.lastSummary.isEmpty ? localizer("notif.session.failed.fallbackBody") : input.lastSummary
            )
        case .waiting_for_input:
            guard preferences.notifyOnWaitingForInput else { return nil }
            guard let pendingRequest = input.pendingRequest else { return nil }
            return Notification(
                key: "\(input.sessionID):waiting:\(pendingRequest.id)",
                title: localizer("notif.session.waiting.title"),
                body: pendingRequest.prompt ?? pendingRequest.title ?? input.title
            )
        case .queued, .running, .blocked, .cancelled:
            return nil
        }
    }

    static func terminalDedupKeysToReset(sessionID: String, status: PickySessionStatus) -> Set<String> {
        switch status {
        case .completed, .failed, .cancelled:
            return []
        case .queued, .running, .waiting_for_input, .blocked:
            return ["\(sessionID):completed", "\(sessionID):failed"]
        }
    }
}
