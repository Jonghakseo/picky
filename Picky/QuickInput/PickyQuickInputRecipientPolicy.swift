//
//  PickyQuickInputRecipientPolicy.swift
//  Picky
//

import Foundation

/// Resolves the typed Quick Input target from the capture-time screen-context
/// selection. The panel retains this value until delivery finishes, so later
/// hover/selection changes cannot retarget an in-flight draft.
enum PickyQuickInputRecipientPolicy {
    static func resolve(
        screenContextTargetSessionID: String?,
        targetLabel: String?
    ) -> QuickInputRecipientProjection {
        let sessionID = screenContextTargetSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionID.isEmpty else { return .main }

        let label = targetLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .pickle(sessionID: sessionID, label: label.isEmpty ? "Pickle" : label)
    }
}
