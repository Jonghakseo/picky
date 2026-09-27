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
    @Environment(\.colorScheme) private var colorScheme

    private var horizontal: Bool { dockSide.orientation == .horizontal }

    var body: some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: metrics.chromeSpacing))
            : AnyLayout(VStackLayout(spacing: metrics.chromeSpacing))
        layout {
            content()
            Rectangle().fill(DS.Colors.borderSubtle)
                .frame(width: horizontal ? 1 : metrics.collapseNotchWidth,
                       height: horizontal ? metrics.collapseNotchWidth : 1)
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
        let style = PickyHUDDockSurfacePresentation.style(for: colorScheme)
        return PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1, material: style.materialKind.material)
            .overlay(shape.fill(DS.Colors.surface1.opacity(style.surfaceOverlayOpacity)))
            .overlay(shape.strokeBorder(DS.Colors.borderSubtle.opacity(style.borderOpacity), lineWidth: 0.8))
            .compositingGroup()
            .shadow(color: .black.opacity(PickyHUDExpansion.dockShadowOpacity),
                    radius: PickyHUDExpansion.dockShadowRadius, y: PickyHUDExpansion.dockShadowYOffset)
            .shadow(color: .black.opacity(PickyHUDExpansion.dockTightShadowOpacity),
                    radius: PickyHUDExpansion.dockTightShadowRadius, y: PickyHUDExpansion.dockTightShadowYOffset)
    }
}

/// An inset pocket connected to the outer edge, rather than a separate toolbar strip.
struct PickyHUDDockNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = min(rect.width / 4, rect.height)
        var path = Path()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: shoulder, y: rect.height),
                      control1: CGPoint(x: shoulder * 0.6, y: 0),
                      control2: CGPoint(x: shoulder * 0.25, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width, y: 0),
                      control1: CGPoint(x: rect.width - shoulder * 0.25, y: rect.height),
                      control2: CGPoint(x: rect.width - shoulder * 0.6, y: 0))
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
        let presentation = PickyHUDDockHandlePresentation.resolve(isActive: isActive)
        ZStack(alignment: .top) {
            PickyHUDDockNotchShape().fill(isActive ? DS.Colors.surface4 : DS.Colors.surface3)
            Capsule().fill(presentation.foregroundColor.opacity(presentation.opacity))
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
                    .font(.system(size: 9, weight: .semibold)) // design-token-exception: optical glyph inside the 11pt notch; hit area remains 24pt.
                    .foregroundStyle(active ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: horizontal ? metrics.notchDepth : metrics.collapseNotchWidth,
                           height: horizontal ? metrics.collapseNotchWidth : metrics.notchDepth)
            }
            .frame(width: horizontal ? metrics.utilityButtonSide : metrics.collapseNotchWidth,
                   height: horizontal ? metrics.collapseNotchWidth : metrics.utilityButtonSide)
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
    private let metrics = PickyHUDDockMetrics.medium
    @State private var hovered = false
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
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(L10n.t("dock.restore"))
        .accessibilityLabel(L10n.t("dock.restore"))
    }
}
