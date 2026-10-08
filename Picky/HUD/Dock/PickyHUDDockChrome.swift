import AppKit
import SwiftUI

/// Shared production shell, also used by the offscreen dock gallery.
struct PickyHUDDockChrome<Content: View, Utilities: View, Handle: View>: View, @preconcurrency Animatable {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    let railLength: CGFloat
    let crossSize: CGFloat
    let onMinimize: () -> Void
    var compactWidth: CGFloat? = nil
    /// Target width of the lane that holds the handle and collapse notch.
    /// The rail's width at the screen edge; the full shell width to center them.
    var compactControlsWidth: CGFloat = PickyHUDDockCompactLayout.iconColumnWidth
    @ViewBuilder var content: () -> Content
    @ViewBuilder var utilities: () -> Utilities
    @ViewBuilder var handle: () -> Handle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lane width on screen. It follows `compactControlsWidth` in a separate
    /// transaction so only this width animates. An implicit animation on the
    /// lanes would also interpolate their position when a HUD open resizes the
    /// panel, so the collapse notch would fly across the rows to the bottom.
    @State private var displayedControlsWidth: CGFloat?

    /// Same curve and duration as the shell's expansion, so a collapsing
    /// centered lane stays aligned with the shrinking shell.
    private var controlLaneAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private var horizontal: Bool { dockSide.orientation == .horizontal }

    var animatableData: CGFloat {
        get { compactWidth ?? crossSize }
        set { if compactWidth != nil { compactWidth = newValue } }
    }

    @ViewBuilder var body: some View {
        if let compactWidth, !horizontal {
            compactChrome(width: compactWidth)
        } else {
            classicChrome
        }
    }

    private var laneWidth: CGFloat { displayedControlsWidth ?? compactControlsWidth }

    private func compactChrome(width: CGFloat) -> some View {
        let alignment: Alignment = dockSide == .left ? .leading : .trailing
        let shape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        return VStack(spacing: metrics.chromeSpacing) {
            content()
            Rectangle().fill(DS.Colors.borderSubtle)
                .frame(height: metrics.chromeSeparatorThickness)
                .padding(.horizontal, DS.Spacing.space2)
            utilities()
        }
        .padding(.top, metrics.handleInset)
        .padding(.bottom, metrics.collapseInset)
        .frame(width: crossSize, height: railLength)
        // The content never reflows during expansion. Only the shell grows,
        // with the icon column anchored to the display-facing edge.
        .frame(width: width, alignment: alignment)
        .clipped()
        .contentShape(Rectangle())
        .background(surface)
        .overlay(alignment: dockSide == .left ? .topLeading : .topTrailing) {
            handle().frame(width: laneWidth)
        }
        .overlay(alignment: dockSide == .left ? .bottomLeading : .bottomTrailing) {
            PickyHUDDockCollapseNotch(dockSide: dockSide, metrics: metrics, onMinimize: onMinimize)
                .frame(width: laneWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: dockSide == .left ? .bottomLeading : .bottomTrailing)
                .clipShape(shape)
        }
        .background(PickyHUDVisibleChromeFrameReporter())
        // Runs after the HUD-open relayout has committed without animation,
        // so this transaction carries nothing but the lane width.
        .onChange(of: compactControlsWidth) { _, target in
            withAnimation(controlLaneAnimation) { displayedControlsWidth = target }
        }
        // The classic branch does not observe the target; start from it again.
        .onAppear { displayedControlsWidth = nil }
    }

    private var classicChrome: some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: metrics.chromeSpacing))
            : AnyLayout(VStackLayout(spacing: metrics.chromeSpacing))
        return layout {
            content()
            Rectangle().fill(DS.Colors.borderSubtle)
                .frame(width: horizontal ? metrics.chromeSeparatorThickness : metrics.collapseNotchWidth,
                       height: horizontal ? min(metrics.collapseNotchWidth, max(0, crossSize - 12)) : metrics.chromeSeparatorThickness)
            // Utilities sit side by side in both orientations: a thin
            // horizontal rail cannot stack two 24pt buttons.
            utilities()
                .frame(height: metrics.utilityButtonSide)
        }
        .padding(horizontal ? .vertical : .horizontal, metrics.horizontalPadding)
        .padding(horizontal ? .leading : .top, metrics.handleInset)
        .padding(horizontal ? .trailing : .bottom, metrics.collapseInset)
        .frame(width: horizontal ? railLength : crossSize,
               height: horizontal ? crossSize : railLength)
        .background(surface)
        .overlay(alignment: horizontal ? .leading : .top) { handle() }
        .overlay(alignment: horizontal ? .trailing : .bottom) {
            PickyHUDDockCollapseNotch(dockSide: dockSide, metrics: metrics, edgeLength: crossSize, onMinimize: onMinimize)
        }
    }

    private var surface: some View {
        let radius = horizontal
            ? metrics.horizontalShellCornerRadius(thickness: crossSize)
            : metrics.outerCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Group {
            if reduceTransparency { DS.Colors.surface1 }
            else { PickyHUDDockNativeMaterial().overlay(DS.Colors.dockShellScrim) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3) // design-token-exception: approved dual-notch shell elevation, shared across dock presets.
    }
}

/// An inset pocket connected to the outer edge, rather than a separate toolbar strip.
struct PickyHUDDockNotchShape: Shape {
    /// Width of each curved shoulder. Short notches use a smaller one so the
    /// flat floor stays long enough for the grip.
    var shoulder: CGFloat = PickyHUDDockMetrics.notchShoulder

    func path(in rect: CGRect) -> Path {
        let shoulder = min(shoulder, rect.width / 3)
        let scale = shoulder / 8
        var path = Path()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: shoulder, y: rect.height),
                      control1: CGPoint(x: 5 * scale, y: 0),
                      control2: CGPoint(x: 2 * scale, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width, y: 0),
                      control1: CGPoint(x: rect.width - 2 * scale, y: rect.height),
                      control2: CGPoint(x: rect.width - 5 * scale, y: 0))
        path.closeSubpath()
        return path
    }
}

struct PickyHUDDockHandleNotch: View {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    var isActive = false
    /// Length of the shell edge the notch sits on. A horizontal rail's end
    /// edge is its thickness; the notch shrinks to fit its straight part.
    var edgeLength: CGFloat? = nil

    var body: some View {
        let horizontal = dockSide.orientation == .horizontal
        // A vertical list's handle widens with the dock; a horizontal one fits its end edge.
        let notchWidth = horizontal
            ? metrics.horizontalNotchLength(preferred: metrics.horizontalHandleNotchWidth, thickness: edgeLength ?? .infinity)
            : metrics.handleNotchWidth
        let shoulder = PickyHUDDockMetrics.notchShoulder(notchLength: notchWidth)
        let gripWidth = horizontal
            ? PickyHUDDockMetrics.gripLength(preferred: metrics.horizontalHandleIdleWidth, notchLength: notchWidth)
            : metrics.handleIdleWidth
        ZStack(alignment: .top) {
            PickyHUDDockNotchShape(shoulder: shoulder).fill(DS.Colors.surface3)
            Capsule().fill(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: gripWidth, height: metrics.handleHeight)
                .padding(.top, DS.Spacing.space1)
        }
        .frame(width: notchWidth, height: metrics.notchDepth)
        .rotationEffect(.degrees(horizontal ? -90 : 0))
        .frame(width: horizontal ? metrics.notchDepth : notchWidth,
               height: horizontal ? notchWidth : metrics.notchDepth)
        .allowsHitTesting(false)
    }
}

struct PickyHUDDockCollapseNotch: View {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    var edgeLength: CGFloat? = nil
    let onMinimize: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let horizontal = dockSide.orientation == .horizontal
        let active = hovered || focused
        let notchWidth = horizontal
            ? metrics.horizontalNotchLength(preferred: metrics.collapseNotchWidth, thickness: edgeLength ?? .infinity)
            : metrics.collapseNotchWidth
        Button(action: onMinimize) {
            ZStack(alignment: horizontal ? .trailing : .bottom) {
                Color.clear
                PickyHUDDockNotchShape(shoulder: PickyHUDDockMetrics.notchShoulder(notchLength: notchWidth))
                    .fill(active ? DS.Colors.surface4 : DS.Colors.surface3)
                    .frame(width: notchWidth, height: metrics.notchDepth)
                    .rotationEffect(.degrees(horizontal ? 90 : 180))
                    .frame(width: horizontal ? metrics.notchDepth : notchWidth,
                           height: horizontal ? notchWidth : metrics.notchDepth)
                Image(systemName: horizontal ? "chevron.left" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold)) // design-token-exception: optical glyph inside the 11pt notch; hit area is collapseHitDepth.
                    .foregroundStyle(active ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: horizontal ? metrics.notchDepth : notchWidth,
                           height: horizontal ? notchWidth : metrics.notchDepth)
            }
            .frame(width: horizontal ? metrics.collapseHitDepth : notchWidth,
                   height: horizontal ? notchWidth : metrics.collapseHitDepth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .help(L10n.t("dock.minimize"))
        .accessibilityLabel(L10n.t("dock.minimize"))
    }
}

struct PickyHUDDockUtilityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed)
    }
    private struct Face<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hovered = false
        var body: some View {
            label
                .background(pressed ? DS.Colors.surface4 : (hovered ? DS.Colors.surface3 : .clear),
                            in: RoundedRectangle(cornerRadius: DS.CornerRadius.small))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// Count shown on the minimized dock for Pickles the user has not opened since they
/// completed, failed, or started waiting for input. Mirrors the expanded dock's unread dots.
enum PickyHUDDockMinimizedUnreadBadge {
    static func label(unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
        return unreadCount > 99 ? "99+" : "\(unreadCount)"
    }
}

struct PickyHUDDockMinimizedButton: View {
    let onRestore: () -> Void
    var unreadCount: Int = 0
    var onDragChanged: (CGPoint) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    private let metrics = PickyHUDDockMetrics.medium
    @State private var hovered = false
    @State private var dragging = false
    var body: some View {
        Button(action: onRestore) {
            Image("PickyCursorNormal").resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 21, height: 21) // design-token-exception: approved compact logo optical size in the fixed 32pt minimized dock.
                .frame(width: metrics.minimizedSide, height: metrics.minimizedSide)
                .background(hovered ? DS.Colors.surface3 : DS.Colors.surface1,
                            in: RoundedRectangle(cornerRadius: metrics.minimizedCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.minimizedCornerRadius)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.10), radius: 4, y: 2) // design-token-exception: approved 32pt restore-control elevation.
        }
        .buttonStyle(.plain)
        .overlay {
            PickyHUDDockAnchorHandleHost(
                onHoverChanged: { hovered = $0 },
                onDragChanged: { delta in dragging = true; onDragChanged(delta) },
                onDragEnded: { dragging = false; onDragEnded() },
                onDoubleClick: {}, onClick: onRestore
            )
            .accessibilityHidden(true)
        }
        .onDisappear {
            if dragging { dragging = false; onDragEnded() }
        }
        .overlay(alignment: .bottomTrailing) {
            if let label = PickyHUDDockMinimizedUnreadBadge.label(unreadCount: unreadCount) {
                Text(label)
                    .pickyFont(size: 10, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.notificationText)
                    .padding(.horizontal, DS.Spacing.space1)
                    .frame(minWidth: 14, minHeight: 14) // design-token-exception: compact count badge on the fixed 32pt minimized dock.
                    .background(DS.Colors.notification, in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.background, lineWidth: 1.2))
                    .offset(x: 5, y: 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help(unreadHelp)
        .accessibilityLabel(L10n.t("dock.restore"))
        .accessibilityValue(unreadCount > 0 ? L10n.t("dock.restore.unreadCount", unreadCount) : "")
        .accessibilityHint(L10n.t("dock.restore.help"))
    }

    private var unreadHelp: String {
        let help = L10n.t("dock.restore.help")
        guard unreadCount > 0 else { return help }
        return L10n.t("dock.restore.unreadCount", unreadCount) + "\n" + help
    }
}

/// Uses the same AppKit material as the approved standalone study.
struct PickyHUDDockNativeMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The utility label shares the session rows' fixed icon lane. Clipping the
/// shell hides names without moving either the icon or its popover anchor.
struct PickyHUDDockCompactUtilityLabel: View {
    let title: String
    let symbol: String
    let metrics: PickyHUDDockMetrics
    var height: CGFloat = 24
    @Environment(\.pickyDockCompactLayout) private var layout

    var body: some View {
        HStack(spacing: 0) {
            if layout?.iconOnLeadingEdge == true { icon }
            Text(title)
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(layout?.isExpanded == true ? 1 : 0)
                .accessibilityHidden(true)
            if layout?.iconOnLeadingEdge != true { icon }
        }
        .frame(width: metrics.listWidth, height: height)
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: metrics.plusFontSize, weight: .medium)) // design-token-exception: dock utility glyph.
            .frame(width: PickyHUDDockCompactLayout.iconColumnWidth, height: height)
    }
}
