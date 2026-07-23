//
//  QuickInputHistoryPolicy.swift
//  Picky
//
//  Pure presentation decisions for the compact main-agent transcript that
//  appears above the Quick Input composer.
//

import CoreGraphics

/// Keeps the Quick Input history card's message selection and size decisions
/// independent from SwiftUI/AppKit layout. The card starts at the final user
/// turn, so scrolling down continues that answer and scrolling up reaches
/// earlier turns in the same scroll view.
enum QuickInputHistoryPolicy {
    /// Header + one user turn + roughly four assistant text lines.
    static let defaultCardHeight: CGFloat = 164
    /// The history card must never claim more than this fraction of a screen.
    static let maximumScreenHeightFraction: CGFloat = 0.45

    static func shouldShowCard(for messages: [PickyMainAgentMessage]) -> Bool {
        !messages.isEmpty
    }

    /// Starts the compact view at the last prompt. A still-pending user prompt
    /// is naturally its own anchor because it is also the last user message.
    static func anchorMessageID(in messages: [PickyMainAgentMessage]) -> String? {
        messages.last(where: { $0.role == .user })?.id ?? messages.last?.id
    }

    /// The instructional affordance only appears when a prior transcript
    /// exists above the starting turn; it is never rendered for a single turn.
    static func hasEarlierMessages(in messages: [PickyMainAgentMessage]) -> Bool {
        guard let anchorID = anchorMessageID(in: messages),
              let anchorIndex = messages.firstIndex(where: { $0.id == anchorID }) else {
            return false
        }
        return anchorIndex > messages.startIndex
    }

    /// Caps the card to the space available on the active display while keeping
    /// the default four-line presentation on normal displays.
    static func cardHeightLimit(
        visibleScreenHeight: CGFloat?,
        spaceAbovePill: CGFloat?
    ) -> CGFloat {
        let screenCap = visibleScreenHeight.map { $0 * maximumScreenHeightFraction } ?? defaultCardHeight
        let availableSpace = spaceAbovePill ?? defaultCardHeight
        return max(0, min(defaultCardHeight, screenCap, availableSpace))
    }
}
