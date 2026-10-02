//
//  PickyAnnotationTextOverlayView.swift
//  Picky
//
//  `[TEXT: ...]` annotation renderer. The original on-screen text stays
//  visible; a thin marker underlines it and a bubble with the translation or
//  explanation attaches beside it. Several TEXT tags in one reply are laid out
//  together so bubbles avoid each other and the other marked text.
//  Design: design/proposals/messenger-ux-2026-10.md §1-2.
//

import AppKit
import SwiftUI

/// Screen-local input for one TEXT annotation.
struct PickyAnnotationTextItem: Equatable, Identifiable {
    let id: String
    let rect: CGRect
    let text: String
    let visualStyle: PickyAnnotationVisualStyle
}

enum PickyAnnotationTextLayoutPolicy {
    static let markerHeight: CGFloat = 1.5
    static let calloutMaxWidth: CGFloat = 280
    static let calloutMaxLines = 8
    static let calloutHorizontalPadding: CGFloat = DS.Spacing.space3
    static let calloutVerticalPadding: CGFloat = DS.Spacing.space2
    static let calloutTailSize = CGSize(width: 12, height: 6)
    static let calloutGap: CGFloat = DS.Spacing.space1
    /// Minimum distance kept between two bubbles.
    static let calloutSpacing: CGFloat = DS.Spacing.space1

    struct CalloutLayout: Equatable {
        /// Bubble body frame, screen-local, excluding the tail.
        let frame: CGRect
        /// Edge of the bubble that carries the tail, facing the anchor.
        let tailEdge: Edge
        /// Tail tip position along `tailEdge`, relative to the bubble origin.
        let tailOffset: CGFloat
    }

    static var calloutFont: NSFont {
        .systemFont(ofSize: PickyHUDTypography.Size.bodyCompact, weight: .regular)
    }

    static func calloutBodySize(text: String) -> CGSize {
        let font = calloutFont
        let maxTextWidth = calloutMaxWidth - calloutHorizontalPadding * 2
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(ceil(bounds.height), lineHeight * CGFloat(calloutMaxLines))
        return CGSize(
            width: ceil(bounds.width) + calloutHorizontalPadding * 2,
            height: ceil(height) + calloutVerticalPadding * 2
        )
    }

    /// Places bubbles in reading order. Each bubble tries below, above,
    /// trailing, then leading its anchor, then the same four sides slid along
    /// the anchor, and takes the first slot that stays on screen without
    /// covering an earlier bubble or another marked text box. When every slot
    /// collides, the one with the least overlap wins.
    static func layout(_ items: [PickyAnnotationTextItem], screenSize: CGSize) -> [String: CalloutLayout] {
        let screen = CGRect(origin: .zero, size: screenSize)
        var placed: [CGRect] = []
        var result: [String: CalloutLayout] = [:]
        for item in items {
            let body = calloutBodySize(text: item.text)
            let otherRects = items.filter { $0.id != item.id }.map(\.rect)
            let bubbles = placed.map { $0.insetBy(dx: -calloutSpacing, dy: -calloutSpacing) }
            let candidates = candidateFrames(anchor: item.rect, body: body).map { edge, frame in
                (edge, clamp(frame, into: screen))
            }
            let chosen = candidates.first { _, frame in
                placementCost(frame, own: item.rect, others: otherRects, bubbles: bubbles) == (0, 0, 0)
            } ?? candidates.min {
                placementCost($0.1, own: item.rect, others: otherRects, bubbles: bubbles)
                    < placementCost($1.1, own: item.rect, others: otherRects, bubbles: bubbles)
            }!
            placed.append(chosen.1)
            result[item.id] = CalloutLayout(
                frame: chosen.1,
                tailEdge: chosen.0,
                tailOffset: tailOffset(edge: chosen.0, frame: chosen.1, anchor: item.rect)
            )
        }
        return result
    }

    private static func candidateFrames(anchor: CGRect, body: CGSize) -> [(Edge, CGRect)] {
        let reach = calloutGap + markerHeight + calloutTailSize.height
        let below = anchor.maxY + reach
        let above = anchor.minY - reach - body.height
        let right = anchor.maxX + reach
        let left = anchor.minX - reach - body.width
        var frames: [(Edge, CGRect)] = [
            (.top, CGRect(x: anchor.minX, y: below, width: body.width, height: body.height)),
            (.bottom, CGRect(x: anchor.minX, y: above, width: body.width, height: body.height)),
            (.leading, CGRect(x: right, y: anchor.midY - body.height / 2, width: body.width, height: body.height)),
            (.trailing, CGRect(x: left, y: anchor.midY - body.height / 2, width: body.width, height: body.height)),
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
            frames.append((.top, CGRect(x: x, y: below, width: body.width, height: body.height)))
            frames.append((.bottom, CGRect(x: x, y: above, width: body.width, height: body.height)))
        }
        for y in [
            anchor.minY,
            anchor.maxY - body.height,
            anchor.maxY + calloutSpacing,
            anchor.minY - body.height - calloutSpacing,
        ] {
            frames.append((.leading, CGRect(x: right, y: y, width: body.width, height: body.height)))
            frames.append((.trailing, CGRect(x: left, y: y, width: body.width, height: body.height)))
        }
        return frames
    }

    private static func tailOffset(edge: Edge, frame: CGRect, anchor: CGRect) -> CGFloat {
        let inset = DS.Spacing.space3
        switch edge {
        case .top, .bottom:
            let target = min(anchor.midX, anchor.minX + 24)
            return min(max(target - frame.minX, inset), frame.width - inset)
        case .leading, .trailing:
            return min(max(anchor.midY - frame.minY, inset), frame.height - inset)
        }
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

/// Renders every TEXT annotation of one screen inside the annotation overlay.
struct PickyAnnotationTextOverlayView: View {
    let items: [PickyAnnotationTextItem]
    let screenSize: CGSize

    var body: some View {
        let layouts = PickyAnnotationTextLayoutPolicy.layout(items, screenSize: screenSize)
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                marker(for: item)
            }
            ForEach(items) { item in
                if let layout = layouts[item.id] {
                    callout(item, layout: layout)
                }
            }
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
    }

    private func marker(for item: PickyAnnotationTextItem) -> some View {
        Capsule()
            .fill(item.visualStyle.palette.color.opacity(0.75))
            .frame(width: item.rect.width, height: PickyAnnotationTextLayoutPolicy.markerHeight)
            .position(x: item.rect.midX, y: item.rect.maxY + PickyAnnotationTextLayoutPolicy.markerHeight / 2 + 1)
    }

    private func callout(_ item: PickyAnnotationTextItem, layout: PickyAnnotationTextLayoutPolicy.CalloutLayout) -> some View {
        Text(item.text)
            .font(Font(PickyAnnotationTextLayoutPolicy.calloutFont))
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(PickyAnnotationTextLayoutPolicy.calloutMaxLines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, PickyAnnotationTextLayoutPolicy.calloutHorizontalPadding)
            .padding(.vertical, PickyAnnotationTextLayoutPolicy.calloutVerticalPadding)
            .frame(width: layout.frame.width, height: layout.frame.height, alignment: .leading)
            .background {
                let shape = PickyAnnotationCalloutShape(
                    tailEdge: layout.tailEdge,
                    tailOffset: layout.tailOffset,
                    tailSize: PickyAnnotationTextLayoutPolicy.calloutTailSize,
                    cornerRadius: DS.CornerRadius.surface
                )
                shape.fill(DS.Colors.surface1)
                    .shadow( // design-token-exception: desktop callout floats over arbitrary app content, so it reuses the cursor response bubble's separation shadow instead of a HUD surface elevation
                        color: .black.opacity(0.22),
                        radius: 8,
                        y: 2
                    )
            }
            .position(x: layout.frame.midX, y: layout.frame.midY)
    }
}

/// Rounded bubble whose tail sits outside the body rect on `tailEdge`.
struct PickyAnnotationCalloutShape: Shape {
    let tailEdge: Edge
    let tailOffset: CGFloat
    let tailSize: CGSize
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        let half = tailSize.width / 2
        var tail = Path()
        switch tailEdge {
        case .top:
            let x = rect.minX + tailOffset
            tail.move(to: CGPoint(x: x - half, y: rect.minY + 0.5))
            tail.addLine(to: CGPoint(x: x, y: rect.minY - tailSize.height))
            tail.addLine(to: CGPoint(x: x + half, y: rect.minY + 0.5))
        case .bottom:
            let x = rect.minX + tailOffset
            tail.move(to: CGPoint(x: x - half, y: rect.maxY - 0.5))
            tail.addLine(to: CGPoint(x: x, y: rect.maxY + tailSize.height))
            tail.addLine(to: CGPoint(x: x + half, y: rect.maxY - 0.5))
        case .leading:
            let y = rect.minY + tailOffset
            tail.move(to: CGPoint(x: rect.minX + 0.5, y: y - half))
            tail.addLine(to: CGPoint(x: rect.minX - tailSize.height, y: y))
            tail.addLine(to: CGPoint(x: rect.minX + 0.5, y: y + half))
        case .trailing:
            let y = rect.minY + tailOffset
            tail.move(to: CGPoint(x: rect.maxX - 0.5, y: y - half))
            tail.addLine(to: CGPoint(x: rect.maxX + tailSize.height, y: y))
            tail.addLine(to: CGPoint(x: rect.maxX - 0.5, y: y + half))
        }
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}
