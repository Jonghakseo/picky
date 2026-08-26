//
//  PickyHUDDockGroupListOutsideDismissFramePolicy.swift
//  Picky
//

import CoreGraphics

/// Panel anchoring uses the badge frame, while outside dismissal belongs to
/// the larger tile-plus-label interaction frame.
enum PickyHUDDockGroupListOutsideDismissFramePolicy {
    static func owningInteractionScreenFrame(
        openGroupID: String?,
        interactionFrames: [String: CGRect],
        hudPanelFrame: CGRect
    ) -> CGRect? {
        guard let openGroupID, let interactionFrame = interactionFrames[openGroupID] else { return nil }
        return PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudPanelFrame,
            swiftUIOrigin: interactionFrame.origin,
            panelSize: interactionFrame.size
        )
    }
}
