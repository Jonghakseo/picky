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
    /// One user turn + roughly four assistant text lines; kept intentionally
    /// compact so the card reads as a peek, not a chat window.
    static let defaultCardHeight: CGFloat = 148
    /// The history card must never claim more than this fraction of a screen.
    static let maximumScreenHeightFraction: CGFloat = 0.45
    /// Fixed top and bottom padding around the scroll viewport.
    static let cardVerticalPadding: CGFloat = 20
    /// Keeps a compact user prompt readable rather than showing a clipped card.
    static let minimumScrollContentHeight: CGFloat = 44
    static let minimumCardHeight: CGFloat = cardVerticalPadding + minimumScrollContentHeight

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

    /// Prior transcript exists above the starting turn and can therefore be
    /// indicated with the non-interactive top fade.
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
    static func scrollHeightLimit(cardHeightLimit: CGFloat) -> CGFloat? {
        guard cardHeightLimit >= minimumCardHeight else { return nil }
        return cardHeightLimit - cardVerticalPadding
    }

    /// A gradient should only obscure the bottom edge while transcript content
    /// remains below the scroll viewport. Both values are measured in the
    /// scroll view's named coordinate space.
    static func hasContentBelowViewport(
        contentBottom: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        contentBottom > viewportHeight + 0.5
    }
}

/// The history starts visually lightweight for each presentation, then becomes
/// solid after a user scroll so text remains easy to read over desktop content.
enum QuickInputHistoryBackgroundMode: Equatable {
    case lightweight
    case solid

    mutating func recordUserScroll() {
        self = .solid
    }

    mutating func resetForPresentation() {
        self = .lightweight
    }
}
