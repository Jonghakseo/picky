//
//  PickyAnnotationTextOverlayView.swift
//  Picky
//
//  `[RECT: ... text="..."]` callout renderer. The original stays visible
//  inside a source box connected to a translation card. Callouts are laid out
//  together so cards avoid each other and the other marked text.
//  Design: design/proposals/messenger-ux-2026-10.md §1-2.
//

import AppKit
import SwiftUI

/// Screen-local source box and callout body for one RECT annotation.
struct PickyAnnotationTextItem: Equatable, Identifiable {
    let id: String
    let rect: CGRect
    let text: String
    let visualStyle: PickyAnnotationVisualStyle
}

enum PickyAnnotationTextLayoutPolicy {
    /// Bubble width floor for wrapped text; short text still hugs its content.
    static let calloutMinWrapWidth: CGFloat = 280
    /// Absolute width cap, further limited by the screen width.
    static let calloutMaxWidth: CGFloat = 560
    /// Above this many lines the bubble widens toward the cap before growing taller.
    static let calloutPreferredMaxLines = 4
    static let calloutWidthStep: CGFloat = 40
    static let calloutScreenMargin: CGFloat = DS.Spacing.space4
    /// Rounding headroom between the measured and rendered text width.
    static let calloutWrapSlack: CGFloat = 1
    static let calloutHorizontalPadding: CGFloat = DS.Spacing.space3
    static let calloutVerticalPadding: CGFloat = DS.Spacing.space2
    static let calloutGap: CGFloat = DS.Spacing.space4
    static let calloutNumberWidth: CGFloat = 24
    static let calloutLineSpacing: CGFloat = DS.Spacing.space1
    /// Minimum distance kept between two bubbles.
    static let calloutSpacing: CGFloat = DS.Spacing.space1

    struct CalloutLayout: Equatable {
        let frame: CGRect
        /// Both endpoints touch the actual source/card boundary after clamping.
        let connectorStart: CGPoint
        let connectorEnd: CGPoint
    }

    static var calloutFont: NSFont {
        .systemFont(ofSize: PickyHUDTypography.Size.body, weight: .regular)
    }

    static func maximumBubbleWidth(screenWidth: CGFloat) -> CGFloat {
        max(1, min(calloutMaxWidth, screenWidth - calloutScreenMargin * 2))
    }

    /// Full, untruncated bubble size. The wrap width starts at the original
    /// text's width (a translated paragraph reads best about as wide as its
    /// source) within [`calloutMinWrapWidth`, cap], then widens in steps while
    /// the text still needs more than `calloutPreferredMaxLines` lines.
    static func calloutBodySize(text: String, anchorWidth: CGFloat, screenWidth: CGFloat, numbered: Bool = false) -> CGSize {
        let font = calloutFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let cap = maximumBubbleWidth(screenWidth: screenWidth)
        var bubbleWidth = min(cap, max(calloutMinWrapWidth, anchorWidth))
        let numberWidth = numbered ? calloutNumberWidth : 0
        let wrapWidth = { (bubble: CGFloat) in bubble - calloutHorizontalPadding * 2 - calloutWrapSlack - numberWidth }
        var bounds = measure(text, font: font, width: wrapWidth(bubbleWidth))
        let preferredHeight = lineHeight * CGFloat(calloutPreferredMaxLines)
            + calloutLineSpacing * CGFloat(calloutPreferredMaxLines - 1)
        while bounds.height > preferredHeight + 0.5, bubbleWidth < cap {
            bubbleWidth = min(cap, bubbleWidth + calloutWidthStep)
            bounds = measure(text, font: font, width: wrapWidth(bubbleWidth))
        }
        // Only single-line text hugs its content. Narrowing a wrapped block to
        // its widest line lets SwiftUI re-break it into one more line than measured.
        let isSingleLine = bounds.height < lineHeight * 1.5
        return CGSize(
            width: isSingleLine
                ? min(bubbleWidth, bounds.width + calloutWrapSlack + calloutHorizontalPadding * 2 + numberWidth)
                : bubbleWidth,
            height: bounds.height + calloutVerticalPadding * 2
        )
    }

    /// Greedy word-wrap measurement. SwiftUI draws Korean wrapped at spaces,
    /// but every AppKit/CoreText/SwiftUI size API breaks it between any two
    /// syllables and reports fewer lines than are drawn. Filling lines word by
    /// word matches the drawn result; where text really does break by syllable
    /// it only over-estimates, so the bubble errs wider, never cut off.
    static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let wordWidth = { (word: Substring) in ceil((String(word) as NSString).size(withAttributes: attributes).width) }
        let spaceWidth = (" " as NSString).size(withAttributes: attributes).width
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let limit = max(1, width)
        var lines = 0
        var widest: CGFloat = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current: CGFloat = 0
            var gap = spaceWidth
            lines += 1
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                // Consecutive spaces stay in the text and take room on the line.
                guard !word.isEmpty else {
                    gap += spaceWidth
                    continue
                }
                let w = wordWidth(word)
                defer { gap = spaceWidth }
                if current > 0, current + gap + w <= limit {
                    current += gap + w
                } else {
                    if current > 0 { lines += 1 }
                    // A word wider than the line breaks across extra lines.
                    let extra = max(0, Int(ceil(w / limit)) - 1)
                    lines += extra
                    current = extra > 0 ? w - CGFloat(extra) * limit : w
                    if extra > 0 { widest = limit }
                }
                widest = max(widest, min(current, limit))
            }
        }
        return CGSize(width: ceil(widest), height: CGFloat(lines) * lineHeight + CGFloat(max(0, lines - 1)) * calloutLineSpacing)
    }

    /// Places cards in reading order, preferring a side column for multiple
    /// paragraphs and below the source for a single card, then sliding along
    /// the anchor, and takes the first slot that stays on screen without
    /// covering an earlier bubble or another marked text box. When every slot
    /// collides, the one with the least overlap wins.
    static func layout(_ items: [PickyAnnotationTextItem], screenSize: CGSize, avoiding obstacles: [CGRect] = []) -> [String: CalloutLayout] {
        let screen = CGRect(origin: .zero, size: screenSize).insetBy(dx: calloutScreenMargin, dy: calloutScreenMargin)
        var placed: [CGRect] = []
        var result: [String: CalloutLayout] = [:]
        for item in items {
            let body = calloutBodySize(text: item.text, anchorWidth: item.rect.width, screenWidth: screenSize.width, numbered: items.count > 1)
            let otherRects = items.filter { $0.id != item.id }.map(\.rect) + obstacles
            let bubbles = placed.map { $0.insetBy(dx: -calloutSpacing, dy: -calloutSpacing) }
            let sides = sideFrames(item, screen: screen, numbered: items.count > 1)
            let defaults = candidateFrames(anchor: item.rect, body: body)
            // Multiple paragraphs read as pairs in a side column when room allows.
            let preferred = items.count > 1
                ? sides + defaults
                : Array(defaults.prefix(1)) + sides + Array(defaults.dropFirst())
            // Slide past nearby source/label/card edges too. Merely clamping the
            // four anchor sides can leave a tiny overlap even when a clear gap exists.
            let candidates = (preferred
                + clearanceFrames(anchor: item.rect, body: body, obstacles: otherRects + bubbles))
                .map { clamp($0, into: screen) }
            let chosen = candidates.first { frame in
                placementCost(frame, own: item.rect, others: otherRects, bubbles: bubbles) == (0, 0, 0)
            } ?? candidates.min {
                placementCost($0, own: item.rect, others: otherRects, bubbles: bubbles)
                    < placementCost($1, own: item.rect, others: otherRects, bubbles: bubbles)
            }!
            placed.append(chosen)
            let connection = connector(frame: chosen, anchor: item.rect)
            result[item.id] = CalloutLayout(
                frame: chosen,
                connectorStart: connection.0,
                connectorEnd: connection.1
            )
        }
        return result
    }

    /// A paragraph widened for a full screen may not fit beside its source.
    /// Remeasure against the actual side column instead of clamping it over the source.
    private static func sideFrames(_ item: PickyAnnotationTextItem, screen: CGRect, numbered: Bool) -> [CGRect] {
        [true, false].compactMap { right in
            let width = right ? screen.maxX - item.rect.maxX - calloutGap
                : item.rect.minX - screen.minX - calloutGap
            guard width >= min(calloutMinWrapWidth, screen.width) else { return nil }
            let body = calloutBodySize(text: item.text, anchorWidth: item.rect.width,
                screenWidth: width + calloutScreenMargin * 2, numbered: numbered)
            guard body.height <= screen.height else { return nil }
            return CGRect(x: right ? item.rect.maxX + calloutGap : item.rect.minX - calloutGap - body.width,
                          y: item.rect.midY - body.height / 2, width: body.width, height: body.height)
        }
    }

    private static func candidateFrames(anchor: CGRect, body: CGSize) -> [CGRect] {
        let reach = calloutGap
        let below = anchor.maxY + reach
        let above = anchor.minY - reach - body.height
        let right = anchor.maxX + reach
        let left = anchor.minX - reach - body.width
        var frames: [CGRect] = [
            CGRect(x: anchor.minX, y: below, width: body.width, height: body.height),
            CGRect(x: anchor.minX, y: above, width: body.width, height: body.height),
            CGRect(x: right, y: anchor.midY - body.height / 2, width: body.width, height: body.height),
            CGRect(x: left, y: anchor.midY - body.height / 2, width: body.width, height: body.height),
        ]
        // Crowded screens: slide the same four sides along the anchor before
        // giving up, so a bubble can clear a neighbouring text box instead of
        // landing on it.
        for x in [
            anchor.maxX - body.width,
            anchor.midX - body.width / 2,
            anchor.maxX + calloutSpacing,
            anchor.minX - body.width - calloutSpacing,
        ] {
            frames.append(CGRect(x: x, y: below, width: body.width, height: body.height))
            frames.append(CGRect(x: x, y: above, width: body.width, height: body.height))
        }
        for y in [
            anchor.minY,
            anchor.maxY - body.height,
            anchor.maxY + calloutSpacing,
            anchor.minY - body.height - calloutSpacing,
        ] {
            frames.append(CGRect(x: right, y: y, width: body.width, height: body.height))
            frames.append(CGRect(x: left, y: y, width: body.width, height: body.height))
        }
        return frames
    }

    private static func clearanceFrames(anchor: CGRect, body: CGSize, obstacles: [CGRect]) -> [CGRect] {
        obstacles.flatMap { obstacle in
            [CGRect(x: anchor.minX, y: obstacle.maxY + calloutSpacing, width: body.width, height: body.height),
             CGRect(x: anchor.minX, y: obstacle.minY - calloutSpacing - body.height, width: body.width, height: body.height),
             CGRect(x: obstacle.maxX + calloutSpacing, y: anchor.minY, width: body.width, height: body.height),
             CGRect(x: obstacle.minX - calloutSpacing - body.width, y: anchor.minY, width: body.width, height: body.height)]
        }.sorted {
            hypot($0.midX - anchor.midX, $0.midY - anchor.midY)
                < hypot($1.midX - anchor.midX, $1.midY - anchor.midY)
        }
    }

    private static func connector(frame: CGRect, anchor: CGRect) -> (CGPoint, CGPoint) {
        func bounded(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(max(value, lower), upper)
        }
        // Infer the facing sides from the clamped frames, not the proposed slot.
        if frame.minX >= anchor.maxX || frame.maxX <= anchor.minX {
            let right = frame.minX >= anchor.maxX
            let sourceY = bounded(frame.midY, anchor.minY, anchor.maxY)
            let cardY = bounded(sourceY, frame.minY + DS.Spacing.space3, frame.maxY - DS.Spacing.space3)
            return (CGPoint(x: right ? anchor.maxX : anchor.minX, y: sourceY),
                    CGPoint(x: right ? frame.minX : frame.maxX, y: cardY))
        }
        let below = frame.minY >= anchor.maxY
        let sourceX = bounded(frame.midX, anchor.minX, anchor.maxX)
        let cardX = bounded(sourceX, frame.minX + DS.Spacing.space3, frame.maxX - DS.Spacing.space3)
        return (CGPoint(x: sourceX, y: below ? anchor.maxY : anchor.minY),
                CGPoint(x: cardX, y: below ? frame.minY : frame.maxY))
    }

    /// Ranking used to pick a slot. Covering the text the callout explains is
    /// the one failure it must never make, then covering another marked text
    /// box (whose own callout would become unreadable), and only then
    /// overlapping an already placed bubble.
    private static func placementCost(
        _ frame: CGRect,
        own: CGRect,
        others: [CGRect],
        bubbles: [CGRect]
    ) -> (CGFloat, CGFloat, CGFloat) {
        (overlap(frame, [own]), overlap(frame, others), overlap(frame, bubbles))
    }

    private static func overlap(_ frame: CGRect, _ obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(0) { total, obstacle in
            let intersection = frame.intersection(obstacle)
            return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
    }

    private static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        result.origin.y = min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return result
    }
}

/// Renders RECT source boxes and their cards in one placement pass.
struct PickyAnnotationTextOverlayView: View {
    let items: [PickyAnnotationTextItem]
    let screenSize: CGSize
    var obstacles: [CGRect] = []

    var body: some View {
        let layouts = PickyAnnotationTextLayoutPolicy.layout(items, screenSize: screenSize, avoiding: obstacles)
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                sourceBox(item, number: items.count > 1 ? index + 1 : nil)
                if let layout = layouts[item.id] {
                    Path { path in
                        path.move(to: layout.connectorStart)
                        path.addLine(to: layout.connectorEnd)
                    }
                    .stroke(item.visualStyle.palette.color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                }
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let layout = layouts[item.id] {
                    callout(item, layout: layout, number: items.count > 1 ? index + 1 : nil)
                }
            }
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
    }

    private func sourceBox(_ item: PickyAnnotationTextItem, number: Int?) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DS.CornerRadius.compact)
                .strokeBorder(item.visualStyle.palette.color, lineWidth: 1.5)
                .frame(width: item.rect.width, height: item.rect.height)
                .offset(x: item.rect.minX, y: item.rect.minY)
            if let number {
                Text(verbatim: String(number))
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, DS.Spacing.space1)
                    .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
                    .offset(x: item.rect.minX + DS.Spacing.space2, y: max(0, item.rect.minY - DS.Spacing.space2))
            }
        }
    }

    private func callout(_ item: PickyAnnotationTextItem, layout: PickyAnnotationTextLayoutPolicy.CalloutLayout, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if let number {
                Text(verbatim: String(number))
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: PickyAnnotationTextLayoutPolicy.calloutNumberWidth, alignment: .leading)
            }
            Text(item.text)
                .font(Font(PickyAnnotationTextLayoutPolicy.calloutFont))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineSpacing(PickyAnnotationTextLayoutPolicy.calloutLineSpacing)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PickyAnnotationTextLayoutPolicy.calloutHorizontalPadding)
        .padding(.vertical, PickyAnnotationTextLayoutPolicy.calloutVerticalPadding)
        // Placement reserves this measured height. Use it for the actual surface
        // too, so conservative CJK measurement cannot leave the connector detached.
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
        .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: DS.CornerRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.surface).strokeBorder(DS.Colors.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(DS.Elevation.floatingPanelShadowOpacity),
                radius: DS.Elevation.floatingPanelShadowRadius, y: DS.Elevation.floatingPanelShadowYOffset)
        .offset(x: layout.frame.minX, y: layout.frame.minY)
    }
}
