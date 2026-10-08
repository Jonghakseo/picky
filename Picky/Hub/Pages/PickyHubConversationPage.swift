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
            conversation: dependencies.companionManager.mainConversation,
            tasks: dependencies.companionManager.mainTasks,
            pickleOpener: dependencies.pickleOpener
        )
    }
}

private struct PickyHubConversationTimeline: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversation: PickyMainAgentConversationStore
    /// Observed by the transcript alone, so a Task update never re-renders the header or composer.
    let tasks: PickyMainTaskStore
    let pickleOpener: PickyPickleOpener
    @State private var draft = ""
    @State private var didCopyResumeCommand = false
    @State private var composerFocused = false
    @State private var editorHeight: CGFloat = 22
    @Environment(\.pickyAppFontScale) private var fontScale
    @Environment(\.pickyHubContentWidth) private var contentWidth

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
                .padding(.top, PickyHubTheme.Layout.contentTopPadding)

            Divider().overlay(PickyHubTheme.Colors.borderSoft)

            PickyHubConversationTranscript(conversation: conversation, tasks: tasks, pickleOpener: pickleOpener)
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
                .pickyFont(size: PickyHubTheme.Typography.pageTitle, weight: .semibold)
                .tracking(-0.8)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("hub.page.conversation.subtitle")
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
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
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
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

/// The scrolling timeline: messages, with a block for each Task and Pickle
/// question in the turn it started in. It observes the transcript and the Tasks
/// itself, so typing in the composer does not re-render it.
private struct PickyHubConversationTranscript: View {
    @ObservedObject var conversation: PickyMainAgentConversationStore
    @ObservedObject var tasks: PickyMainTaskStore
    let pickleOpener: PickyPickleOpener
    @State private var isNearBottom = true
    @State private var hasUnreadMessages = false
    /// Whether each laid-out question waiting on the user is in view. Only the
    /// answer is kept, not the frame, so scrolling re-renders nothing until it flips.
    @State private var waitingQuestionVisibility: [String: Bool] = [:]
    @State private var viewportHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomAnchorID = "hub.conversation.bottom"

    var body: some View {
        let items = PickyMainTaskPresentation.timelineItems(messages: conversation.messages, snapshot: tasks.snapshot)
        let waitingQuestion = PickyHubConversationPolicy.waitingQuestion(in: items)
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                GeometryReader { viewport in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            if items.isEmpty {
                                PickyHubEmptyState(
                                    systemImage: "bubble.left.and.bubble.right",
                                    title: "hub.conversation.empty.title",
                                    message: "hub.conversation.empty.message"
                                )
                                .padding(.vertical, PickyHubTheme.Spacing.group)
                            } else {
                                LazyVStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                                    ForEach(items) { item in
                                        entry(item, viewportHeight: viewport.size.height)
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
                    // Open on the newest message in the first frame; the deferred
                    // onAppear scroll alone showed the oldest one first.
                    .pickyInitialBottomScrollAnchor()
                    .coordinateSpace(name: bottomAnchorID)
                    .onPreferenceChange(PickyHubConversationBottomPreference.self) { bottom in
                        isNearBottom = PickyHubConversationPolicy.isNearBottom(bottom: bottom, viewportHeight: viewport.size.height)
                        if isNearBottom { hasUnreadMessages = false }
                    }
                    .onPreferenceChange(PickyHubWaitingQuestionVisibilityPreference.self) { visibility in
                        waitingQuestionVisibility = visibility
                    }
                    .onAppear {
                        viewportHeight = viewport.size.height
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: viewport.size.height) { _, height in viewportHeight = height }
                    // A new entry at the end, message or block. A block whose state changes keeps its
                    // place, so it neither scrolls the timeline nor counts as unread.
                    .onChange(of: items.last?.id) { _, _ in
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

                if let waitingQuestion,
                   PickyHubConversationPolicy.showsWaitingQuestionBar(
                       isQuestionInView: waitingQuestionVisibility[waitingQuestion.id],
                       viewportHeight: viewportHeight
                   ) {
                    PickyHubWaitingQuestionBar(question: waitingQuestion.question) {
                        scroll(proxy, to: waitingQuestion.id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entry(_ item: PickyMainConversationTimelineItem, viewportHeight: CGFloat) -> some View {
        switch item {
        case .message(let message):
            PickyHubConversationMessage(message: message)
        case .task(let row):
            PickyHubMainTaskBlock(row: row, store: tasks)
        case .decision(let row) where row.isRecord:
            PickyHubMainDelegationRecord(row: row, opener: pickleOpener)
        case .decision(let row):
            PickyHubMainDelegationBlock(row: row, store: tasks)
                .background {
                    if row.showsChoices {
                        GeometryReader { block in
                            Color.clear.preference(
                                key: PickyHubWaitingQuestionVisibilityPreference.self,
                                value: [item.id: PickyHubConversationPolicy.isWaitingQuestionInView(
                                    frame: block.frame(in: .named(bottomAnchorID)),
                                    viewportHeight: viewportHeight
                                )]
                            )
                        }
                    }
                }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        scroll(proxy, to: bottomAnchorID, anchor: .bottom, animated: animated)
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: anchor) }
            } else {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }
}

/// Whether each laid-out question waiting on the user is in view. A question
/// the lazy transcript has not laid out reports nothing.
private struct PickyHubWaitingQuestionVisibilityPreference: PreferenceKey {
    static var defaultValue: [String: Bool] = [:]
    static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// Shared by messages and blocks so the timeline reads as one column.
enum PickyHubConversationEntryLayout {
    static let maxWidth: CGFloat = 560
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
            .frame(maxWidth: PickyHubConversationEntryLayout.maxWidth, alignment: message.role == .user ? .trailing : .leading)
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
    /// The question the waiting-question bar points at: the newest one still
    /// waiting on the user, with its id in the timeline and the text to show.
    struct WaitingQuestion: Equatable {
        let id: String
        let question: String
    }

    /// The last bottom stretch of the transcript does not count as "in view": a
    /// question peeking over the edge shows no buttons yet (same margin as the phone).
    static let waitingQuestionBottomMargin: CGFloat = 64

    static func shouldSubmit(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.shift, .option, .control]).isEmpty
    }

    static func isNearBottom(bottom: CGFloat, viewportHeight: CGFloat) -> Bool {
        bottom >= 0 && bottom <= viewportHeight + 32
    }

    static func waitingQuestion(in items: [PickyMainConversationTimelineItem]) -> WaitingQuestion? {
        for item in items.reversed() {
            guard case .decision(let row) = item, row.showsChoices else { continue }
            let question = row.decision.question.flatMap { $0.isEmpty ? nil : $0 } ?? row.decision.title
            return WaitingQuestion(id: item.id, question: question)
        }
        return nil
    }

    /// Whether a laid-out question can be answered where it is: on screen and
    /// above the bottom margin. `frame` is in the scroll view's visible space.
    static func isWaitingQuestionInView(frame: CGRect, viewportHeight: CGFloat) -> Bool {
        frame.maxY > 0 && frame.minY < viewportHeight - waitingQuestionBottomMargin
    }

    /// Whether the bar above the composer should point at the waiting question.
    /// `isQuestionInView` is nil when the lazy transcript has not laid the
    /// question out, which only happens while it is far out of view. Before the
    /// viewport has a size nothing is known yet, so the bar stays hidden.
    static func showsWaitingQuestionBar(isQuestionInView: Bool?, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0 else { return false }
        return isQuestionInView != true
    }
}
