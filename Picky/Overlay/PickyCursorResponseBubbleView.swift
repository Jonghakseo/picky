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
    /// Number of visual lines the truncated text wraps to at `textWidth`. Used by the
    /// cache to reject transient renders that are shorter than what is already shown.
    let lineCount: Int

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
        let truncated = PickyBubbleLayout.truncatedAttributedText(
            rawAttributed,
            font: Metrics.font,
            lineSpacing: 0,
            width: measuredWidth,
            maxLines: Metrics.maxLines
        )
        attributedText = truncated
        lineCount = PickyBubbleLayout.visualLineCount(
            truncated,
            font: Metrics.font,
            lineSpacing: 0,
            width: measuredWidth
        )
    }
}

final class PickyCursorResponseBubbleLayoutCache: ObservableObject {
    @Published private var cachedLayout: PickyCursorResponseBubbleLayout?
    private var cachedContentIdentity: String?

    /// Returns a layout for the current text. On a cache miss the layout is
    /// computed synchronously instead of returning nil, so the response bubble
    /// never blanks for the one frame between a text change and the async cache
    /// warm in `update(for:)`. That transient nil is what made the blue bubble
    /// flicker as narration sentences accumulated or swapped at visual boundaries.
    /// Computed inline without mutating `@Published` state so this stays safe to
    /// call during a SwiftUI body evaluation; `update(for:)` still warms the
    /// cache so steady-state renders reuse the stored layout.
    func layout(
        for sourceText: String,
        contentIdentity: String? = nil
    ) -> PickyCursorResponseBubbleLayout? {
        guard !sourceText.isEmpty else { return nil }
        if let cachedLayout {
            if cachedContentIdentity == contentIdentity,
               cachedLayout.sourceText == sourceText {
                return cachedLayout
            }
            let candidate = PickyCursorResponseBubbleLayout(sourceText: sourceText)
            guard cachedContentIdentity == contentIdentity else { return candidate }
            return stabilized(candidate, against: cachedLayout)
        }
        return PickyCursorResponseBubbleLayout(sourceText: sourceText)
    }

    func update(
        for sourceText: String,
        contentIdentity: String? = nil
    ) {
        guard !sourceText.isEmpty else {
            clear()
            return
        }
        guard cachedContentIdentity != contentIdentity
                || cachedLayout?.sourceText != sourceText else { return }
        let candidate = PickyCursorResponseBubbleLayout(sourceText: sourceText)
        if let current = cachedLayout,
           cachedContentIdentity == contentIdentity {
            cachedLayout = stabilized(candidate, against: current)
        } else {
            cachedLayout = candidate
        }
        cachedContentIdentity = contentIdentity
    }

    /// Within one content identity the response is append-only, so a candidate that wraps to
    /// fewer visual lines than the layout already on screen is a transient regression: a
    /// TTS/narration state race briefly hands back a shorter text variant (streamed vs
    /// spoken/narration text differ in whitespace, so a plain prefix check misses it). A new
    /// visual narration segment has a different identity and bypasses this stabilization.
    private func stabilized(
        _ candidate: PickyCursorResponseBubbleLayout,
        against current: PickyCursorResponseBubbleLayout
    ) -> PickyCursorResponseBubbleLayout {
        candidate.lineCount < current.lineCount ? current : candidate
    }

    func clear() {
        guard cachedLayout != nil else { return }
        cachedLayout = nil
        cachedContentIdentity = nil
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
