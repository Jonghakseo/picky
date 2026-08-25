//
//  PickyTerminalAttachmentStore.swift
//  Picky
//
//  Observable owner for the single visible terminal attachment in one terminal
//  modality. Mounted terminal panels read this exact store so another panel
//  taking ownership immediately replaces its placeholder without observing the
//  global session facade.
//

import Observation

@MainActor
@Observable
final class PickyTerminalAttachmentStore {
    private var coordinator = PickyTerminalAttachmentCoordinator()
    private(set) var activeSessionID: String?
    private(set) var activeAttachmentID: String?

    func isActive(sessionID: String, attachmentID: String) -> Bool {
        activeSessionID == sessionID && activeAttachmentID == attachmentID
    }

    func activate(sessionID: String, attachmentID: String, eligibleSessionIDs: Set<String>) {
        coordinator.activate(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: eligibleSessionIDs
        )
        syncActiveAttachment()
    }

    func release(sessionID: String, attachmentID: String, eligibleSessionIDs: Set<String>) {
        coordinator.release(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: eligibleSessionIDs
        )
        syncActiveAttachment()
    }

    func removeSession(sessionID: String, eligibleSessionIDs: Set<String>) {
        coordinator.removeSession(sessionID: sessionID, eligibleSessionIDs: eligibleSessionIDs)
        syncActiveAttachment()
    }

    private func syncActiveAttachment() {
        let nextSessionID = coordinator.activeSessionID
        let nextAttachmentID = coordinator.activeAttachmentID
        guard activeSessionID != nextSessionID || activeAttachmentID != nextAttachmentID else { return }
        activeSessionID = nextSessionID
        activeAttachmentID = nextAttachmentID
    }
}
