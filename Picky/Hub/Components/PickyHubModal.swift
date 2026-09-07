//
//  PickyHubModal.swift
//  Picky
//
//  Window-level modal presentation for the hub (video player, plugin detail,
//  confirmations). One host per window: pages call `present`, the root view
//  draws the backdrop + dialog above everything, and the page beneath is
//  disabled so keyboard focus cannot escape the dialog. `Esc`, backdrop click,
//  and the dialog's own buttons all funnel through `dismiss()` so the
//  `onDismiss` hook (used to restore focus to the trigger) runs exactly once.
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
        let onDismiss: () -> Void
    }

    @Published private(set) var presentation: Presentation?
    /// The hub window; key events from other Picky windows are left alone.
    weak var window: NSWindow?
    private var escapeMonitor: Any?

    var isPresenting: Bool { presentation != nil }

    func present<Content: View>(
        width: CGFloat = 540,
        accessibilityLabel: String,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        if presentation != nil { dismiss() }
        presentation = Presentation(
            width: width,
            accessibilityLabel: accessibilityLabel,
            content: AnyView(content()),
            onDismiss: onDismiss
        )
        installEscapeMonitor()
    }

    func dismiss() {
        guard let current = presentation else { return }
        presentation = nil
        removeEscapeMonitor()
        current.onDismiss()
    }

    /// `onExitCommand` only fires while a SwiftUI view inside the dialog owns
    /// focus. The local monitor covers the moment right after presentation
    /// (before the dialog's first responder is set) and any focus-less state.
    private func installEscapeMonitor() {
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
                .disabled(host.isPresenting)
                .accessibilityHidden(host.isPresenting)

            if let presentation = host.presentation {
                PickyHubTheme.Colors.modalBackdrop
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { host.dismiss() }
                    .accessibilityHidden(true)
                    .transition(.opacity)

                presentation.content
                    .frame(width: presentation.width)
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
                    .padding(24)
                    .onExitCommand { host.dismiss() }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .id(presentation.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.modal, value: host.presentation?.id)
    }
}

/// Header row shared by hub dialogs: eyebrow meta, title, close glyph.
struct PickyHubModalHeader: View {
    var meta: String?
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
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
                .frame(width: 30, height: 30)
                .background(Circle().fill(isHovering ? PickyHubTheme.Colors.navHighlight : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: 15)
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
                PickyHubButton(title: "common.cancel", role: .secondary, action: onCancel)
                    .focused($cancelFocused)
                PickyHubButton(title: confirmTitle, role: confirmRole, isBusy: isBusy, action: onConfirm)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .onAppear { cancelFocused = true }
    }
}
