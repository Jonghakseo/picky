//
//  PickyUserBubbleSurfaceView.swift
//  Picky
//
//  AppKit-owned user bubble surface. The SwiftUI host may allocate the full
//  trailing bubble slot, but this view measures the markdown text internally
//  and draws only the trailing rounded rect that the content actually needs.
//

import AppKit
import SwiftUI

struct PickyUserBubbleSurfaceView: NSViewRepresentable {
    let markdown: String
    let attachedImagesLabel: String?
    let originLabel: String?
    let isPiExtensionMessage: Bool
    let maxBubbleWidth: CGFloat
    let expansionTitle: String?
    let expansionSystemImageName: String?
    let onToggleExpansion: (() -> Void)?
    let onOpenAsReport: (() -> Void)?
    let onCopyText: (() -> Void)?
    let onEditText: (() -> Void)?
    /// See `PickyAgentBubbleSurfaceView.appFontScale` — declaring the env
    /// dependency forces SwiftUI to call `updateNSView` whenever the global
    /// app font scale changes, which lets the underlying markdown view's
    /// `cachedFontScale` gate rebuild its block subviews at the new size.
    @Environment(\.pickyAppFontScale) private var appFontScale

    func makeNSView(context: Context) -> PickyUserBubbleSurfaceNSView {
        PickyPerf.event("user_bubble_make_nsview")
        return PickyUserBubbleSurfaceNSView()
    }

    func updateNSView(_ view: PickyUserBubbleSurfaceNSView, context: Context) {
        PickyPerf.event("user_bubble_update_nsview")
        _ = appFontScale
        view.configure(
            markdown: markdown,
            attachedImagesLabel: attachedImagesLabel,
            originLabel: originLabel,
            isPiExtensionMessage: isPiExtensionMessage,
            maxBubbleWidth: maxBubbleWidth,
            expansionTitle: expansionTitle,
            expansionSystemImageName: expansionSystemImageName,
            onToggleExpansion: onToggleExpansion,
            onOpenAsReport: onOpenAsReport,
            onCopyText: onCopyText,
            onEditText: onEditText
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PickyUserBubbleSurfaceNSView,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width?.isFinite == true ? proposal.width! : maxBubbleWidth
        let width = min(maxBubbleWidth, proposedWidth)
        return nsView.measuredSize(forRootWidth: width)
    }
}

final class PickyUserBubbleSurfaceNSView: NSView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 8
        static let labelSpacing: CGFloat = 4
        static let expansionSpacing: CGFloat = 7
        static let expansionButtonHeight: CGFloat = 22
        static let maxBubbleWidthFallback: CGFloat = 320
        static let bubbleRadii = BubbleRadii(
            topLeft: PickyConversationBubbleLayout.bubbleRadius,
            topRight: PickyConversationBubbleLayout.bubbleRadius,
            bottomRight: PickyConversationBubbleLayout.bubbleAnchorRadius,
            bottomLeft: PickyConversationBubbleLayout.bubbleRadius
        )
    }

    private let markdownView = PickyBubbleMarkdownContentView()
    private let attachedImagesField = NSTextField(labelWithString: "")
    private let originField = NSTextField(labelWithString: "")
    private let expansionButton = NSButton(title: "", target: nil, action: nil)

    private var maxBubbleWidth: CGFloat = Metrics.maxBubbleWidthFallback
    private var attachedImagesLabel: String?
    private var originLabel: String?
    private var isPiExtensionMessage = false
    private var expansionTitle: String?
    private var actionText: String?
    private var onCopyText: (() -> Void)?
    private var onEditText: (() -> Void)?
    private var onToggleExpansion: (() -> Void)?
    private var onOpenAsReport: (() -> Void)?

    private(set) var lastBubbleRect: NSRect = .zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        addSubview(markdownView)

        configureLabel(attachedImagesField)
        configureLabel(originField)

        expansionButton.isBordered = false
        expansionButton.bezelStyle = .regularSquare
        expansionButton.imagePosition = .imageTrailing
        expansionButton.target = self
        expansionButton.action = #selector(toggleExpansionClicked)
        expansionButton.isHidden = true
        expansionButton.setButtonType(.momentaryChange)
        addSubview(expansionButton)
        applyExpansionButtonAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyExpansionButtonAppearance()
    }

    private func applyExpansionButtonAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            expansionButton.contentTintColor = NSColor(DS.Colors.textSecondary)
            expansionButton.attributedTitle = NSAttributedString(
                string: expansionButton.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .medium),
                    .foregroundColor: NSColor(DS.Colors.textSecondary)
                ]
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        markdown: String,
        attachedImagesLabel: String?,
        originLabel: String?,
        isPiExtensionMessage: Bool,
        maxBubbleWidth: CGFloat,
        expansionTitle: String?,
        expansionSystemImageName: String?,
        onToggleExpansion: (() -> Void)?,
        onOpenAsReport: (() -> Void)?,
        onCopyText: (() -> Void)?,
        onEditText: (() -> Void)?
    ) {
        markdownView.configure(
            markdown: markdown,
            onOpenAsReport: onOpenAsReport,
            onCopyText: { [weak self] in self?.copyTextClicked() },
            onEditText: { [weak self] in self?.editTextClicked() }
        )

        self.attachedImagesLabel = attachedImagesLabel
        self.originLabel = originLabel
        self.isPiExtensionMessage = isPiExtensionMessage
        self.maxBubbleWidth = max(0, maxBubbleWidth)
        self.expansionTitle = expansionTitle
        self.actionText = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : markdown
        self.onCopyText = onCopyText
        self.onEditText = onEditText
        self.onToggleExpansion = onToggleExpansion
        self.onOpenAsReport = onOpenAsReport

        configureLabel(attachedImagesField)
        configureLabel(originField)
        configureExpansionButton(title: expansionTitle, systemImageName: expansionSystemImageName)
        setLabel(attachedImagesField, text: attachedImagesLabel)
        setLabel(originField, text: originLabel)
        needsLayout = true
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        measuredSize(forRootWidth: maxBubbleWidth)
    }

    func measuredSize(forRootWidth rootWidth: CGFloat) -> NSSize {
        let rootWidth = max(0, rootWidth)
        let metrics = bubbleMetrics(rootWidth: rootWidth)
        return NSSize(width: rootWidth, height: ceil(metrics.bubbleHeight))
    }

    override func layout() {
        super.layout()
        let metrics = bubbleMetrics(rootWidth: bounds.width)
        let bubbleX = max(0, bounds.width - metrics.bubbleWidth)
        let bubbleRect = NSRect(x: bubbleX, y: 0, width: metrics.bubbleWidth, height: metrics.bubbleHeight)
        lastBubbleRect = bubbleRect

        let textWidth = max(0, bubbleRect.width - 2 * Metrics.horizontalPadding)
        var y = bubbleRect.minY + Metrics.verticalPadding
        markdownView.frame = NSRect(
            x: bubbleRect.minX + Metrics.horizontalPadding,
            y: y,
            width: textWidth,
            height: ceil(metrics.textHeight)
        )
        y = markdownView.frame.maxY

        layoutLabel(attachedImagesField, in: bubbleRect, y: &y, textWidth: textWidth)
        layoutLabel(originField, in: bubbleRect, y: &y, textWidth: textWidth)
        layoutExpansionButton(in: bubbleRect, y: &y, textWidth: textWidth)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !lastBubbleRect.isEmpty else { return }
        bubbleFill.setFill()
        bubblePath(in: lastBubbleRect).fill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if actionText != nil, onCopyText != nil {
            let item = NSMenuItem(title: "Copy Text", action: #selector(copyTextClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if actionText != nil, onEditText != nil {
            let item = NSMenuItem(title: "Edit in Composer", action: #selector(editTextClicked), keyEquivalent: "")
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
        if isPiExtensionMessage { return NSColor(DS.Colors.surface2.opacity(0.92)) }
        return NSColor(DS.Colors.accentSubtle.opacity(0.95))
    }

    /// Measure the markdown content ONCE — at the bubble cap interior width —
    /// and derive both the content-hugging bubble width and the full bubble
    /// height (text + labels + expansion chrome) from that single
    /// `boundingRect`. The old split measured the text a second time at the
    /// narrower content-fit width just to read its height; that height is
    /// identical at both widths (`ceil` on the content width never re-wraps a
    /// line), so the second measure was pure thrash against the content view's
    /// per-width cache. Mirrors `PickyAgentBubbleSurfaceNSView.bubbleMetrics`.
    private func bubbleMetrics(rootWidth: CGFloat) -> (bubbleWidth: CGFloat, bubbleHeight: CGFloat, textHeight: CGFloat) {
        let bubbleCap = min(maxBubbleWidth, rootWidth)
        let interiorCap = max(0, bubbleCap - 2 * Metrics.horizontalPadding)
        let textSize = measuredTextContentSize(forWidth: interiorCap)
        let labelWidth = max(labelWidth(attachedImagesField), labelWidth(originField))
        let expansionWidth = expansionButtonWidth()
        let contentWidth = min(interiorCap, ceil(max(textSize.width, labelWidth, expansionWidth)))
        let bubbleWidth = min(bubbleCap, contentWidth + 2 * Metrics.horizontalPadding)

        let textHeight = ceil(textSize.height)
        var bubbleHeight = Metrics.verticalPadding + textHeight
        if attachedImagesLabel != nil {
            bubbleHeight += Metrics.labelSpacing + ceil(attachedImagesField.fittingSize.height)
        }
        if originLabel != nil {
            bubbleHeight += Metrics.labelSpacing + ceil(originField.fittingSize.height)
        }
        if expansionTitle != nil {
            bubbleHeight += Metrics.expansionSpacing + Metrics.expansionButtonHeight
        }
        bubbleHeight += Metrics.verticalPadding
        return (bubbleWidth, bubbleHeight, textHeight)
    }

    private func measuredTextContentSize(forWidth width: CGFloat) -> NSSize {
        markdownView.measuredSize(forWidth: width)
    }

    private func configureLabel(_ field: NSTextField) {
        field.font = NSFont.systemFont(ofSize: PickyHUDTypography.Size.minimumText, weight: .medium)
        field.textColor = NSColor(DS.Colors.textTertiary)
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isHidden = true
        addSubview(field)
    }

    private func setLabel(_ field: NSTextField, text: String?) {
        field.stringValue = text ?? ""
        field.isHidden = text == nil
    }

    private func configureExpansionButton(title: String?, systemImageName: String?) {
        expansionButton.title = title ?? ""
        if let systemImageName {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            expansionButton.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: title)?
                .withSymbolConfiguration(symbolConfig)
        } else {
            expansionButton.image = nil
        }
        expansionButton.isHidden = title == nil || onToggleExpansion == nil
        expansionButton.toolTip = title
        applyExpansionButtonAppearance()
    }

    private func labelWidth(_ field: NSTextField) -> CGFloat {
        field.isHidden ? 0 : ceil(field.fittingSize.width)
    }

    private func expansionButtonWidth() -> CGFloat {
        expansionButton.isHidden ? 0 : ceil(expansionButton.fittingSize.width)
    }

    private func layoutLabel(_ field: NSTextField, in bubbleRect: NSRect, y: inout CGFloat, textWidth: CGFloat) {
        guard !field.isHidden else { return }
        y += Metrics.labelSpacing
        let height = ceil(field.fittingSize.height)
        field.frame = NSRect(
            x: bubbleRect.minX + Metrics.horizontalPadding,
            y: y,
            width: textWidth,
            height: height
        )
        y += height
    }

    private func layoutExpansionButton(in bubbleRect: NSRect, y: inout CGFloat, textWidth: CGFloat) {
        guard !expansionButton.isHidden else { return }
        y += Metrics.expansionSpacing
        let width = min(textWidth, max(52, expansionButtonWidth()))
        expansionButton.frame = NSRect(
            x: bubbleRect.minX + Metrics.horizontalPadding - 4,
            y: y,
            width: width,
            height: Metrics.expansionButtonHeight
        )
        y += Metrics.expansionButtonHeight
    }

    private func bubblePath(in rect: NSRect) -> NSBezierPath {
        let radii = Metrics.bubbleRadii.clamped(to: rect)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + radii.topLeft, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - radii.topRight, y: rect.minY))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.minY + radii.topRight),
            controlPoint1: NSPoint(x: rect.maxX - radii.topRight * 0.45, y: rect.minY),
            controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radii.topRight * 0.45)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight))
        path.curve(
            to: NSPoint(x: rect.maxX - radii.bottomRight, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight * 0.45),
            controlPoint2: NSPoint(x: rect.maxX - radii.bottomRight * 0.45, y: rect.maxY)
        )
        path.line(to: NSPoint(x: rect.minX + radii.bottomLeft, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.maxY - radii.bottomLeft),
            controlPoint1: NSPoint(x: rect.minX + radii.bottomLeft * 0.45, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radii.bottomLeft * 0.45)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radii.topLeft))
        path.curve(
            to: NSPoint(x: rect.minX + radii.topLeft, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radii.topLeft * 0.45),
            controlPoint2: NSPoint(x: rect.minX + radii.topLeft * 0.45, y: rect.minY)
        )
        path.close()
        return path
    }

    @objc private func copyTextClicked() {
        guard actionText != nil else { return }
        onCopyText?()
    }

    @objc private func editTextClicked() {
        guard actionText != nil else { return }
        onEditText?()
    }

    @objc private func openAsReportClicked() {
        onOpenAsReport?()
    }

    @objc private func toggleExpansionClicked() {
        onToggleExpansion?()
    }
}

private struct BubbleRadii {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomRight: CGFloat
    var bottomLeft: CGFloat

    func clamped(to rect: NSRect) -> BubbleRadii {
        let limit = min(rect.width, rect.height) / 2
        return BubbleRadii(
            topLeft: min(topLeft, limit),
            topRight: min(topRight, limit),
            bottomRight: min(bottomRight, limit),
            bottomLeft: min(bottomLeft, limit)
        )
    }
}
