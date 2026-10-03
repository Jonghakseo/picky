//
//  PickyConversationPresenceRow.swift
//  Picky
//
//  Messenger-style "working" line under the last bubble of a running turn.
//  Replaces the inline tool row and the live thinking block for Pickles.
//  Design: design/proposals/messenger-ux-2026-10.md §2-1.
//

import SwiftUI

struct PickyConversationPresencePresentation: Equatable {
    enum Phase: Equatable {
        case thinking
        /// The model is streaming its reply text, reported by the daemon as
        /// `isWritingReply`. The app cannot infer this: assistant deltas are
        /// buffered and only journaled when the segment ends.
        case writing
        case working
        case waitingForInput
    }

    /// Friendly wordings for `.writing`. One is chosen from the turn start so a
    /// single turn never rotates its label while the line is on screen, and
    /// consecutive turns still read differently.
    static let writingTitleKeys = [
        "hud.presence.writing.choosingWords",
        "hud.presence.writing.writingBack",
        "hud.presence.writing.polishing",
        "hud.presence.writing.puttingIntoWords",
    ]

    let phase: Phase
    /// Human-written description of the current step. Never a raw command,
    /// path, or JSON argument.
    let detail: String?
    let startedAt: Date?

    var title: String {
        switch phase {
        case .thinking: L10n.t("hud.presence.thinking")
        case .writing: L10n.t(Self.writingTitleKey(forTurnStartedAt: startedAt))
        case .working: L10n.t("hud.liveStep.working")
        case .waitingForInput: L10n.t("hud.conversation.status.waiting")
        }
    }

    static func writingTitleKey(forTurnStartedAt startedAt: Date?) -> String {
        guard let startedAt, startedAt.timeIntervalSince1970.isFinite else { return writingTitleKeys[0] }
        let seconds = Int(startedAt.timeIntervalSince1970.rounded(.down))
        return writingTitleKeys[((seconds % writingTitleKeys.count) + writingTitleKeys.count) % writingTitleKeys.count]
    }

    var isAnimated: Bool { phase != .waitingForInput }

    /// A running tool makes the live value "working" and streaming reply text
    /// makes it "writing"; otherwise it is "thinking".
    /// `PickyConversationPresenceStabilizer` holds the last step on screen
    /// through short gaps, so "thinking" shows only for long pauses. Once the agent has finished responding, the line
    /// disappears even if the session stays running for background work
    /// (`bash_async`, subagents): the Pickle can take a new message, and the
    /// running-task footer already shows that work.
    static func make(
        isRunning: Bool,
        isWaitingForInput: Bool,
        activeTool: PickyToolActivity?,
        activeTodoForm: String?,
        isWritingReply: Bool = false,
        startedAt: Date?,
        isAgentResponding: Bool = true
    ) -> Self? {
        if isWaitingForInput {
            return Self(phase: .waitingForInput, detail: nil, startedAt: nil)
        }
        guard isRunning, isAgentResponding else { return nil }
        let todo = activeTodoForm.flatMap(nonEmptyLine)
        if let activeTool, activeTool.isActive {
            return Self(phase: .working, detail: todo ?? detail(for: activeTool), startedAt: startedAt)
        }
        if isWritingReply {
            return Self(phase: .writing, detail: nil, startedAt: startedAt)
        }
        return Self(phase: .thinking, detail: nil, startedAt: startedAt)
    }

    /// Detail priority after the active todo: bash/bash_async title, skill name,
    /// delegated subagent. Everything else shows the bare phase title.
    static func detail(for tool: PickyToolActivity) -> String? {
        if let skill = PickyToolActivityPresentation.skillName(forToolNamed: tool.name, argsPreview: tool.argsPreview) {
            return L10n.t("hud.presence.skill", skill)
        }
        switch tool.name.lowercased() {
        case "bash", "bash_async":
            return PickyToolHistoryRenderer.recoverStringValue(from: tool.argsPreview, key: "title")
                .flatMap(nonEmptyLine)
        case "subagent":
            let agents = tool.subagentSummary?.agents.compactMap(nonEmptyLine) ?? []
            guard !agents.isEmpty else { return nil }
            return L10n.t("hud.presence.subagent", agents.joined(separator: ", "))
        default:
            return nil
        }
    }

    private static func nonEmptyLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line?.isEmpty == false ? line : nil
    }
}

/// Keeps the last step on screen between tool calls. Most tools finish in
/// well under a second while the model spends most of a turn choosing the next
/// one, so a strict live value read "thinking" nearly all the time. Entering
/// "working" or "writing", changing a detail, waiting for input, and any other
/// change apply at once. Falling back to "thinking" waits until the step has
/// been gone for `workingGrace` (and shown for `minimumWorkingDuration`): the
/// next tool or reply inside that window only swaps the line, and only a pause
/// longer than the grace reads as "thinking" again.
struct PickyConversationPresenceStabilizer: Equatable {
    static let workingGrace: TimeInterval = 5
    static let minimumWorkingDuration: TimeInterval = 0.6

    private(set) var displayed: PickyConversationPresencePresentation?
    private var stepSince: Date?
    /// When the live value first stopped reporting a step (working or writing).
    private var leftStepAt: Date?

    /// Applies `target` at `now` and returns how long to wait before calling
    /// again, or nil when the displayed value already matches the target.
    mutating func update(target: PickyConversationPresencePresentation, now: Date) -> TimeInterval? {
        if Self.isStep(target.phase) {
            if !Self.isStep(displayed?.phase) { stepSince = now }
            leftStepAt = nil
            displayed = target
            return nil
        }
        guard Self.isStep(displayed?.phase), target.phase == .thinking, let stepSince else {
            reset(to: target)
            return nil
        }
        let leftAt = leftStepAt ?? now
        leftStepAt = leftAt
        let releaseAt = max(
            leftAt.addingTimeInterval(Self.workingGrace),
            stepSince.addingTimeInterval(Self.minimumWorkingDuration)
        )
        let remaining = releaseAt.timeIntervalSince(now)
        guard remaining > 0 else {
            reset(to: target)
            return nil
        }
        return remaining
    }

    /// Phases that report actual progress, so they hold the line through a gap.
    private static func isStep(_ phase: PickyConversationPresencePresentation.Phase?) -> Bool {
        phase == .working || phase == .writing
    }

    private mutating func reset(to target: PickyConversationPresencePresentation) {
        displayed = target
        stepSince = nil
        leftStepAt = nil
    }
}

struct PickyConversationPresenceRow: View {
    let presentation: PickyConversationPresencePresentation
    var onTap: (() -> Void)? = nil
    @State private var stabilizer = PickyConversationPresenceStabilizer()
    @State private var isHovered = false

    /// The stabilized value; the first frame shows the live value directly.
    private var shown: PickyConversationPresencePresentation {
        stabilizer.displayed ?? presentation
    }

    var body: some View {
        let _ = PickyPerf.event("conversation_presence_row_body")
        let presentation = shown
        Button { onTap?() } label: {
            HStack(spacing: DS.Spacing.space2) {
                PickyPresenceTypingIndicator(isAnimated: presentation.isAnimated)
                HStack(spacing: DS.Spacing.space1) {
                    Text(presentation.title)
                        .font(PickyHUDTypography.labelMedium)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize()
                    if let detail = presentation.detail {
                        Text("·")
                            .font(PickyHUDTypography.labelMedium)
                            .foregroundStyle(DS.Colors.textTertiary)
                            .accessibilityHidden(true)
                        Text(detail)
                            .font(PickyHUDTypography.labelMedium)
                            .foregroundStyle(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                // Elapsed time sits right after the status, like a bubble's send
                // time, and only shows on hover. It keeps its slot while hidden so
                // the status text never shifts.
                if let startedAt = presentation.startedAt {
                    Text(startedAt, style: .timer)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize()
                        .opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, DS.Spacing.space1)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .help(L10n.t("hud.toolHistory.open"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([presentation.title, presentation.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(onTap == nil ? "" : L10n.t("hud.toolHistory.open"))
        .task(id: self.presentation) {
            var delay = stabilizer.update(target: self.presentation, now: Date())
            while let wait = delay {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                delay = stabilizer.update(target: self.presentation, now: Date())
            }
        }
    }
}

/// Three dots in a small agent-side bubble. Dots fade in sequence while the
/// Pickle is active; Reduce Motion and the waiting phase keep them static.
private struct PickyPresenceTypingIndicator: View {
    let isAnimated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private static let dotSize: CGFloat = 5
    private static let cycle: Double = 0.9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DS.Colors.textTertiary)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .opacity(dotOpacity)
                    .animation(animation(delay: Double(index) * Self.cycle / 3), value: isPulsing)
            }
        }
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, DS.Spacing.space2)
        .background(DS.Colors.surface2, in: PickyConversationBubbleLayout.bubbleShape(side: .agent))
        .accessibilityHidden(true)
        .onAppear { isPulsing = shouldAnimate }
        .onChange(of: shouldAnimate) { _, value in isPulsing = value }
    }

    private var shouldAnimate: Bool { isAnimated && !reduceMotion }

    private var dotOpacity: Double {
        guard shouldAnimate else { return isAnimated ? 0.8 : 0.45 }
        return isPulsing ? 0.35 : 1
    }

    private func animation(delay: Double) -> Animation? {
        guard shouldAnimate else { return nil }
        return .easeInOut(duration: Self.cycle / 2).repeatForever(autoreverses: true).delay(delay)
    }
}
