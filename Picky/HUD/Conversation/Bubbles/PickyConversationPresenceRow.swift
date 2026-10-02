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
        case working
        case waitingForInput
    }

    let phase: Phase
    /// Human-written description of the current step. Never a raw command,
    /// path, or JSON argument.
    let detail: String?
    let startedAt: Date?

    var title: String {
        switch phase {
        case .thinking: L10n.t("hud.presence.thinking")
        case .working: L10n.t("hud.liveStep.working")
        case .waitingForInput: L10n.t("hud.conversation.status.waiting")
        }
    }

    var isAnimated: Bool { phase != .waitingForInput }

    /// Only a running tool makes the line "working". Once it finishes the line
    /// drops back to "thinking" so a finished or failed step never reads as
    /// still in progress. Once the agent has finished responding, the line
    /// disappears even if the session stays running for background work
    /// (`bash_async`, subagents): the Pickle can take a new message, and the
    /// running-task footer already shows that work.
    static func make(
        isRunning: Bool,
        isWaitingForInput: Bool,
        activeTool: PickyToolActivity?,
        activeTodoForm: String?,
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

/// Smooths "working" <-> "thinking" flips caused by back-to-back short tool
/// calls. Entering "working", changing its detail, waiting for input, and any
/// non-working change apply at once. Leaving "working" for "thinking" waits
/// until the step has been gone for `workingGrace` and shown for at least
/// `minimumWorkingDuration`, so a tool that starts inside that window just
/// replaces the detail instead of blinking through "thinking".
struct PickyConversationPresenceStabilizer: Equatable {
    static let workingGrace: TimeInterval = 0.4
    static let minimumWorkingDuration: TimeInterval = 0.6

    private(set) var displayed: PickyConversationPresencePresentation?
    private var workingSince: Date?
    /// When the live value first stopped being "working" (the step ended).
    private var leftWorkingAt: Date?

    /// Applies `target` at `now` and returns how long to wait before calling
    /// again, or nil when the displayed value already matches the target.
    mutating func update(target: PickyConversationPresencePresentation, now: Date) -> TimeInterval? {
        if target.phase == .working {
            if displayed?.phase != .working { workingSince = now }
            leftWorkingAt = nil
            displayed = target
            return nil
        }
        guard displayed?.phase == .working, target.phase == .thinking, let workingSince else {
            reset(to: target)
            return nil
        }
        let leftAt = leftWorkingAt ?? now
        leftWorkingAt = leftAt
        let releaseAt = max(
            leftAt.addingTimeInterval(Self.workingGrace),
            workingSince.addingTimeInterval(Self.minimumWorkingDuration)
        )
        let remaining = releaseAt.timeIntervalSince(now)
        guard remaining > 0 else {
            reset(to: target)
            return nil
        }
        return remaining
    }

    private mutating func reset(to target: PickyConversationPresencePresentation) {
        displayed = target
        workingSince = nil
        leftWorkingAt = nil
    }
}

struct PickyConversationPresenceRow: View {
    let presentation: PickyConversationPresencePresentation
    var onTap: (() -> Void)? = nil
    @State private var stabilizer = PickyConversationPresenceStabilizer()

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
                Spacer(minLength: DS.Spacing.space2)
                if let startedAt = presentation.startedAt {
                    Text(startedAt, style: .timer)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, DS.Spacing.space1)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
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
