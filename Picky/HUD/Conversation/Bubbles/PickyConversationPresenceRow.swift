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
        /// The model is streaming a tool call's arguments, reported by the
        /// daemon as `isPreparingToolCall`. A long `write` or `edit` spends most
        /// of its step here, before the tool starts and the line reads "working".
        case preparing
        /// A running `read`, `edit`/`multiedit`, or `write` call. The detail is the
        /// file name, so the user sees which file the step touches.
        case readingFile
        case editingFile
        case writingFile
        case working
        /// A "working" tool just finished. Shown instead of thinking, preparing,
        /// or writing for `PickyConversationPresenceStabilizer.finishedWorkHold`
        /// after it ends, so the line names the step the model is reacting to.
        case workCompleted
        case workFailed
        /// Pi is waiting to re-send a failed model request. The detail carries
        /// the provider's code and message: without them a user cannot tell a
        /// passing rate limit from a request that can never succeed.
        case retrying(attempt: Int, maxAttempts: Int)
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
    /// Tooltip for the detail when it is shortened, such as the full path
    /// behind a file name. Defaults to the detail itself.
    var detailHelp: String? = nil
    /// The last tool when it was a finished "working" step. Set only on the
    /// thinking, preparing, and writing phases; the stabilizer decides whether
    /// it is still recent enough to show.
    var finishedWork: FinishedWork? = nil

    struct FinishedWork: Equatable {
        let toolCallId: String
        let failed: Bool
        let detail: String?
        let endedAt: Date?
    }

    /// The line shown while `finishedWork` is held.
    var finishedWorkPresentation: Self? {
        guard let finishedWork else { return nil }
        return Self(phase: finishedWork.failed ? .workFailed : .workCompleted,
                    detail: finishedWork.detail, startedAt: startedAt)
    }

    var title: String {
        switch phase {
        case .thinking: L10n.t("hud.presence.thinking")
        case .writing: L10n.t(Self.writingTitleKey(forTurnStartedAt: startedAt))
        case .preparing: L10n.t("hud.presence.preparing")
        case .readingFile: L10n.t("hud.presence.readingFile")
        case .editingFile: L10n.t("hud.presence.editingFile")
        case .writingFile: L10n.t("hud.presence.writingFile")
        case .working: L10n.t("hud.liveStep.working")
        case .workCompleted: L10n.t("hud.presence.workCompleted")
        case .workFailed: L10n.t("hud.presence.workFailed")
        case .retrying(let attempt, let maxAttempts): L10n.t("hud.presence.retrying", attempt, maxAttempts)
        case .waitingForInput: L10n.t("hud.conversation.status.waiting")
        }
    }

    static func writingTitleKey(forTurnStartedAt startedAt: Date?) -> String {
        guard let startedAt, startedAt.timeIntervalSince1970.isFinite else { return writingTitleKeys[0] }
        let seconds = Int(startedAt.timeIntervalSince1970.rounded(.down))
        return writingTitleKeys[((seconds % writingTitleKeys.count) + writingTitleKeys.count) % writingTitleKeys.count]
    }

    var isAnimated: Bool { phase != .waitingForInput }

    /// A running file tool makes the live value "reading/editing/writing file",
    /// any other running tool makes it "working", streaming tool-call
    /// arguments make it "preparing", and streaming reply text makes it
    /// "writing"; otherwise it is "thinking". The in-progress todo is deliberately
    /// not shown: it replaced the step's own detail and hid what was running.
    /// `PickyConversationPresenceStabilizer` holds the last step on screen
    /// through short gaps, so "thinking" shows only for long pauses. Once the agent has finished responding, the line
    /// disappears even if the session stays running for background work
    /// (`bash_async`, subagents): the Pickle can take a new message, and the
    /// running-task footer already shows that work.
    static func make(
        isRunning: Bool,
        isWaitingForInput: Bool,
        activeTool: PickyToolActivity?,
        lastTool: PickyToolActivity? = nil,
        isWritingReply: Bool = false,
        isPreparingToolCall: Bool = false,
        autoRetry: PickyAutoRetryStatus? = nil,
        startedAt: Date?,
        isAgentResponding: Bool = true,
        isRuntimeRestarting: Bool = false
    ) -> Self? {
        // The restart banner owns that moment; no model is thinking until the new runtime takes input.
        guard !isRuntimeRestarting else { return nil }
        if isWaitingForInput {
            return Self(phase: .waitingForInput, detail: nil, startedAt: nil)
        }
        guard isRunning else { return nil }
        // The daemon clears a retry once the model makes progress, so it outranks
        // every other phase while it is set.
        if let autoRetry {
            return Self(
                phase: .retrying(attempt: autoRetry.attempt, maxAttempts: autoRetry.maxAttempts),
                detail: retryDetail(autoRetry),
                startedAt: startedAt
            )
        }
        guard isAgentResponding else { return nil }
        if let activeTool, activeTool.isActive {
            if let file = fileStep(for: activeTool) {
                return Self(phase: file.phase, detail: file.name, startedAt: startedAt, detailHelp: file.path)
            }
            return Self(phase: .working, detail: detail(for: activeTool), startedAt: startedAt)
        }
        let finishedWork = lastTool.flatMap(finishedWork(for:))
        if isPreparingToolCall {
            return Self(phase: .preparing, detail: nil, startedAt: startedAt, finishedWork: finishedWork)
        }
        if isWritingReply {
            return Self(phase: .writing, detail: nil, startedAt: startedAt, finishedWork: finishedWork)
        }
        return Self(phase: .thinking, detail: nil, startedAt: startedAt, finishedWork: finishedWork)
    }

    /// A finished tool that read as "working" while it ran. File tools keep
    /// their own titles. `bash_async` and `subagent` return as soon as they
    /// launch background work, and a question tool ends with the user's answer,
    /// so none of those reads as a completed step.
    static func finishedWork(for tool: PickyToolActivity) -> FinishedWork? {
        guard !tool.isActive, fileStep(for: tool) == nil else { return nil }
        let name = tool.name.lowercased()
        guard !["bash_async", "subagent", "ask_user_question"].contains(name) else { return nil }
        let failed = tool.didFail
        guard failed || tool.status == "succeeded" else { return nil }
        return FinishedWork(toolCallId: tool.toolCallId, failed: failed,
                            detail: detail(for: tool), endedAt: tool.endedAt)
    }

    /// "429 · Usage credits are required for fast mode." The message is the
    /// provider's own text, shown as-is because it names the actual cause.
    static func retryDetail(_ retry: PickyAutoRetryStatus) -> String? {
        let message = nonEmptyLine(retry.errorMessage)
        let code = retry.errorCode.flatMap(nonEmptyLine)
        let detail = [code, message].compactMap { $0 }.joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }

    /// File phase for `read`, `edit`/`multiedit`, and `write`. The name is the
    /// last path component, extension included; a `SKILL.md` read stays a skill
    /// step. Without a usable file name the phase still applies, title only.
    static func fileStep(for tool: PickyToolActivity) -> (phase: Phase, name: String?, path: String?)? {
        let phase: Phase
        switch tool.name.lowercased() {
        case "read":
            guard PickyToolActivityPresentation.skillName(forToolNamed: tool.name, argsPreview: tool.argsPreview) == nil
            else { return nil }
            phase = .readingFile
        case "edit", "multiedit": phase = .editingFile
        case "write": phase = .writingFile
        default: return nil
        }
        let path = ["path", "file_path", "filePath", "file"].lazy
            .compactMap { PickyToolHistoryRenderer.recoverStringValue(from: tool.argsPreview, key: $0) }
            .compactMap(nonEmptyLine)
            .first
        guard let path, !path.hasSuffix("/") else { return (phase, nil, nil) }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? (phase, nil, nil) : (phase, name, path)
    }

    /// Detail for other tools: bash/bash_async title, skill name, delegated
    /// subagent. Everything else shows the bare phase title.
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

/// Keeps the line from flickering. Most tools finish in well under a second
/// while the model spends most of a turn choosing the next one, so the live
/// value can change several times a second.
///
/// - Every change (phase, title, or detail) stays on screen for at least
///   `minimumDisplayDuration`; changes arriving sooner are coalesced and the
///   latest one shows when the interval ends.
/// - Falling back from a step ("working", "preparing", or "writing") to
///   "thinking" additionally waits until the step has been gone for
///   `workingGrace`, so only a long pause reads as "thinking" again.
/// - Entering or leaving "waiting for input" applies at once: the user has to
///   act on it, or just did.
struct PickyConversationPresenceStabilizer: Equatable {
    static let workingGrace: TimeInterval = 5
    static let minimumDisplayDuration: TimeInterval = 1.5
    /// How long a finished "working" step reads "done" or "failed" while the
    /// model thinks, prepares, or writes. A new running tool replaces it at once.
    static let finishedWorkHold: TimeInterval = 5

    private(set) var displayed: PickyConversationPresencePresentation?
    private var displayedSince: Date?
    /// When the live value first stopped reporting a step (working, preparing, or writing).
    private var leftStepAt: Date?
    /// The finished tool being held and when it ended (or was first seen ended).
    private var finishedWorkID: String?
    private var finishedWorkEndedAt: Date?

    /// Applies `target` at `now` and returns how long to wait before calling
    /// again, or nil when the displayed value already matches the target.
    mutating func update(target live: PickyConversationPresencePresentation, now: Date) -> TimeInterval? {
        var target = live
        var holdRemaining: TimeInterval?
        if let work = live.finishedWork, let held = live.finishedWorkPresentation {
            if finishedWorkID != work.toolCallId {
                finishedWorkID = work.toolCallId
                finishedWorkEndedAt = work.endedAt.map { min($0, now) } ?? now
            }
            let remaining = (finishedWorkEndedAt ?? now).addingTimeInterval(Self.finishedWorkHold).timeIntervalSince(now)
            if remaining > 0 {
                target = held
                holdRemaining = remaining
            }
        }
        let wait = apply(target, now: now)
        guard let holdRemaining else { return wait }
        return min(wait ?? holdRemaining, holdRemaining)
    }

    private mutating func apply(_ target: PickyConversationPresencePresentation, now: Date) -> TimeInterval? {
        guard let displayed, let displayedSince,
              target.phase != .waitingForInput, displayed.phase != .waitingForInput else {
            show(target, at: now)
            return nil
        }
        if target == displayed {
            leftStepAt = nil
            return nil
        }
        var releaseAt = displayedSince.addingTimeInterval(Self.minimumDisplayDuration)
        if Self.isStep(displayed.phase), target.phase == .thinking {
            let leftAt = leftStepAt ?? now
            leftStepAt = leftAt
            releaseAt = max(releaseAt, leftAt.addingTimeInterval(Self.workingGrace))
        } else {
            leftStepAt = nil
        }
        let remaining = releaseAt.timeIntervalSince(now)
        guard remaining > 0 else {
            show(target, at: now)
            return nil
        }
        return remaining
    }

    /// Phases that report actual progress, so they hold the line through a gap.
    private static func isStep(_ phase: PickyConversationPresencePresentation.Phase?) -> Bool {
        switch phase {
        case .working, .preparing, .writing, .retrying, .readingFile, .editingFile, .writingFile: true
        // A finished step already had its hold; leaving it applies normally.
        case .thinking, .workCompleted, .workFailed, .waitingForInput, nil: false
        }
    }

    private mutating func show(_ target: PickyConversationPresencePresentation, at now: Date) {
        displayed = target
        displayedSince = now
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
                            .help(presentation.detailHelp ?? detail)
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

    private static let dotSize: CGFloat = 5
    private static let cycle: Double = 0.9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DS.Colors.textTertiary)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .pickyRepeatingPulse(
                        isActive: isAnimated,
                        dimmedOpacity: 0.35,
                        halfPeriod: Self.cycle / 2,
                        delay: Double(index) * Self.cycle / 3,
                        staticOpacity: isAnimated ? 0.8 : 0.45
                    )
            }
        }
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, DS.Spacing.space2)
        .background(DS.Colors.surface2, in: PickyConversationBubbleLayout.bubbleShape(side: .agent))
        .accessibilityHidden(true)
    }
}
