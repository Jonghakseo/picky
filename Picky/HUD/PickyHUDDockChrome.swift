import AppKit
import SwiftUI

/// Shared production shell, also used by the offscreen dock gallery.
struct PickyHUDDockChrome<Content: View, Utilities: View, Handle: View>: View {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    let railLength: CGFloat
    let crossSize: CGFloat
    let onMinimize: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var utilities: () -> Utilities
    @ViewBuilder var handle: () -> Handle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var horizontal: Bool { dockSide.orientation == .horizontal }

    var body: some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: metrics.chromeSpacing))
            : AnyLayout(VStackLayout(spacing: metrics.chromeSpacing))
        layout {
            content()
            Rectangle().fill(DS.Colors.borderSubtle)
                .frame(width: horizontal ? metrics.chromeSeparatorThickness : metrics.collapseNotchWidth,
                       height: horizontal ? metrics.collapseNotchWidth : metrics.chromeSeparatorThickness)
            utilities()
                .frame(width: horizontal ? metrics.utilityButtonSide : nil,
                       height: horizontal ? nil : metrics.utilityButtonSide)
        }
        .padding(horizontal ? .vertical : .horizontal, metrics.horizontalPadding)
        .padding(horizontal ? .leading : .top, metrics.handleInset)
        .padding(horizontal ? .trailing : .bottom, metrics.collapseInset)
        .frame(width: horizontal ? railLength : crossSize,
               height: horizontal ? crossSize : railLength)
        .background(surface)
        .overlay(alignment: horizontal ? .leading : .top) { handle() }
        .overlay(alignment: horizontal ? .trailing : .bottom) {
            PickyHUDDockCollapseNotch(dockSide: dockSide, metrics: metrics, onMinimize: onMinimize)
        }
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        return Group {
            if reduceTransparency { DS.Colors.surface1 }
            else { PickyHUDDockNativeMaterial() }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3) // design-token-exception: approved dual-notch shell elevation, shared across dock presets.
    }
}

/// An inset pocket connected to the outer edge, rather than a separate toolbar strip.
struct PickyHUDDockNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = 8
        var path = Path()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: shoulder, y: rect.height),
                      control1: CGPoint(x: 5, y: 0),
                      control2: CGPoint(x: 2, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width, y: 0),
                      control1: CGPoint(x: rect.width - 2, y: rect.height),
                      control2: CGPoint(x: rect.width - 5, y: 0))
        path.closeSubpath()
        return path
    }
}

struct PickyHUDDockHandleNotch: View {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    var isActive = false

    var body: some View {
        let horizontal = dockSide.orientation == .horizontal
        ZStack(alignment: .top) {
            PickyHUDDockNotchShape().fill(DS.Colors.surface3)
            Capsule().fill(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: metrics.handleIdleWidth, height: metrics.handleHeight)
                .padding(.top, DS.Spacing.space1)
        }
        .frame(width: metrics.handleNotchWidth, height: metrics.notchDepth)
        .rotationEffect(.degrees(horizontal ? -90 : 0))
        .frame(width: horizontal ? metrics.notchDepth : metrics.handleNotchWidth,
               height: horizontal ? metrics.handleNotchWidth : metrics.notchDepth)
        .allowsHitTesting(false)
    }
}

struct PickyHUDDockCollapseNotch: View {
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    let onMinimize: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let horizontal = dockSide.orientation == .horizontal
        let active = hovered || focused
        Button(action: onMinimize) {
            ZStack(alignment: horizontal ? .trailing : .bottom) {
                Color.clear
                PickyHUDDockNotchShape().fill(active ? DS.Colors.surface4 : DS.Colors.surface3)
                    .frame(width: metrics.collapseNotchWidth, height: metrics.notchDepth)
                    .rotationEffect(.degrees(horizontal ? 90 : 180))
                    .frame(width: horizontal ? metrics.notchDepth : metrics.collapseNotchWidth,
                           height: horizontal ? metrics.collapseNotchWidth : metrics.notchDepth)
                Image(systemName: horizontal ? "chevron.left" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold)) // design-token-exception: optical glyph inside the 11pt notch; hit area is collapseHitDepth.
                    .foregroundStyle(active ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: horizontal ? metrics.notchDepth : metrics.collapseNotchWidth,
                           height: horizontal ? metrics.collapseNotchWidth : metrics.notchDepth)
            }
            .frame(width: horizontal ? metrics.collapseHitDepth : metrics.collapseNotchWidth,
                   height: horizontal ? metrics.collapseNotchWidth : metrics.collapseHitDepth)
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

struct PickyHUDDockMinimizedButton: View {
    let onRestore: () -> Void
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
        .help(L10n.t("dock.restore.help"))
        .accessibilityLabel(L10n.t("dock.restore"))
        .accessibilityHint(L10n.t("dock.restore.help"))
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
