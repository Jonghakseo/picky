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
    /// Fixed vertical chrome shared by every history-card variant.
    static let cardVerticalPadding: CGFloat = 20
    static let historyHintHeight: CGFloat = 22
    static let historyContentSpacing: CGFloat = 8
    /// Keeps a compact user prompt readable rather than showing a clipped card.
    static let minimumScrollContentHeight: CGFloat = 44
    /// The minimum includes the hint row even for a one-turn transcript, so a
    /// card never appears with insufficient room for its normal chrome.
    static let minimumCardHeight: CGFloat = cardVerticalPadding
        + historyHintHeight
        + historyContentSpacing
        + minimumScrollContentHeight

    static func shouldShowCard(for messages: [PickyMainAgentMessage]) -> Bool {
        !messages.isEmpty
    }

    /// Avoids rendering a clipped history card when the cursor leaves too
    /// little room above the pill. The composer then remains anchored on its
    /// own, rather than being shifted downward by card chrome.
    static func shouldDisplayCard(
        for messages: [PickyMainAgentMessage],
        cardHeightLimit: CGFloat
    ) -> Bool {
        shouldShowCard(for: messages) && cardHeightLimit >= minimumCardHeight
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

    /// Reserves fixed card chrome before giving the scroll view its height cap,
    /// ensuring the rendered card can never exceed `cardHeightLimit`.
    static func scrollHeightLimit(
        cardHeightLimit: CGFloat,
        hasEarlierMessages: Bool
    ) -> CGFloat? {
        guard cardHeightLimit >= minimumCardHeight else { return nil }
        let chromeHeight = cardVerticalPadding
            + (hasEarlierMessages ? historyHintHeight + historyContentSpacing : 0)
        return cardHeightLimit - chromeHeight
    }
}
