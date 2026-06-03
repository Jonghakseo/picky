//
//  PickyTerminalAttachmentCoordinator.swift
//  Picky
//
//  Pure stack policy for inline/shell terminal attachments. The latest visible
//  eligible attachment is active; releasing/removing the active one promotes
//  the most recent still-eligible attachment.
//

struct PickyTerminalAttachmentCoordinator: Equatable {
    private struct Attachment: Equatable {
        let sessionID: String
        let attachmentID: String
    }

    private var visibleAttachments: [Attachment] = []
    private(set) var activeSessionID: String?
    private(set) var activeAttachmentID: String?

    func isActive(sessionID: String, attachmentID: String) -> Bool {
        activeSessionID == sessionID && activeAttachmentID == attachmentID
    }

    mutating func activate(sessionID: String, attachmentID: String, eligibleSessionIDs: Set<String>) {
        guard eligibleSessionIDs.contains(sessionID) else { return }
        let attachment = Attachment(sessionID: sessionID, attachmentID: attachmentID)
        visibleAttachments.removeAll { $0 == attachment }
        visibleAttachments.append(attachment)
        activeSessionID = sessionID
        activeAttachmentID = attachmentID
    }

    mutating func release(sessionID: String, attachmentID: String, eligibleSessionIDs: Set<String>) {
        let releasedActiveAttachment = activeSessionID == sessionID && activeAttachmentID == attachmentID
        visibleAttachments.removeAll { $0.sessionID == sessionID && $0.attachmentID == attachmentID }
        guard releasedActiveAttachment else { return }
        promoteLastVisibleAttachment(eligibleSessionIDs: eligibleSessionIDs)
    }

    mutating func removeSession(sessionID: String, eligibleSessionIDs: Set<String>) {
        let removedActiveSession = activeSessionID == sessionID
        visibleAttachments.removeAll { $0.sessionID == sessionID }
        if removedActiveSession {
            promoteLastVisibleAttachment(eligibleSessionIDs: eligibleSessionIDs)
        }
    }

    private mutating func promoteLastVisibleAttachment(eligibleSessionIDs: Set<String>) {
        while let next = visibleAttachments.last {
            if eligibleSessionIDs.contains(next.sessionID) {
                activeSessionID = next.sessionID
                activeAttachmentID = next.attachmentID
                return
            }
            visibleAttachments.removeLast()
        }
        activeSessionID = nil
        activeAttachmentID = nil
    }
}
