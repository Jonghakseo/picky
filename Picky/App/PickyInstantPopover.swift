import AppKit
import SwiftUI

/// SwiftUI's popover modifier does not expose AppKit's presentation animation.
/// Keep one native, transient NSPopover implementation for app popovers so
/// Escape, outside-click dismissal, anchoring, and binding ownership agree.
extension View {
    func pickyInstantPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge? = nil,
        presentationIdentity: @escaping () -> AnyHashable? = { nil },
        dismissOnAnchorRemoval: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(PickyInstantPopoverAnchor(
            isPresented: isPresented,
            arrowEdge: arrowEdge,
            presentationIdentity: presentationIdentity,
            dismissOnAnchorRemoval: dismissOnAnchorRemoval,
            content: content
        ))
    }
}

private final class PickyInstantPopoverPositioningView: NSView {
    var onWindowChange: (() -> Void)?

    // The positioning view fills the button's background but never steals its clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

private final class PickyInstantPopoverHostingController: NSHostingController<AnyView> {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct PickyInstantPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge?
    let presentationIdentity: () -> AnyHashable?
    let dismissOnAnchorRemoval: Bool
    let content: () -> Content

    // A separate NSHostingController does not inherit SwiftUI's parent
    // environment. Carry the values used by popover content across the bridge.
    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PickyInstantPopoverPositioningView {
        let view = PickyInstantPopoverPositioningView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.showIfNeeded(in: view)
        }
        return view
    }

    func updateNSView(_ view: PickyInstantPopoverPositioningView, context: Context) {
        context.coordinator.update(
            in: view,
            isPresented: isPresented,
            binding: $isPresented,
            options: .init(
                arrowEdge: arrowEdge,
                presentationIdentity: presentationIdentity,
                dismissOnAnchorRemoval: dismissOnAnchorRemoval
            ),
            content: {
                AnyView(content()
                    .environment(\.pickyAppFontScale, fontScale)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.locale, locale)
                    .environment(\.layoutDirection, layoutDirection)
                    .disabled(!isEnabled))
            }
        )
    }

    static func dismantleNSView(_ view: PickyInstantPopoverPositioningView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.tearDown()
    }

    struct PresentationOptions {
        let arrowEdge: Edge?
        let presentationIdentity: () -> AnyHashable?
        let dismissOnAnchorRemoval: Bool
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        private let popover = NSPopover()
        private var host: PickyInstantPopoverHostingController?
        private var binding: Binding<Bool>?
        private var content: (() -> AnyView)?
        private var arrowEdge: Edge?
        private var presentationIdentity: (() -> AnyHashable?)?
        private var activeIdentity: AnyHashable?
        private var closingIdentity: AnyHashable?
        private var dismissOnAnchorRemoval = true
        private var requested = false
        private var dismissalPending = false
        private var generation = 0
        private var tornDown = false

        override init() {
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
        }

        func update(
            in view: NSView,
            isPresented: Bool,
            binding: Binding<Bool>,
            options: PresentationOptions,
            content: @escaping () -> AnyView
        ) {
            self.binding = binding
            self.arrowEdge = options.arrowEdge
            self.presentationIdentity = options.presentationIdentity
            self.dismissOnAnchorRemoval = options.dismissOnAnchorRemoval
            self.content = content
            if !isPresented {
                requested = false
                dismissalPending = false
                if popover.isShown { popover.close() }
                return
            }
            // A different calendar day or row can be selected by the same
            // outside click that closed the previous popover. That new identity
            // must not be swallowed by the old dismissal handoff.
            if dismissalPending {
                guard options.presentationIdentity() != closingIdentity else { return }
                dismissalPending = false
            }
            requested = true
            if popover.isShown {
                activeIdentity = options.presentationIdentity()
                popover.appearance = view.effectiveAppearance
                host?.rootView = content()
                resizeToFit()
            } else {
                showIfNeeded(in: view)
            }
        }

        func showIfNeeded(in view: NSView) {
            guard !tornDown, !dismissalPending, requested, !popover.isShown, view.window != nil,
                  let content else { return }
            generation += 1
            activeIdentity = presentationIdentity?()
            let host = PickyInstantPopoverHostingController(rootView: content())
            host.sizingOptions = [.preferredContentSize]
            host.onCancel = { [weak self] in self?.popover.close() }
            self.host = host
            popover.appearance = view.effectiveAppearance
            popover.contentViewController = host
            resizeToFit()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: arrowEdge.nsRectEdge)
        }

        private func resizeToFit() {
            guard let host else { return }
            let size = host.sizeThatFits(in: CGSize(width: 640, height: 700))
            if size.width.isFinite, size.height.isFinite,
               size.width > 0, size.height > 0, popover.contentSize != size {
                popover.contentSize = size
            }
        }

        func popoverDidClose(_ notification: Notification) {
            host = nil
            guard requested else { return }
            requested = false
            dismissalPending = true
            closingIdentity = activeIdentity
            let closedGeneration = generation
            // AppKit can close during a SwiftUI update. The generation and
            // current source identity protect a newer selection on the same
            // anchor even if SwiftUI has not re-evaluated the presenter yet.
            Task { @MainActor [weak self] in
                guard let self, !self.tornDown, self.generation == closedGeneration,
                      self.dismissalPending, !self.popover.isShown else { return }
                if self.presentationIdentity?() == self.closingIdentity {
                    self.binding?.wrappedValue = false
                }
                self.dismissalPending = false
            }
        }

        func tearDown() {
            let wasPresented = requested || dismissalPending || popover.isShown
            let binding = binding
            let identity = presentationIdentity?()
            let currentIdentity = presentationIdentity
            let shouldDismiss = dismissOnAnchorRemoval
            tornDown = true
            requested = false
            dismissalPending = false
            content = nil
            popover.delegate = nil
            if popover.isShown { popover.close() }
            host = nil
            self.binding = nil
            presentationIdentity = nil
            if wasPresented, shouldDismiss {
                Task { @MainActor in
                    guard currentIdentity?() == identity, binding?.wrappedValue == true else { return }
                    binding?.wrappedValue = false
                }
            }
        }
    }
}

private extension Optional where Wrapped == Edge {
    var nsRectEdge: NSRectEdge {
        switch self {
        case .top, nil: .maxY
        case .bottom: .minY
        case .leading: .minX
        case .trailing: .maxX
        }
    }
}
