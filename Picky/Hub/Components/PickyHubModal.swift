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
    struct Presentation: Identifiable {
        let id = UUID()
        let width: CGFloat
        let accessibilityLabel: String
        let content: AnyView
        let canDismiss: () -> Bool
        let onWillDismiss: () -> Void
        let onDismiss: () -> Void
    }

    /// Logical ownership clears immediately; SwiftUI observes the render phase.
    private(set) var presentation: Presentation?
    @Published private(set) var renderedPresentation: Presentation?
    /// The hub window; key events from other Picky windows are left alone.
    weak var window: NSWindow?
    private var escapeMonitor: Any?
    private var pendingDismissal: Presentation?

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
        if let current = presentation {
            guard current.canDismiss() else { return current.id }
            dismiss()
        }
        pendingDismissal = nil
        let next = Presentation(
            width: width,
            accessibilityLabel: accessibilityLabel,
            content: AnyView(content()),
            canDismiss: canDismiss,
            onWillDismiss: onWillDismiss,
            onDismiss: onDismiss
        )
        presentation = next
        renderedPresentation = next
        installEscapeMonitor()
        return next.id
    }

    func dismiss(ifPresenting presentationID: UUID?) {
        guard let presentationID, presentation?.id == presentationID else { return }
        dismiss()
    }

    func dismiss() {
        guard let current = presentation, current.canDismiss() else { return }
        presentation = nil
        removeEscapeMonitor()
        pendingDismissal = current
        current.onWillDismiss()

        // A SwiftUI button action can arrive during a view update. Do not
        // publish removal from that transaction: @Published sends before storing.
        let id = current.id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == nil,
                  self.pendingDismissal?.id == id,
                  self.renderedPresentation?.id == id else { return }
            // The overlay supplies its animation, including Reduce Motion.
            // Completion waits for exit transitions, unlike onDisappear.
            withAnimation(nil, completionCriteria: .removed) {
                self.renderedPresentation = nil
            } completion: { [weak self] in
                self?.restoreFocusAfterRemoval(id: id)
            }
        }
    }

    private func restoreFocusAfterRemoval(id: UUID) {
        // With no animation, SwiftUI may complete synchronously. Leave that
        // transaction before changing the caller's focus binding.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == nil,
                  let pending = self.pendingDismissal, pending.id == id else { return }
            self.pendingDismissal = nil
            pending.onDismiss()
        }
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

    var body: some View {
        ZStack {
            content()
                .disabled(host.renderedPresentation != nil)
                .accessibilityHidden(host.renderedPresentation != nil)

            if let presentation = host.renderedPresentation {
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
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.modal, value: host.renderedPresentation?.id)
    }
}

/// Header row shared by Hub dialogs: title, optional supporting metadata, and close glyph.
struct PickyHubModalHeader: View {
    var meta: String?
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Text(title)
                    .pickyFont(size: PickyHubTheme.Typography.modalTitle, weight: .semibold)
                    .tracking(-0.6)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
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
                .pickyFont(size: 12, weight: .semibold)
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
                .pickyFont(size: 18, weight: .semibold)
                .tracking(-0.5)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
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
