//
//  PickyHubModal.swift
//  Picky
//
//  Window-level modal presentation for the hub (video player, plugin detail,
//  confirmations). One host per window: pages call `present`, the root view
//  draws the backdrop + dialog above everything, and the page beneath is
//  disabled so keyboard focus cannot escape the dialog. `Esc`, backdrop click,
//  and the dialog's own buttons all funnel through `dismiss()` so the
//  `onDismiss` restores focus after SwiftUI re-enables the trigger. Replacing
//  a dialog suppresses prior restoration, while `onWillDismiss` still cleans up.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PickyHubModalHost: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    struct Presentation: Identifiable {
        let id = UUID()
        let width: CGFloat
        let accessibilityLabel: String
        let content: AnyView
        let canDismiss: () -> Bool
        let onWillDismiss: () -> Void
        let onDismiss: () -> Void
    }

    /// Logical modal ownership changes immediately so busy work and replacement
    /// requests never race with SwiftUI's rendering transaction.
    private(set) var presentation: Presentation?
    /// SwiftUI observes this copy only after the initiating action's view
    /// update unwinds. It is written before invalidation because `@Published`
    /// emits before its write, which can leave the old dialog mounted.
    private(set) var renderedPresentation: Presentation?
    /// The hub window; key events from other Picky windows are left alone.
    weak var window: NSWindow?
    private var escapeMonitor: Any?
    private var pendingDismissal: Presentation?
    private var capturedResponder: CapturedResponder?

    private final class CapturedResponder {
        weak var window: NSWindow?
        weak var responder: NSResponder?

        init(window: NSWindow?) {
            self.window = window
            responder = window?.firstResponder
        }
    }

    var isPresenting: Bool { presentation != nil }
    var presentationID: UUID? { presentation?.id }

    @discardableResult
    func present<Content: View>(
        width: CGFloat = 540,
        accessibilityLabel: String,
        canDismiss: @escaping () -> Bool = { true },
        onWillDismiss: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) -> UUID {
        let suppressesNativeRestoration = presentation != nil || pendingDismissal != nil
        if let current = presentation {
            guard current.canDismiss() else { return current.id }
            dismiss()
        }
        pendingDismissal = nil
        capturedResponder = suppressesNativeRestoration ? nil : CapturedResponder(window: window)
        let next = Presentation(
            width: width,
            accessibilityLabel: accessibilityLabel,
            content: AnyView(content()),
            canDismiss: canDismiss,
            onWillDismiss: onWillDismiss,
            onDismiss: onDismiss
        )
        presentation = next
        publishPresentation(next)
        installEscapeMonitor()
        return next.id
    }

    func dismiss() {
        guard let current = presentation, current.canDismiss() else { return }
        presentation = nil
        removeEscapeMonitor()
        pendingDismissal = current
        current.onWillDismiss()
        removeRenderedPresentation(id: current.id)
    }

    private func publishPresentation(_ presentation: Presentation) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation?.id == presentation.id else { return }
            self.renderedPresentation = presentation
            self.objectWillChange.send()
        }
    }

    private func removeRenderedPresentation(id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == nil,
                  self.pendingDismissal?.id == id,
                  self.renderedPresentation?.id == id else { return }
            self.renderedPresentation = nil
            self.objectWillChange.send()
        }
    }

    /// `onDisappear` confirms that SwiftUI removed the overlay. The next main
    /// turn is outside that view update, so AppKit can safely restore the
    /// responder captured before presentation. Caller focus-state callbacks
    /// remain a fallback for controls without a native responder.
    func presentationDidDisappear(id: UUID) {
        guard presentation == nil, pendingDismissal?.id == id else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == nil,
                  let pending = self.pendingDismissal, pending.id == id else { return }
            self.pendingDismissal = nil
            self.restoreCapturedResponder()
            pending.onDismiss()
        }
    }

    private func restoreCapturedResponder() {
        defer { capturedResponder = nil }
        guard let capturedResponder,
              let capturedWindow = capturedResponder.window,
              capturedWindow === window,
              let responder = capturedResponder.responder,
              responderBelongsToHubWindow(responder, window: capturedWindow) else { return }
        // SwiftUI can keep its hosting view as first responder while the
        // dialog is up. Force a public AppKit resign/become cycle so the
        // restored responder receives a fresh focus transition.
        capturedWindow.makeFirstResponder(nil)
        capturedWindow.makeFirstResponder(responder)
    }

    private func responderBelongsToHubWindow(_ responder: NSResponder, window: NSWindow) -> Bool {
        if responder === window { return true }
        guard let view = responder as? NSView, let contentView = window.contentView else { return false }
        return view === contentView || view.isDescendant(of: contentView)
    }

    /// `onExitCommand` only fires while a SwiftUI view inside the dialog owns
    /// focus. The local monitor covers the moment right after presentation
    /// (before the dialog's first responder is set) and any focus-less state.
    private func installEscapeMonitor() {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.presentation != nil else { return event }
            guard event.keyCode == 53 else { return event }
            if let window = self.window, let eventWindow = event.window, eventWindow !== window { return event }
            self.dismiss()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

/// Draws the current modal above `content`. Mount once at the window root.
struct PickyHubModalOverlay<Content: View>: View {
    @ObservedObject var host: PickyHubModalHost
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Keep SwiftUI's visual branch in `@State`. The host owns logical modal
    /// lifetime, while this local projection consumes its post-write
    /// invalidation without re-entering a button's update transaction.
    @State private var renderedPresentation: PickyHubModalHost.Presentation?

    var body: some View {
        ZStack {
            content()
                .disabled(host.isPresenting)
                .accessibilityHidden(host.isPresenting)

            if let presentation = renderedPresentation {
                PickyHubTheme.Colors.modalBackdrop
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { host.dismiss() }
                    .accessibilityHidden(true)
                    .transition(.opacity)

                ViewThatFits(in: .vertical) {
                    presentation.content
                    ScrollView { presentation.content }
                }
                    .frame(maxWidth: presentation.width)
                    .background(
                        RoundedRectangle(cornerRadius: PickyHubTheme.Radius.modal, style: .continuous)
                            .fill(PickyHubTheme.Colors.modal)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PickyHubTheme.Radius.modal, style: .continuous)
                            .stroke(PickyHubTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.modal, style: .continuous))
                    .shadow(
                        color: PickyHubTheme.Shadow.modalColor,
                        radius: PickyHubTheme.Shadow.modalRadius,
                        x: 0,
                        y: PickyHubTheme.Shadow.modalY
                    )
                    .padding(PickyHubTheme.Spacing.group)
                    .onExitCommand { host.dismiss() }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .id(presentation.id)
                    .onDisappear { host.presentationDidDisappear(id: presentation.id) }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onAppear { renderedPresentation = host.renderedPresentation }
        .onReceive(host.objectWillChange) { _ in
            renderedPresentation = host.renderedPresentation
        }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.modal, value: renderedPresentation?.id)
    }
}

/// Header row shared by hub dialogs: eyebrow meta, title, close glyph.
struct PickyHubModalHeader: View {
    var meta: String?
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
                Text(title)
                    .pickyFont(size: PickyHubTheme.Typography.modalTitle, weight: .bold)
                    .tracking(-0.6)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            if let onClose {
                PickyHubModalCloseButton(action: onClose)
            }
        }
    }
}

struct PickyHubModalCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .pickyFont(size: 12, weight: .bold)
                .foregroundColor(isHovering ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textTertiary)
                .frame(width: PickyHubTheme.Control.minimumHeight, height: PickyHubTheme.Control.minimumHeight)
                .background(Circle().fill(isHovering ? PickyHubTheme.Colors.navHighlight : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Control.minimumHeight / 2)
        .onHover { isHovering = $0 }
        .help(Text("common.close"))
        .accessibilityLabel(Text("common.close"))
        .onAppear { isFocused = true }
    }
}

/// Two-button confirmation dialog body (mockup `.plugin-confirm-dialog`).
struct PickyHubConfirmDialog: View {
    let title: String
    let message: String
    var confirmTitle: LocalizedStringKey
    var confirmRole: PickyHubButtonRole = .danger
    var isBusy = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .pickyFont(size: 18, weight: .bold)
                .tracking(-0.5)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                PickyHubButton(title: "common.cancel", role: .secondary, isEnabled: !isBusy, action: onCancel)
                    .focused($cancelFocused)
                PickyHubButton(title: confirmTitle, role: confirmRole, isBusy: isBusy, action: onConfirm)
            }
            .padding(.top, PickyHubTheme.Spacing.field)
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .onAppear { cancelFocused = true }
    }
}
