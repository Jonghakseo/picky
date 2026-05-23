//
//  PickyMarkdownInlineTextView.swift
//  Picky
//
//  One-NSTextView wrapper that renders a contiguous run of inline markdown
//  blocks (heading/paragraph/bullet) as a single selectable text container.
//
//  Replaces the previous per-block SwiftUI `Text` + `.textSelection(.enabled)`
//  pattern, which on macOS 26.x trapped the main thread inside a single
//  mouseDown for several seconds — NSTextSelectionNavigation iterated every
//  selectable backing in the card while holding objc_sync locks (see
//  `Picky/Watchdog/PickyMainThreadWatchdog.swift:60-66`). Folding inline
//  blocks into one NSTextLayoutManager makes hit-test O(1) in the card and,
//  as a side-effect, lets selection sweep across heading/paragraph/bullet
//  without stopping at SwiftUI sibling boundaries.
//
//  Code blocks and tables stay outside this wrapper — they need a horizontal
//  ScrollView and custom column widths that NSTextView can't express
//  cheaply, and the per-block selection island they form today already
//  matches user expectation.
//

import AppKit
import SwiftUI

struct PickyMarkdownInlineTextView: NSViewRepresentable {
    /// Subset of `PickyReportMarkdownRenderer.Block` that this wrapper accepts.
    /// Code/table blocks go through their existing SwiftUI render paths.
    enum InlineBlock: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
    }

    let blocks: [InlineBlock]
    /// When false, the text container hugs its widest line instead of
    /// stretching to the SwiftUI-allotted width. Used by the user bubble,
    /// which sizes the bubble to its own content.
    var fillsAvailableWidth: Bool = true
    /// Hug-fit cap when `fillsAvailableWidth` is false. The wrapper would
    /// otherwise inherit the SwiftUI parent's full width proposal as its
    /// hug-fit ceiling, and the user bubble's `.frame(maxWidth: cardWidth
    /// * 0.85)` would stretch the bubble to that whole 85% column even for
    /// short messages (see screenshot 2026-05-21 12:16:57). Pass the
    /// allowed bubble interior width here so wrapping and the reported
    /// ideal width both respect it.
    var hugContentMaxWidth: CGFloat?
    /// Appended to the NSTextView's right-click menu as "Open as Report"
    /// when non-nil. Mirrors the SwiftUI `.contextMenu` action the bubble
    /// view used to attach — that modifier no longer covers the text region
    /// once an NSTextView claims the click.
    var onOpenAsReport: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onEditText: (() -> Void)?

    /// Global app font scale. Both declared so SwiftUI re-invokes
    /// `updateNSView` on ⌘+ / ⌘- and threaded into the cache key /
    /// attributed-string builder so the rebuilt NSTextView storage actually
    /// reflects the new scale.
    @Environment(\.pickyAppFontScale) private var appFontScale

    /// Vertical gap appended after every block except the last. Matches the
    /// `VStack(spacing: 5)` used by the previous SwiftUI composition so the
    /// migration is pixel-stable. Multiplied by the live app font scale at
    /// build time so the gap grows together with the body text.
    static let blockSpacing: CGFloat = 5

    /// Bullet body-column indent (matches the previous SwiftUI HStack with
    /// a 6pt spacer + the "•" glyph's natural width at body size). Scaled
    /// alongside the block spacing so larger bullet glyphs don't crash into
    /// the body text.
    fileprivate static let bulletLeaderIndent: CGFloat = 14

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelfSizingMarkdownTextView {
        let view = SelfSizingMarkdownTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: SelfSizingMarkdownTextView, context: Context) {
        let key = Self.cacheKey(blocks, scale: appFontScale)
        if context.coordinator.lastCacheKey != key {
            let attributed = Self.buildAttributedString(from: blocks, scale: appFontScale)
            view.textStorage?.setAttributedString(attributed)
            context.coordinator.lastCacheKey = key
            view.invalidateIntrinsicContentSize()
        }
        view.fillsAvailableWidth = fillsAvailableWidth
        view.hugContentMaxWidth = hugContentMaxWidth
        view.onOpenAsReport = onOpenAsReport
        view.onCopyText = onCopyText
        view.onEditText = onEditText
    }

    /// Reports the layout-measured size for the SwiftUI parent's width
    /// proposal. We can't rely on `intrinsicContentSize` alone because
    /// SwiftUI's `.frame(maxWidth: X)` is a max bound on the *child's*
    /// ideal width — NSView reporting an ideal width wider than X still
    /// renders at the wider value, which is how the user bubble started
    /// spilling out of the card after the migration.
    ///
    /// By measuring inside the proposed width we let the conversation bubble
    /// layout cap actually clamp hug-fit content, while
    /// `fillsAvailableWidth = true` keeps the agent bubble stretching to the
    /// full available column.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SelfSizingMarkdownTextView,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width ?? .greatestFiniteMagnitude
        let proposedFinite = proposedWidth.isFinite ? proposedWidth : .greatestFiniteMagnitude

        if fillsAvailableWidth {
            // Stretch to the SwiftUI-allotted column (agent bubble case).
            let measured = nsView.measureUsedSize(forWidth: proposedFinite)
            return CGSize(width: proposedFinite, height: ceil(measured.height))
        }

        // Hug content. The cap is the explicit `hugContentMaxWidth` when
        // the caller passed one (user bubble path: bubble interior width);
        // otherwise fall back to whatever SwiftUI proposed. Layout once at
        // the cap so the measured width reflects post-wrap reality, then
        // report that width as the wrapper's ideal so the parent
        // `.frame(maxWidth:)` does not stretch the bubble background.
        let cap: CGFloat
        if let hugCap = hugContentMaxWidth, hugCap.isFinite, hugCap > 0 {
            cap = min(hugCap, proposedFinite)
        } else {
            cap = proposedFinite
        }
        let measured = nsView.measureUsedSize(forWidth: cap)
        let width = min(ceil(measured.width), cap)
        return CGSize(width: width, height: ceil(measured.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastCacheKey: String?

        /// Routes `picky://...` clicks through the dispatcher (so deep links
        /// open the right companion panel screen). Any other scheme returns
        /// `false` so AppKit falls back to `NSWorkspace.open(url)`.
        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let resolved: URL?
            if let url = link as? URL {
                resolved = url
            } else if let string = link as? String {
                resolved = URL(string: string)
            } else {
                resolved = nil
            }
            guard let url = resolved else { return false }
            return PickyDeepLinkDispatcher.shared.handle(url)
        }
    }
}

// MARK: - NSAttributedString builder

extension PickyMarkdownInlineTextView {
    /// Public so unit tests can assert the produced string layout. The scale
    /// argument is forwarded into the rendered attributed string so a
    /// ⌘+ / ⌘- triggered rebuild produces fonts at the new size; if scale
    /// is omitted (call sites that predate the global app font scale, or
    /// previews), the live `PickyAppFontScaleStore.staticCGScale` is used.
    static func buildAttributedString(
        from blocks: [InlineBlock],
        scale: CGFloat? = nil
    ) -> NSAttributedString {
        let effectiveScale = scale ?? PickyAppFontScaleStore.staticCGScale
        let key = cacheKey(blocks, scale: effectiveScale) as NSString
        if let cached = attributedCache.object(forKey: key) {
            return cached
        }
        // computeAttributedString reads `PickyHUDTypography.Size.*` which is
        // already derived from the live `PickyAppFontScaleStore.staticScale`,
        // so we don't need to thread the scale argument through; the
        // attributed string it returns is already sized at `effectiveScale`.
        let built = computeAttributedString(from: blocks)
        attributedCache.setObject(built, forKey: key, cost: built.length)
        return built
    }

    /// Joined per-block representation plus the live font scale. The scale
    /// component is critical — without it the NSCache would return a stale
    /// pre-scale attributed string when the user hits ⌘+ / ⌘- and the
    /// `updateNSView` rebuild would silently skip the new size.
    fileprivate static func cacheKey(_ blocks: [InlineBlock], scale: CGFloat) -> String {
        let body = blocks.map { block in
            switch block {
            case .heading(let level, let text): return "h\(level)\u{1F}\(text)"
            case .paragraph(let text): return "p\u{1F}\(text)"
            case .bullet(let text): return "b\u{1F}\(text)"
            }
        }.joined(separator: "\n")
        return "\(body)\u{1E}s\(scale)"
    }

    private static func computeAttributedString(from blocks: [InlineBlock]) -> NSAttributedString {
        let renderer = PickyReportMarkdownRenderer()
        let textPrimary = NSColor(DS.Colors.textPrimary)
        let textSecondary = NSColor(DS.Colors.textSecondary)
        let linkColor = NSColor(DS.Colors.accentText)
        let bodyFont = NSFont.systemFont(ofSize: PickyHUDTypography.Size.body, weight: .regular)
        let bulletLeaderFont = NSFont.systemFont(ofSize: PickyHUDTypography.Size.body, weight: .semibold)
        // Scale paragraph gaps with the live app font scale so the bubble's
        // vertical rhythm stays in proportion when the user pumps the body
        // size up. NSTextView's per-line leading already scales via the
        // font's natural metrics; paragraph-level spacing has to be applied
        // explicitly here.
        let scale = PickyAppFontScaleStore.staticCGScale
        let scaledBlockSpacing = blockSpacing * scale
        let scaledBulletLeader = bulletLeaderIndent * scale

        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            let piece: NSAttributedString
            switch block {
            case .heading(let level, let text):
                piece = renderHeading(
                    text: text,
                    level: level,
                    renderer: renderer,
                    textColor: textPrimary,
                    linkColor: linkColor,
                    paragraphSpacing: scaledBlockSpacing,
                    isLast: isLast
                )
            case .paragraph(let text):
                piece = renderParagraph(
                    text: text,
                    renderer: renderer,
                    baseFont: bodyFont,
                    textColor: textPrimary,
                    linkColor: linkColor,
                    paragraphSpacing: scaledBlockSpacing,
                    isLast: isLast
                )
            case .bullet(let text):
                piece = renderBullet(
                    text: text,
                    renderer: renderer,
                    leaderFont: bulletLeaderFont,
                    leaderColor: textSecondary,
                    bodyFont: bodyFont,
                    textColor: textPrimary,
                    linkColor: linkColor,
                    leaderIndent: scaledBulletLeader,
                    paragraphSpacing: scaledBlockSpacing,
                    isLast: isLast
                )
            }
            result.append(piece)
            if !isLast {
                // Single newline between blocks; per-block paragraphSpacing
                // adds the visual gap (matches VStack spacing: 5).
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func renderHeading(
        text: String,
        level: Int,
        renderer: PickyReportMarkdownRenderer,
        textColor: NSColor,
        linkColor: NSColor,
        paragraphSpacing: CGFloat,
        isLast: Bool
    ) -> NSAttributedString {
        let size: CGFloat
        switch level {
        case 1: size = PickyHUDTypography.Size.heading1
        case 2: size = PickyHUDTypography.Size.heading2
        default: size = PickyHUDTypography.Size.heading3
        }
        let baseFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let attr = renderInline(text, baseFont: baseFont, baseColor: textColor, linkColor: linkColor)
        applyParagraphStyle(to: attr, headIndent: 0, paragraphSpacing: paragraphSpacing, isLast: isLast)
        return attr
    }

    private static func renderParagraph(
        text: String,
        renderer: PickyReportMarkdownRenderer,
        baseFont: NSFont,
        textColor: NSColor,
        linkColor: NSColor,
        paragraphSpacing: CGFloat,
        isLast: Bool
    ) -> NSAttributedString {
        let attr = renderInline(text, baseFont: baseFont, baseColor: textColor, linkColor: linkColor)
        applyParagraphStyle(to: attr, headIndent: 0, paragraphSpacing: paragraphSpacing, isLast: isLast)
        return attr
    }

    private static func renderBullet(
        text: String,
        renderer: PickyReportMarkdownRenderer,
        leaderFont: NSFont,
        leaderColor: NSColor,
        bodyFont: NSFont,
        textColor: NSColor,
        linkColor: NSColor,
        leaderIndent: CGFloat,
        paragraphSpacing: CGFloat,
        isLast: Bool
    ) -> NSAttributedString {
        let leader = NSMutableAttributedString(
            string: "•\t",
            attributes: [
                .font: leaderFont,
                .foregroundColor: leaderColor
            ]
        )
        let body = renderInline(text, baseFont: bodyFont, baseColor: textColor, linkColor: linkColor)
        leader.append(body)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = isLast ? 0 : paragraphSpacing
        style.firstLineHeadIndent = 0
        style.headIndent = leaderIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: leaderIndent)]
        style.defaultTabInterval = leaderIndent
        leader.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: leader.length))
        return leader
    }

    // MARK: - Helpers

    /// Parses `text` as inline-only markdown and walks the resulting
    /// `AttributedString.runs` once, projecting each run's typed attributes
    /// (`inlinePresentationIntent`, `link`) into concrete NSFont + NSColor
    /// values on top of `baseFont`/`baseColor`.
    ///
    /// We can't reuse `PickyReportMarkdownRenderer.inlineAttributedString` +
    /// `NSAttributedString(attributed:)` here because that conversion path
    /// keeps inline emphasis as the typed `inlinePresentationIntent`
    /// attribute rather than flattening it to `.font` runs, so a downstream
    /// `enumerateAttribute(.font, ...)` pass sees a single run and the bold
    /// inside `**bold**` would be lost. Reading the AttributedString runs
    /// directly is the only stable way to project intents into NSFont
    /// traits.
    private static func renderInline(
        _ text: String,
        baseFont: NSFont,
        baseColor: NSColor,
        linkColor: NSColor
    ) -> NSMutableAttributedString {
        let attributed: AttributedString
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let parsed = try? AttributedString(markdown: text, options: options) {
            attributed = parsed
        } else {
            attributed = AttributedString(text)
        }

        let result = NSMutableAttributedString()
        for run in attributed.runs {
            let substring = String(attributed[run.range].characters)
            guard !substring.isEmpty else { continue }

            var traits = baseFont.fontDescriptor.symbolicTraits
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
            }
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
            let font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: run.link != nil ? linkColor : baseColor
            ]
            if let link = run.link {
                attrs[.link] = link
            }
            result.append(NSAttributedString(string: substring, attributes: attrs))
        }
        return result
    }

    private static func applyParagraphStyle(
        to attr: NSMutableAttributedString,
        headIndent: CGFloat,
        paragraphSpacing: CGFloat,
        isLast: Bool
    ) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = isLast ? 0 : paragraphSpacing
        style.firstLineHeadIndent = headIndent
        style.headIndent = headIndent
        attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attr.length))
    }

    private static let attributedCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 512
        cache.totalCostLimit = 1 * 1024 * 1024
        return cache
    }()
}

// MARK: - Self-sizing NSTextView

/// NSTextView subclass that reports its layout-driven height to SwiftUI via
/// `intrinsicContentSize`. Width comes from the SwiftUI layout (the SwiftUI
/// `.frame(maxWidth: .infinity)` on the wrapper); the text view keeps its
/// container width in sync with `frame.width` so wrapping recalculates when
/// the parent card resizes.
final class SelfSizingMarkdownTextView: NSTextView {
    var fillsAvailableWidth: Bool = true {
        didSet {
            guard fillsAvailableWidth != oldValue else { return }
            updateHorizontalSizingPriority()
            invalidateIntrinsicContentSize()
        }
    }

    var hugContentMaxWidth: CGFloat? {
        didSet {
            guard hugContentMaxWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    var onOpenAsReport: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onEditText: (() -> Void)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        allowsUndo = false
        smartInsertDeleteEnabled = false
        updateHorizontalSizingPriority()
        // Links come from the attributed string; don't let NSTextView add
        // ad-hoc data detectors which would conflict with our deep-link
        // dispatcher.
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        // Fallback for hosts that don't call `sizeThatFits` (older AppKit
        // entry points / test environments). The representable's
        // `sizeThatFits` is the canonical sizing path; this keeps both
        // height and hug-mode width honest when SwiftUI falls back to
        // AppKit intrinsic sizing.
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize
        }

        if !fillsAvailableWidth, let cap = intrinsicHugWidthCap {
            let measured = measureUsedSize(forWidth: cap)
            return NSSize(width: min(ceil(measured.width), cap), height: ceil(measured.height))
        }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged, let textContainer {
            textContainer.size = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager?.ensureLayout(for: textContainer)
            invalidateIntrinsicContentSize()
        }
    }

    private var intrinsicHugWidthCap: CGFloat? {
        if let hugContentMaxWidth, hugContentMaxWidth.isFinite, hugContentMaxWidth > 0 {
            return hugContentMaxWidth
        }
        if frame.width.isFinite, frame.width > 0 {
            return frame.width
        }
        return nil
    }

    private func updateHorizontalSizingPriority() {
        let priority: NSLayoutConstraint.Priority = fillsAvailableWidth ? .defaultLow : .required
        setContentHuggingPriority(priority, for: .horizontal)
        setContentCompressionResistancePriority(priority, for: .horizontal)
    }

    /// Layout the text at `width` and return the layout manager's used
    /// rect. Restores the previous container width afterwards so the next
    /// `setFrameSize` / `intrinsicContentSize` pass stays consistent with
    /// whatever SwiftUI ultimately chooses.
    func measureUsedSize(forWidth width: CGFloat) -> NSSize {
        guard let layoutManager, let textContainer else { return .zero }
        let previousWidth = textContainer.size.width
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).size
        if previousWidth != width {
            textContainer.size = NSSize(width: previousWidth, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
        }
        return used
    }

    /// Adds Picky-specific actions (today: "Open as Report") to the native
    /// NSTextView right-click menu so users keep Copy / Look Up / Translate
    /// / Speech / Services while gaining the report shortcut that used to
    /// live in the SwiftUI `.contextMenu`.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if onCopyText != nil || onEditText != nil || onOpenAsReport != nil {
            menu.addItem(.separator())
        }
        if onCopyText != nil {
            let item = NSMenuItem(title: "Copy Text", action: #selector(copyTextClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if onEditText != nil {
            let item = NSMenuItem(title: "Edit in Composer", action: #selector(editTextClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if onOpenAsReport != nil {
            let item = NSMenuItem(
                title: "Open as Report",
                action: #selector(openAsReportClicked),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func copyTextClicked() {
        onCopyText?()
    }

    @objc private func editTextClicked() {
        onEditText?()
    }

    @objc private func openAsReportClicked() {
        onOpenAsReport?()
    }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }
}
