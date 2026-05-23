//
//  PickyAgentBubbleSurfaceView.swift
//  Picky
//
//  AppKit-owned assistant bubble surface. SwiftUI may allocate the full
//  leading bubble slot, but this view measures markdown internally and draws
//  only the leading rounded rect that the content actually needs.
//

import AppKit
import SwiftUI

struct PickyAgentBubbleSurfaceView: NSViewRepresentable {
    let markdown: String
    let maxBubbleWidth: CGFloat
    let showsShortcutBadge: Bool
    let onOpenAsReport: (() -> Void)?
    let onCopyText: (() -> Void)?

    func makeNSView(context: Context) -> PickyAgentBubbleSurfaceNSView {
        PickyAgentBubbleSurfaceNSView()
    }

    func updateNSView(_ view: PickyAgentBubbleSurfaceNSView, context: Context) {
        view.configure(
            markdown: markdown,
            maxBubbleWidth: maxBubbleWidth,
            showsShortcutBadge: showsShortcutBadge,
            onOpenAsReport: onOpenAsReport,
            onCopyText: onCopyText
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PickyAgentBubbleSurfaceNSView,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width?.isFinite == true ? proposal.width! : maxBubbleWidth
        let width = min(maxBubbleWidth, proposedWidth)
        return nsView.measuredSize(forRootWidth: width)
    }
}

final class PickyAgentBubbleSurfaceNSView: NSView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 8
        static let maxBubbleWidthFallback: CGFloat = 320
        static let bubbleRadii = AgentBubbleRadii(topLeft: 12, topRight: 12, bottomRight: 12, bottomLeft: 4)
        static let badgeWidth: CGFloat = 30
        static let badgeHeight: CGFloat = 17
        static let badgeInset: CGFloat = 6
        static let hoverIconSize: CGFloat = 22
        static let hoverIconInset: CGFloat = 5
        static let hoverIconCornerRadius: CGFloat = 6
    }

    private let markdownView = PickyBubbleMarkdownContentView()
    private let hoverButton = NSButton(title: "", target: nil, action: nil)

    private var maxBubbleWidth: CGFloat = Metrics.maxBubbleWidthFallback
    private var actionText: String?
    private var showsShortcutBadge = false
    private var onCopyText: (() -> Void)?
    private var onOpenAsReport: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false

    private(set) var lastBubbleRect: NSRect = .zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        addSubview(markdownView)

        hoverButton.isBordered = false
        hoverButton.bezelStyle = .regularSquare
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        hoverButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open this message as report")?
            .withSymbolConfiguration(symbolConfig)
        hoverButton.imagePosition = .imageOnly
        hoverButton.contentTintColor = NSColor(DS.Colors.textSecondary)
        hoverButton.target = self
        hoverButton.action = #selector(openAsReportClicked)
        hoverButton.isHidden = true
        hoverButton.wantsLayer = true
        hoverButton.layer?.cornerRadius = Metrics.hoverIconCornerRadius
        hoverButton.layer?.backgroundColor = NSColor(DS.Colors.surface1).withAlphaComponent(0.78).cgColor
        hoverButton.layer?.borderWidth = 0.5
        hoverButton.layer?.borderColor = NSColor(DS.Colors.borderSubtle).withAlphaComponent(0.55).cgColor
        addSubview(hoverButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        markdown: String,
        maxBubbleWidth: CGFloat,
        showsShortcutBadge: Bool,
        onOpenAsReport: (() -> Void)?,
        onCopyText: (() -> Void)?
    ) {
        markdownView.configure(
            markdown: markdown,
            onOpenAsReport: onOpenAsReport,
            onCopyText: { [weak self] in self?.copyTextClicked() },
            onEditText: nil
        )

        self.maxBubbleWidth = max(0, maxBubbleWidth)
        self.showsShortcutBadge = showsShortcutBadge
        self.actionText = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : markdown
        self.onCopyText = onCopyText
        self.onOpenAsReport = onOpenAsReport

        hoverButton.toolTip = "Open this message as report"

        needsLayout = true
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        measuredSize(forRootWidth: maxBubbleWidth)
    }

    func measuredSize(forRootWidth rootWidth: CGFloat) -> NSSize {
        let rootWidth = max(0, rootWidth)
        let bubbleWidth = measuredBubbleWidth(rootWidth: rootWidth)
        let height = measuredBubbleHeight(interiorWidth: max(0, bubbleWidth - 2 * Metrics.horizontalPadding))
        return NSSize(width: rootWidth, height: ceil(height))
    }

    override func layout() {
        super.layout()
        let bubbleWidth = measuredBubbleWidth(rootWidth: bounds.width)
        let bubbleHeight = measuredBubbleHeight(interiorWidth: max(0, bubbleWidth - 2 * Metrics.horizontalPadding))
        let bubbleRect = NSRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        lastBubbleRect = bubbleRect

        let textWidth = max(0, bubbleRect.width - 2 * Metrics.horizontalPadding)
        let textSize = measuredTextContentSize(forWidth: textWidth)
        markdownView.frame = NSRect(
            x: bubbleRect.minX + Metrics.horizontalPadding,
            y: bubbleRect.minY + Metrics.verticalPadding,
            width: textWidth,
            height: ceil(textSize.height)
        )

        hoverButton.frame = NSRect(
            x: bubbleRect.maxX - Metrics.hoverIconSize - Metrics.hoverIconInset,
            y: bubbleRect.minY + Metrics.hoverIconInset,
            width: Metrics.hoverIconSize,
            height: Metrics.hoverIconSize
        )
        hoverButton.isHidden = !(isPointerInside && onOpenAsReport != nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !lastBubbleRect.isEmpty else { return }
        let path = bubblePath(in: lastBubbleRect)
        bubbleFill.setFill()
        path.fill()
        bubbleStroke.setStroke()
        path.lineWidth = 0.7
        path.stroke()

        if showsShortcutBadge {
            drawShortcutBadge(in: lastBubbleRect)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if actionText != nil, onCopyText != nil {
            let item = NSMenuItem(title: "Copy Text", action: #selector(copyTextClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if onOpenAsReport != nil {
            let item = NSMenuItem(title: "Open as Report", action: #selector(openAsReportClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private var bubbleFill: NSColor {
        NSColor(DS.Colors.surface3.opacity(0.84))
    }

    private var bubbleStroke: NSColor {
        NSColor(DS.Colors.borderSubtle.opacity(0.72))
    }

    private func measuredBubbleWidth(rootWidth: CGFloat) -> CGFloat {
        let bubbleCap = min(maxBubbleWidth, rootWidth)
        let interiorCap = max(0, bubbleCap - 2 * Metrics.horizontalPadding)
        let textSize = measuredTextContentSize(forWidth: interiorCap)
        let contentWidth = min(interiorCap, ceil(textSize.width))
        return min(bubbleCap, contentWidth + 2 * Metrics.horizontalPadding)
    }

    private func measuredBubbleHeight(interiorWidth: CGFloat) -> CGFloat {
        ceil(measuredTextContentSize(forWidth: interiorWidth).height) + 2 * Metrics.verticalPadding
    }

    private func measuredTextContentSize(forWidth width: CGFloat) -> NSSize {
        markdownView.measuredSize(forWidth: width)
    }

    private func bubblePath(in rect: NSRect) -> NSBezierPath {
        let radii = Metrics.bubbleRadii.clamped(to: rect)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + radii.topLeft, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - radii.topRight, y: rect.minY))
        path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + radii.topRight), controlPoint1: NSPoint(x: rect.maxX - radii.topRight * 0.45, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radii.topRight * 0.45))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight))
        path.curve(to: NSPoint(x: rect.maxX - radii.bottomRight, y: rect.maxY), controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight * 0.45), controlPoint2: NSPoint(x: rect.maxX - radii.bottomRight * 0.45, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radii.bottomLeft, y: rect.maxY))
        path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - radii.bottomLeft), controlPoint1: NSPoint(x: rect.minX + radii.bottomLeft * 0.45, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radii.bottomLeft * 0.45))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radii.topLeft))
        path.curve(to: NSPoint(x: rect.minX + radii.topLeft, y: rect.minY), controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radii.topLeft * 0.45), controlPoint2: NSPoint(x: rect.minX + radii.topLeft * 0.45, y: rect.minY))
        path.close()
        return path
    }

    private func drawShortcutBadge(in bubbleRect: NSRect) {
        let rect = NSRect(
            x: bubbleRect.maxX - Metrics.badgeWidth - Metrics.badgeInset,
            y: bubbleRect.maxY - Metrics.badgeHeight - Metrics.badgeInset,
            width: Metrics.badgeWidth,
            height: Metrics.badgeHeight
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(DS.Colors.surface1.opacity(0.82)).setFill()
        path.fill()
        NSColor(DS.Colors.borderSubtle.opacity(0.55)).setStroke()
        path.lineWidth = 0.6
        path.stroke()
        let text = "⌘R"
        // Badge glyph is decorative, but still scales with the global app font
        // scale so users who pump the body text larger can still read the
        // shortcut hint. Floored to 9pt so the badge does not collapse below
        // legibility at the lower end of the 0.9...1.3 range.
        let badgeSize = max(9, 9 * PickyAppFontScaleStore.staticCGScale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: badgeSize, weight: .semibold),
            .foregroundColor: NSColor(DS.Colors.textSecondary),
            .kern: 0.4
        ]
        // Manually center the glyph inside the pill — `draw(in:)` would
        // anchor the text to the top-left of `rect` and leave it visually
        // floating above the vertical midline because system glyphs have a
        // descender region that the box doesn't account for.
        let measured = NSString(string: text).size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.midX - measured.width / 2,
            y: rect.midY - measured.height / 2
        )
        NSAttributedString(string: text, attributes: attributes).draw(at: origin)
    }

    @objc private func copyTextClicked() {
        guard actionText != nil else { return }
        onCopyText?()
    }

    @objc private func openAsReportClicked() {
        onOpenAsReport?()
    }
}

private struct AgentBubbleRadii {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomRight: CGFloat
    var bottomLeft: CGFloat

    func clamped(to rect: NSRect) -> AgentBubbleRadii {
        let limit = min(rect.width, rect.height) / 2
        return AgentBubbleRadii(
            topLeft: min(topLeft, limit),
            topRight: min(topRight, limit),
            bottomRight: min(bottomRight, limit),
            bottomLeft: min(bottomLeft, limit)
        )
    }
}
