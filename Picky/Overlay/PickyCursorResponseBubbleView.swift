//
//  PickyCursorResponseBubbleView.swift
//  Picky
//
//  Cached layout + SwiftUI surface for the short response bubble that follows
//  the cursor. BlueCursorView itself re-renders at cursor/timeline cadence, so
//  markdown parsing and CoreText truncation live here and run only when the
//  response text changes.
//

import AppKit
import Combine
import SwiftUI

struct PickyCursorResponseBubbleLayout {
    enum Metrics {
        static let maxLines: Int = 16
        static let fontSize: CGFloat = 11
        static let maxTextWidth: CGFloat = 302
        static let horizontalPadding: CGFloat = 9
        static let verticalPadding: CGFloat = 6
        static let cornerRadius: CGFloat = DS.CornerRadius.medium

        static var font: NSFont {
            .systemFont(ofSize: fontSize, weight: .medium)
        }
    }

    let sourceText: String
    let attributedText: AttributedString
    let textWidth: CGFloat

    init(sourceText: String) {
        self.sourceText = sourceText
        let renderedText = PickyBubbleMarkdown.displayString(for: sourceText)
        let rawAttributed = PickyBubbleMarkdown.attributedText(for: sourceText)
        let measuredWidth = PickyBubbleLayout.textWidth(
            for: renderedText,
            font: Metrics.font,
            maxWidth: Metrics.maxTextWidth
        )
        textWidth = measuredWidth
        attributedText = PickyBubbleLayout.truncatedAttributedText(
            rawAttributed,
            font: Metrics.font,
            lineSpacing: 0,
            width: measuredWidth,
            maxLines: Metrics.maxLines
        )
    }
}

final class PickyCursorResponseBubbleLayoutCache: ObservableObject {
    @Published private var cachedLayout: PickyCursorResponseBubbleLayout?

    func layout(for sourceText: String) -> PickyCursorResponseBubbleLayout? {
        guard cachedLayout?.sourceText == sourceText else { return nil }
        return cachedLayout
    }

    func update(for sourceText: String) {
        guard !sourceText.isEmpty else {
            clear()
            return
        }
        guard cachedLayout?.sourceText != sourceText else { return }
        cachedLayout = PickyCursorResponseBubbleLayout(sourceText: sourceText)
    }

    func clear() {
        guard cachedLayout != nil else { return }
        cachedLayout = nil
    }
}

struct PickyCursorResponseBubbleView: View {
    let layout: PickyCursorResponseBubbleLayout

    var body: some View {
        Text(layout.attributedText)
            .font(.system(size: PickyCursorResponseBubbleLayout.Metrics.fontSize, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(PickyCursorResponseBubbleLayout.Metrics.maxLines)
            .truncationMode(.tail)
            .frame(width: layout.textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PickyCursorResponseBubbleLayout.Metrics.horizontalPadding)
            .padding(.vertical, PickyCursorResponseBubbleLayout.Metrics.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: PickyCursorResponseBubbleLayout.Metrics.cornerRadius, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 4)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.48), radius: 8, x: 0, y: 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PickyCursorResponseBubbleLayout.Metrics.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.38), lineWidth: 0.8)
            )
    }
}
