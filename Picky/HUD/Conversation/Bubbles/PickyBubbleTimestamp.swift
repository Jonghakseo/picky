//
//  PickyBubbleTimestamp.swift
//  Picky
//
//  Messenger-style send time drawn beside the end of a chat bubble. Hidden
//  until the pointer is over the bubble row; pinned while a message is still
//  being sent. Design: design/proposals/messenger-ux-2026-10.md §2-2.
//

import AppKit
import SwiftUI

struct PickyBubbleTimestamp: Equatable {
    enum Content: Equatable {
        case time(String)
        /// SF Symbol shown instead of text, with its VoiceOver label.
        case symbol(name: String, accessibilityLabel: String)
    }

    let content: Content
    /// Visible without hover. Used for messages that are still being sent.
    let isPinned: Bool

    static func sent(at date: Date) -> Self {
        Self(
            content: .time(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(LocaleManager.nonisolatedEffectiveLocale))),
            isPinned: false
        )
    }

    /// What VoiceOver reads after the bubble text. Hover never happens there.
    var accessibilityText: String {
        switch content {
        case .time(let text): text
        case .symbol(_, let label): label
        }
    }

    /// Queued locally, not yet accepted by the Pickle: a clock, always visible.
    static var sending: Self {
        Self(content: .symbol(name: "clock", accessibilityLabel: L10n.t("common.sending")), isPinned: true)
    }
}

extension View {
    /// Lets VoiceOver read the send time after the bubble text. Bubbles without
    /// a time keep whatever accessibility value their content already provides,
    /// so this never overrides it with an empty string.
    @ViewBuilder
    func pickyBubbleTimestampAccessibility(_ timestamp: PickyBubbleTimestamp?) -> some View {
        if let timestamp {
            accessibilityValue(timestamp.accessibilityText)
        } else {
            self
        }
    }
}

/// Shared AppKit piece for the agent and user bubble surfaces. The surfaces
/// already know the content-hugging bubble rect, so the label can sit right at
/// the bubble's end instead of the card edge.
@MainActor
final class PickyBubbleTimestampAccessory {
    private static let gap: CGFloat = DS.Spacing.space1
    private static let bottomInset: CGFloat = 1
    /// Widest labels the accessory ever shows, in both supported languages.
    private static let widestSamples = ["오후 12:59", "12:59 PM"]
    private static var reserveByFontSize: [CGFloat: CGFloat] = [:]

    let field = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    private(set) var timestamp: PickyBubbleTimestamp?

    /// Width kept free beside the bubble so a time label never overlaps it.
    /// Measured in the current app font scale, because the label grows with it.
    static var reserve: CGFloat {
        let size = PickyHUDTypography.Size.meta
        if let cached = reserveByFontSize[size] { return cached }
        let textWidth = widestSamples.map { measuredLabelWidth($0, size: size) }.max() ?? 0
        let symbolWidth = ceil(symbolImage(name: "clock", size: size, accessibilityDescription: nil)?.size.width ?? 0)
        let reserve = ceil(max(textWidth, symbolWidth) + gap)
        reserveByFontSize[size] = reserve
        return reserve
    }

    /// Measured through a throwaway label rather than `NSString.size`, because
    /// the drawn field adds its own insets and would otherwise truncate a time
    /// that the raw glyph width says fits.
    private static func measuredLabelWidth(_ text: String, size: CGFloat) -> CGFloat {
        let probe = NSTextField(labelWithString: text)
        probe.font = metaFont(size: size)
        probe.lineBreakMode = .byTruncatingTail
        probe.maximumNumberOfLines = 1
        return ceil(probe.fittingSize.width)
    }

    var reservedWidth: CGFloat { timestamp == nil ? 0 : Self.reserve }

    private static func metaFont(size: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private static func symbolImage(name: String, size: CGFloat, accessibilityDescription: String?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config)
    }

    func install(in view: NSView) {
        field.font = Self.metaFont(size: PickyHUDTypography.Size.meta)
        field.textColor = NSColor(DS.Colors.textTertiary)
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isHidden = true
        view.addSubview(field)
        iconView.contentTintColor = NSColor(DS.Colors.textTertiary)
        iconView.isHidden = true
        view.addSubview(iconView)
    }

    func configure(_ timestamp: PickyBubbleTimestamp?) {
        self.timestamp = timestamp
        // The app font scale can change between configurations, and an AppKit
        // font set once at install time would keep the old size.
        let fontSize = PickyHUDTypography.Size.meta
        field.font = Self.metaFont(size: fontSize)
        switch timestamp?.content {
        case .time(let text):
            field.stringValue = text
            iconView.image = nil
        case .symbol(let name, let label):
            field.stringValue = ""
            iconView.image = Self.symbolImage(name: name, size: fontSize, accessibilityDescription: label)
            iconView.setAccessibilityLabel(label)
        case nil:
            field.stringValue = ""
            iconView.image = nil
        }
    }

    /// `bubbleRect` is in the flipped surface coordinate space.
    func layout(beside bubbleRect: NSRect, side: PickyConversationBubbleLayout.BubbleSide, isPointerInside: Bool) {
        guard let timestamp else {
            field.isHidden = true
            iconView.isHidden = true
            return
        }
        let isVisible = timestamp.isPinned || isPointerInside
        if case .symbol = timestamp.content {
            let size = iconView.image?.size ?? .zero
            let x = side == .agent ? bubbleRect.maxX + Self.gap : bubbleRect.minX - Self.gap - size.width
            iconView.frame = NSRect(
                x: x,
                y: bubbleRect.maxY - ceil(size.height) - Self.bottomInset - 2,
                width: ceil(size.width),
                height: ceil(size.height)
            )
            iconView.isHidden = !isVisible
            field.isHidden = true
            return
        }
        iconView.isHidden = true
        let size = field.fittingSize
        let width = min(ceil(size.width), Self.reserve - Self.gap)
        let x = side == .agent ? bubbleRect.maxX + Self.gap : bubbleRect.minX - Self.gap - width
        field.frame = NSRect(
            x: x,
            y: bubbleRect.maxY - ceil(size.height) - Self.bottomInset,
            width: width,
            height: ceil(size.height)
        )
        field.isHidden = !isVisible
    }
}
