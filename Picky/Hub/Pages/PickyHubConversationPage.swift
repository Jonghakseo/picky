//
//  PickyHubConversationPage.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubConversationPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubConversationTimeline(
            companionManager: dependencies.companionManager,
            conversation: dependencies.companionManager.mainConversation
        )
    }
}

private struct PickyHubConversationTimeline: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversation: PickyMainAgentConversationStore
    @State private var draft = ""
    @State private var didCopyResumeCommand = false
    @State private var composerFocused = false
    @State private var editorHeight: CGFloat = 22
    @State private var isNearBottom = true
    @State private var hasUnreadMessages = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.pickyHubContentWidth) private var contentWidth

    private let bottomAnchorID = "hub.conversation.bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
                .padding(.top, PickyHubTheme.Layout.contentTopPadding)

            Divider().overlay(PickyHubTheme.Colors.borderSoft)

            GeometryReader { viewport in
              ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        if conversation.messages.isEmpty {
                            PickyHubEmptyState(
                                systemImage: "bubble.left.and.bubble.right",
                                title: "hub.conversation.empty.title",
                                message: "hub.conversation.empty.message"
                            )
                            .padding(.vertical, PickyHubTheme.Spacing.group)
                        } else {
                            LazyVStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                                ForEach(conversation.messages) { message in
                                    PickyHubConversationMessage(message: message)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, PickyHubTheme.Spacing.group)
                        }

                        Color.clear.frame(height: 1).id(bottomAnchorID)
                            .background {
                                GeometryReader { bottom in
                                    Color.clear.preference(
                                        key: PickyHubConversationBottomPreference.self,
                                        value: bottom.frame(in: .named(bottomAnchorID)).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: bottomAnchorID)
                .onPreferenceChange(PickyHubConversationBottomPreference.self) { bottom in
                    isNearBottom = PickyHubConversationPolicy.isNearBottom(bottom: bottom, viewportHeight: viewport.size.height)
                    if isNearBottom { hasUnreadMessages = false }
                }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: conversation.messages.last) { _, _ in
                    if isNearBottom { scrollToBottom(proxy, animated: true) }
                    else { hasUnreadMessages = true }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasUnreadMessages {
                        PickyHubButton(title: "hub.conversation.newMessages", role: .secondary, systemImage: "arrow.down") {
                            hasUnreadMessages = false
                            scrollToBottom(proxy, animated: true)
                        }
                        .padding(PickyHubTheme.Control.horizontalInset)
                    }
                }
              }
            }

            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PickyHubTheme.Colors.canvas)
    }

    private var header: some View {
        Group {
            if contentWidth < PickyHubConversationLayout.inlineHeaderMinimumWidth * fontScale {
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                    headerText
                    headerActions
                }
            } else {
                HStack(alignment: .top, spacing: PickyHubTheme.Spacing.field) {
                    headerText
                    Spacer(minLength: PickyHubTheme.Spacing.field)
                    headerActions
                }
            }
        }
        .padding(.bottom, PickyHubTheme.Spacing.field)
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text("hub.nav.conversation")
                .pickyFont(size: PickyHubTheme.Typography.pageTitle, weight: .heavy)
                .tracking(-0.8)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("hub.page.conversation.subtitle")
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if contentWidth < PickyHubConversationLayout.inlineActionsMinimumWidth * fontScale {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                sessionActionButtons
            }
        } else {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                sessionActionButtons
            }
        }
    }

    @ViewBuilder
    private var sessionActionButtons: some View {
        if conversation.sessionInfo.canOpenInPi {
            PickyHubPillButton(title: "hub.conversation.openInPi", systemImage: "terminal", action: openInPi)
            PickyHubPillButton(
                title: didCopyResumeCommand ? "hub.conversation.copied" : "hub.conversation.copyResume",
                systemImage: didCopyResumeCommand ? "checkmark" : "doc.on.doc",
                action: copyResumeCommand
            )
        }
        PickyHubPillButton(
            title: "hub.conversation.newSession",
            systemImage: "arrow.counterclockwise",
            isBusy: companionManager.isResettingMainAgentSession,
            action: resetSession
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            if let error = companionManager.directMessageError {
                PickyHubInlineStatus(tone: .error, message: error)
            }
            HStack(alignment: .bottom, spacing: PickyHubTheme.Spacing.related) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("hub.conversation.composer.placeholder")
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                    PickyIMETextView(
                        text: $draft,
                        isFocused: $composerFocused,
                        font: .systemFont(ofSize: PickyHubTheme.Typography.bodySmall * fontScale, weight: .medium),
                        textColor: .labelColor,
                        onMeasuredContentHeight: { editorHeight = min(110 * fontScale, max(22 * fontScale, $0)) },
                        onReturn: { modifiers in
                            guard PickyHubConversationPolicy.shouldSubmit(modifiers: modifiers) else { return false }
                            submit()
                            return true
                        }
                    )
                    .frame(height: editorHeight)
                    .accessibilityLabel(Text("hub.conversation.composer.placeholder"))
                    .accessibilityHint(Text("hub.conversation.composer.hint"))
                }
                .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
                .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
                .background(
                    RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                        .stroke(PickyHubTheme.Colors.border, lineWidth: 1)
                )
                .pickyHubFocusRing(isFocused: composerFocused, cornerRadius: PickyHubTheme.Radius.control)

                PickyHubButton(
                    title: "hub.conversation.send",
                    role: .primary,
                    systemImage: "paperplane.fill",
                    isBusy: companionManager.isSendingDirectMessage,
                    isEnabled: canSubmit,
                    action: submit
                )
            }
        }
        .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity)
        .background(PickyHubTheme.Colors.canvas)
        .overlay(alignment: .top) { Divider().overlay(PickyHubTheme.Colors.borderSoft) }
    }

    private var canSubmit: Bool {
        !companionManager.isSendingDirectMessage && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func submit() {
        let message = draft
        guard canSubmit else { return }
        Task { @MainActor in
            if await companionManager.sendDirectMessage(message) {
                // A reply may arrive after the user has started the next draft.
                if draft == message { draft = "" }
                composerFocused = true
            }
        }
    }

    private func resetSession() {
        Task { @MainActor in _ = await companionManager.resetMainAgentSession() }
    }

    private func openInPi() {
        let info = conversation.sessionInfo
        guard let path = info.sessionFilePath, !path.isEmpty else { return }
        do {
            _ = try PickyTerminalOverlayPresenter.shared.openTerminal(
                sessionID: "picky-main", title: "Picky", sessionFilePath: path, cwd: info.cwd, onClose: { _ in }
            )
        } catch {
            NSSound.beep()
        }
    }

    private func copyResumeCommand() {
        let info = conversation.sessionInfo
        guard let path = info.sessionFilePath, !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PickyPiTerminalCommand.makeCliResumeCommand(sessionFilePath: path, cwd: info.cwd), forType: .string)
        didCopyResumeCommand = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyResumeCommand = false
        }
    }
}

private struct PickyHubConversationMessage: View {
    let message: PickyMainAgentMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(metadata)
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
            Group {
                if message.role == .assistant {
                    PickyMainAgentMarkdownText(markdown: message.text)
                        .textSelection(.enabled)
                } else {
                    Text(message.text)
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textOnAction)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
            .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
            .background(bubbleBackground)
            .frame(maxWidth: 560, alignment: message.role == .user ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        let formatter = DateFormatter()
        formatter.locale = LocaleManager.shared.effectiveLocale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let sender = message.role == .user ? L10n.t("hub.conversation.you") : "Picky"
        return "\(sender) · \(formatter.string(from: message.createdAt))"
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous)
                .fill(PickyHubTheme.Colors.action)
        } else {
            RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous)
                .fill(PickyHubTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous)
                        .stroke(PickyHubTheme.Colors.border, lineWidth: 1)
                )
        }
    }
}

private enum PickyHubConversationLayout {
    /// The retained timeline owns its scroll view, so it cannot use page-level
    /// grid reflow. Stack header actions before their labels begin truncating.
    static let inlineHeaderMinimumWidth: CGFloat = 600
    static let inlineActionsMinimumWidth: CGFloat = 440
}

private struct PickyHubConversationBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum PickyHubConversationPolicy {
    static func shouldSubmit(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.shift, .option, .control]).isEmpty
    }

    static func isNearBottom(bottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        bottom >= 0 && bottom <= viewportHeight + 32
    }
}
