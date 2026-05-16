//
//  OnboardingScenario.swift
//  Picky
//
//  Scripted Pickle scenario that drives the takeover overlay's hands-on
//  segment without making any real LLM/Pi calls. A scenario is a series of
//  delayed `PickyEvent`s that the `OnboardingAgentClient` replays through its
//  events stream so the HUD viewModel sees a believable session lifecycle:
//  spawn -> running with tool activity -> completed with a final answer.
//
//  Scenarios are pure data so the playback layer, the demo content, and the
//  HUD remain decoupled. Tests can construct synthetic scenarios with tighter
//  timings; production code uses `OnboardingScenario.piReleaseSummary()`.
//

import Foundation

struct OnboardingScenario: Equatable {
    /// One step of the scripted timeline.
    struct Beat: Equatable {
        /// Wait this long after the previous beat (or after submit, for the
        /// first beat) before emitting `event`. Expressed in milliseconds so
        /// scenarios stay readable without `nanoseconds` literals everywhere.
        let delayMs: Int
        let event: PickyEvent
    }

    /// Stable session id reused for every beat so a single Pickle card grows
    /// from queued -> running -> completed instead of spawning siblings.
    let sessionId: String
    /// Title shown in the dock card. The takeover quick-input animation can
    /// also surface this so the user sees their typed text reflected verbatim.
    let sessionTitle: String
    let cwd: String?
    let beats: [Beat]

    /// Built-in scenario that summarizes the Pi 0.73.1 release notes. Used by
    /// the default onboarding flow because the same page is what the takeover
    /// opens in the user's browser, so the canned summary can be cross-checked
    /// against reality with a glance.
    static func piReleaseSummary(
        sessionId: String = "onboarding-pickle-\(UUID().uuidString.prefix(8))",
        cwd: String? = nil,
        clock: () -> Date = { Date() }
    ) -> OnboardingScenario {
        let now = clock()
        let title = L10n.t("onboarding.scenario.title")

        // Progressive conversation messages — each beat extends the array so
        // a user opening the dock card mid-flight or after completion sees the
        // turn-by-turn history they would in a real Pickle.
        let userMessage = makeMessage(
            id: "\(sessionId)-msg-user",
            kind: .userText,
            originatedBy: .user,
            createdAt: now,
            text: L10n.t("onboarding.scenario.userMessage")
        )
        let thinkingMessage = makeMessage(
            id: "\(sessionId)-msg-thinking",
            kind: .agentThinking,
            originatedBy: .mainAgent,
            createdAt: now,
            text: L10n.t("onboarding.scenario.thinking")
        )

        let queued = makeSession(
            id: sessionId,
            title: title,
            status: .queued,
            cwd: cwd,
            createdAt: now,
            updatedAt: now,
            summary: L10n.t("onboarding.scenario.summary.queued"),
            logs: [],
            tools: [],
            activity: .zero,
            finalAnswer: nil,
            messages: [userMessage]
        )

        let runningHead = makeSession(
            id: sessionId,
            title: title,
            status: .running,
            cwd: cwd,
            createdAt: now,
            updatedAt: now,
            summary: L10n.t("onboarding.scenario.summary.reading"),
            logs: ["Fetching pi.dev/news/releases/0.73.1"],
            tools: [],
            activity: PickyActivitySummary(other: 1),
            finalAnswer: nil,
            messages: [userMessage, thinkingMessage]
        )

        let readingTool = PickyToolActivity(
            toolCallId: "\(sessionId)-tool-1",
            name: "Read",
            status: "completed",
            preview: "Pi 0.73.1 release notes",
            argsPreview: "url=pi.dev/news/releases/0.73.1",
            resultPreview: "Parsed 23 changelog entries",
            startedAt: now,
            endedAt: now
        )

        let toolMessage = makeMessage(
            id: "\(sessionId)-msg-tool",
            kind: .agentActivity,
            originatedBy: .mainAgent,
            createdAt: now,
            text: nil,
            activitySnapshot: PickyActivitySummary(other: 1, read: 1)
        )

        let extractingHead = makeSession(
            id: sessionId,
            title: title,
            status: .running,
            cwd: cwd,
            createdAt: now,
            updatedAt: now,
            summary: L10n.t("onboarding.scenario.summary.extracting"),
            logs: runningHead.logs + ["Extracting changelog sections"],
            tools: [readingTool],
            activity: PickyActivitySummary(other: 1, read: 1),
            finalAnswer: nil,
            messages: [userMessage, thinkingMessage, toolMessage]
        )

        let finalAnswer = L10n.t("onboarding.scenario.finalAnswer")

        let answerMessage = makeMessage(
            id: "\(sessionId)-msg-answer",
            kind: .agentText,
            originatedBy: .mainAgent,
            createdAt: now,
            text: finalAnswer
        )

        let completed = makeSession(
            id: sessionId,
            title: title,
            status: .completed,
            cwd: cwd,
            createdAt: now,
            updatedAt: now,
            summary: L10n.t("onboarding.scenario.summary.ready"),
            logs: extractingHead.logs + ["Drafting summary", "Done"],
            tools: [readingTool],
            activity: PickyActivitySummary(other: 1, read: 1),
            finalAnswer: finalAnswer,
            messages: [userMessage, thinkingMessage, toolMessage, answerMessage]
        )

        return OnboardingScenario(
            sessionId: sessionId,
            sessionTitle: title,
            cwd: cwd,
            // Stretched (~22s end-to-end) so the user has time to read the
            // running narration and watch the dock card actually do work
            // before the completion bubble pops. The longest pause is the
            // final 'Drafting summary' -> completed step so the user can sit
            // on the running state instead of seeing 'done' the instant they
            // finish reading the delegation bubble.
            beats: [
                Beat(delayMs: 0, event: .sessionUpdated(queued)),
                Beat(delayMs: 1_400, event: .sessionUpdated(runningHead)),
                Beat(delayMs: 1_800, event: .sessionLogAppended(sessionId: sessionId, line: "Fetching pi.dev/news/releases/0.73.1")),
                Beat(delayMs: 2_200, event: .toolActivityUpdated(sessionId: sessionId, tool: readingTool)),
                Beat(delayMs: 2_500, event: .sessionUpdated(extractingHead)),
                Beat(delayMs: 2_400, event: .sessionLogAppended(sessionId: sessionId, line: "Extracting changelog sections")),
                Beat(delayMs: 3_200, event: .sessionLogAppended(sessionId: sessionId, line: "Drafting summary")),
                Beat(delayMs: 4_000, event: .sessionUpdated(completed))
            ]
        )
    }

    /// Convenience for tests: a synthetic scenario whose every beat fires
    /// immediately so playback assertions don't have to wait on real delays.
    static func instantTwoBeatFixture(sessionId: String = "onboarding-test") -> OnboardingScenario {
        let now = Date()
        let queued = makeSession(
            id: sessionId,
            title: "Fixture",
            status: .queued,
            cwd: nil,
            createdAt: now,
            updatedAt: now,
            summary: nil,
            logs: [],
            tools: [],
            activity: .zero,
            finalAnswer: nil
        )
        let completed = makeSession(
            id: sessionId,
            title: "Fixture",
            status: .completed,
            cwd: nil,
            createdAt: now,
            updatedAt: now,
            summary: "Done",
            logs: ["all done"],
            tools: [],
            activity: .zero,
            finalAnswer: "Done."
        )
        return OnboardingScenario(
            sessionId: sessionId,
            sessionTitle: "Fixture",
            cwd: nil,
            beats: [
                Beat(delayMs: 0, event: .sessionUpdated(queued)),
                Beat(delayMs: 0, event: .sessionUpdated(completed))
            ]
        )
    }

    private static func makeSession(
        id: String,
        title: String,
        status: PickySessionStatus,
        cwd: String?,
        createdAt: Date,
        updatedAt: Date,
        summary: String?,
        logs: [String],
        tools: [PickyToolActivity],
        activity: PickyActivitySummary,
        finalAnswer: String?,
        messages: [PickySessionMessage] = []
    ) -> PickyAgentSession {
        PickyAgentSession(
            id: id,
            title: title,
            status: status,
            cwd: cwd,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastSummary: summary,
            finalAnswer: finalAnswer,
            logs: logs,
            tools: tools,
            artifacts: [],
            changedFiles: [],
            messages: messages,
            activitySummary: activity
        )
    }

    private static func makeMessage(
        id: String,
        kind: PickySessionMessageKind,
        originatedBy: PickyMessageOrigin,
        createdAt: Date,
        text: String?,
        activitySnapshot: PickyActivitySummary? = nil
    ) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: createdAt,
            originatedBy: originatedBy,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: activitySnapshot,
            errorContext: nil,
            errorMessage: nil
        )
    }
}
