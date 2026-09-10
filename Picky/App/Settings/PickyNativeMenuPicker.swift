import AppKit
import SwiftUI

private struct PickyUsesSubtleMenuChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Opts a native popup into Picky's quiet control chrome while retaining
    /// AppKit's menu, keyboard navigation, accessibility, and focus behavior.
    var pickyUsesSubtleMenuChrome: Bool {
        get { self[PickyUsesSubtleMenuChromeKey.self] }
        set { self[PickyUsesSubtleMenuChromeKey.self] = newValue }
    }
}

struct PickyNativeMenuOption<Value: Hashable>: Equatable {
    let value: Value
    let title: String
}

/// Keeps AppKit's keyboard/accessibility behavior without SwiftUI rebuilding
/// attributed menu labels when the window's focus environment changes.
struct PickyNativeMenuPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [PickyNativeMenuOption<Value>]
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.pickyUsesSubtleMenuChrome) private var usesSubtleMenuChrome

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PickySubtleMenuPopUpButton(frame: .zero, pullsDown: false)
        button.menu = NSMenu()
        button.menu?.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.apply(
            to: button, title: title, selection: $selection, options: options,
            isEnabled: isEnabled, controlSize: nativeControlSize, fontScale: fontScale,
            usesSubtleMenuChrome: usesSubtleMenuChrome
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    private var nativeControlSize: NSControl.ControlSize {
        switch controlSize {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
    }

    final class Coordinator: NSObject {
        private var selection: Binding<Value>
        private var appliedOptions: [PickyNativeMenuOption<Value>] = []
        private var appliedTitle: String?
        private var appliedControlSize: NSControl.ControlSize?
        private var appliedFontScale: CGFloat?

        init(selection: Binding<Value>) { self.selection = selection }

        /// The menu and its items are retained on focus-only, selection-only,
        /// enabled-state, and chrome-only updates. This is a tested native-work contract.
        func apply(
            to button: NSPopUpButton,
            title: String,
            selection: Binding<Value>,
            options: [PickyNativeMenuOption<Value>],
            isEnabled: Bool,
            controlSize: NSControl.ControlSize,
            fontScale: CGFloat,
            usesSubtleMenuChrome: Bool
        ) {
            self.selection = selection
            if appliedOptions != options {
                PickyPerf.interval("settings_native_menu_update") {
                    if appliedOptions.map(\.value) == options.map(\.value) {
                        for (index, option) in options.enumerated() where appliedOptions[index].title != option.title {
                            button.item(at: index)?.title = option.title
                        }
                    } else {
                        button.removeAllItems()
                        // addItem(withTitle:) deduplicates equal titles. Distinct values
                        // may legitimately share a display name, so append NSMenuItems.
                        for option in options {
                            button.menu?.addItem(NSMenuItem(title: option.title, action: nil, keyEquivalent: ""))
                        }
                    }
                }
                appliedOptions = options
            }
            let index = options.firstIndex { $0.value == selection.wrappedValue } ?? -1
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
            let enabled = isEnabled && !options.isEmpty
            if button.isEnabled != enabled { button.isEnabled = enabled }
            if appliedTitle != title {
                button.setAccessibilityLabel(title)
                appliedTitle = title
            }
            if appliedControlSize != controlSize || appliedFontScale != fontScale {
                button.controlSize = controlSize
                // design-token-exception: retain native popup metrics at the user's app font scale
                let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize) * fontScale)
                button.font = font
                button.menu?.font = font
                appliedControlSize = controlSize
                appliedFontScale = fontScale
            }
            // Chrome updates are visual-only. Calling this on every update also keeps
            // its 30pt component metric proportional to a changed app font scale.
            (button as? PickySubtleMenuPopUpButton)?.setUsesSubtleMenuChrome(usesSubtleMenuChrome, fontScale: fontScale)
            let selectedTitle = button.titleOfSelectedItem ?? ""
            button.toolTip = selectedTitle.isEmpty ? nil : selectedTitle
            button.setAccessibilityHelp(selectedTitle.isEmpty ? nil : selectedTitle)
        }

        @objc func selectionChanged(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard button.isEnabled, appliedOptions.indices.contains(index) else { return }
            let value = appliedOptions[index].value
            guard value != selection.wrappedValue else { return }
            selection.wrappedValue = value
        }
    }
}

/// The standard `NSPopUpButton` interaction is intentionally retained. This subclass
/// only replaces its drawing when the enclosing SwiftUI view opts in to quiet chrome.
private final class PickySubtleMenuPopUpButton: NSPopUpButton {
    // Component metric: 30pt at 100% gives settings menus a stable target without
    // making them read like large buttons. It scales with the user's app font size.
    private static let baseControlHeight: CGFloat = 30

    private var usesSubtleMenuChrome = false
    private var fontScale: CGFloat = 1
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    func setUsesSubtleMenuChrome(_ enabled: Bool, fontScale: CGFloat) {
        let changed = usesSubtleMenuChrome != enabled || self.fontScale != fontScale
        usesSubtleMenuChrome = enabled
        self.fontScale = fontScale
        if changed {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard usesSubtleMenuChrome else { return size }
        let titleWidth = ((titleOfSelectedItem ?? "") as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        let contentWidth = titleWidth + (DS.Spacing.space2 + DS.Spacing.space5) * fontScale
        return NSSize(width: max(size.width, ceil(contentWidth)), height: max(size.height, Self.baseControlHeight * fontScale))
    }

    override var focusRingMaskBounds: NSRect {
        usesSubtleMenuChrome ? bounds : super.focusRingMaskBounds
    }

    override func drawFocusRingMask() {
        guard usesSubtleMenuChrome else {
            super.drawFocusRingMask()
            return
        }
        NSBezierPath(roundedRect: bounds, xRadius: DS.CornerRadius.control, yRadius: DS.CornerRadius.control).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else { return }
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesSubtleMenuChrome else {
            super.draw(dirtyRect)
            return
        }

        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let fill: NSColor
        if !isEnabled {
            fill = NSColor(DS.Colors.disabledBackground)
        } else if isHighlighted {
            fill = NSColor(DS.Colors.surface4)
        } else if isHovered {
            fill = NSColor(DS.Colors.surface3)
        } else {
            fill = NSColor(DS.Colors.surface2)
        }
        let border = NSColor(increaseContrast ? DS.Colors.borderStrong : DS.Colors.borderSubtle)
        let textColor = NSColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.disabledText)

        let controlPath = NSBezierPath(roundedRect: bounds, xRadius: DS.CornerRadius.control, yRadius: DS.CornerRadius.control)
        fill.setFill()
        controlPath.fill()
        border.setStroke()
        controlPath.lineWidth = 1
        controlPath.stroke()

        let chevronWidth = DS.Spacing.space2 * fontScale
        let chevronCenterX = bounds.maxX - DS.Spacing.space3 * fontScale
        let chevronCenterY = bounds.midY
        let chevron = NSBezierPath()
        let chevronDirection: CGFloat = isFlipped ? -1 : 1
        let chevronHalfHeight = DS.Spacing.space1 * fontScale / 2 * chevronDirection
        chevron.move(to: NSPoint(x: chevronCenterX - chevronWidth / 2, y: chevronCenterY + chevronHalfHeight))
        chevron.line(to: NSPoint(x: chevronCenterX, y: chevronCenterY - chevronHalfHeight))
        chevron.line(to: NSPoint(x: chevronCenterX + chevronWidth / 2, y: chevronCenterY + chevronHalfHeight))
        chevron.lineWidth = 1
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        textColor.setStroke()
        chevron.stroke()

        let titleRect = NSRect(
            x: bounds.minX + DS.Spacing.space2 * fontScale,
            y: bounds.minY,
            width: max(0, bounds.width - (DS.Spacing.space2 + DS.Spacing.space5) * fontScale),
            height: bounds.height
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(
            string: titleOfSelectedItem ?? "",
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let titleHeight = min(title.size().height, titleRect.height)
        let centeredTitleRect = NSRect(
            x: titleRect.minX,
            y: bounds.midY - titleHeight / 2,
            width: titleRect.width,
            height: titleHeight
        )
        title.draw(
            with: centeredTitleRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }
}
