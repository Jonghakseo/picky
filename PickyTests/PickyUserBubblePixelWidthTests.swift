//
//  PickyUserBubblePixelWidthTests.swift
//  PickyTests
//
//  Pixel-level regression tests for the user bubble's hug-fit behavior.
//  The conversation card's user bubble must shrink its background to the
//  rendered text width even when the surrounding column proposes a much
//  wider frame. The previous attempts at fixing this (commits 66cb4a0d,
//  23c2f321) only addressed the wrapper's reported size; they did not
//  break the SwiftUI `.fixedSize(horizontal: false, vertical: true)` axis
//  override that forces the wrapper to take the full proposed width.
//
//  These tests host the real `PickyUserBubbleView` inside an
//  `NSHostingView` at a known card width, run an AppKit layout pass, and
//  walk the view tree to read the `SelfSizingMarkdownTextView` instance's
//  actual `frame.width`. A regression where the bubble stretches to the
//  full 85% column reappears as a `frame.width` close to the cap; a
//  healthy hug-fit reports a width near the rendered glyph run.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyUserBubblePixelWidthTests {
    /// Mirrors the cap math the real `PickyUserBubbleView` applies:
    /// bubble interior = card * 0.85 - 20pt horizontal padding.
    private func bubbleInteriorCap(forCardWidth cardWidth: CGFloat) -> CGFloat {
        cardWidth * 0.85 - 20
    }

    /// Mounts a `PickyUserBubbleView` with the same `pickyHUDDetailWidth`
    /// environment override the conversation card sets, then walks the
    /// hosted AppKit tree to find the embedded inline NSTextView wrapper.
    /// Using the real bubble (not just the markdown view) is what makes
    /// the assertion meaningful: the stretching only happens through the
    /// bubble's outer VStack + padding + background + `.frame(maxWidth:)`
    /// envelope, not the markdown view in isolation.
    private func layoutBubble(text: String, cardWidth: CGFloat) throws -> SelfSizingMarkdownTextView {
        // Mount the full `PickyConversationCardView` so any wrapping that
        // surrounds the user bubble in production (turn cards, list scroll
        // view, card padding, environment overrides) is part of the layout
        // pass. Stretch reproduces here that would not reproduce against
        // the bare bubble.
        let userMessage = PickySessionMessage(
            id: "u-1",
            kind: .userText,
            createdAt: Date(timeIntervalSince1970: 1_777_777_777),
            originatedBy: .user,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            assistantRun: nil,
            errorContext: nil,
            errorMessage: nil,
            notifyType: nil,
            attachedImagesCount: nil
        )
        let session = PickySessionListViewModel.SessionCard.fromAgentSession(
            PickyAgentSession(
                id: "session-bubble",
                title: "Bubble test",
                status: .running,
                cwd: "/tmp/picky",
                createdAt: Date(timeIntervalSince1970: 1_777_777_777),
                updatedAt: Date(timeIntervalSince1970: 1_777_777_777),
                lastSummary: "",
                logs: [],
                tools: [],
                artifacts: [],
                changedFiles: [],
                messages: [userMessage],
                queuedSteers: [],
                queuedFollowUps: [],
                steeringMode: .oneAtATime,
                followUpMode: .oneAtATime,
                activitySummary: .zero,
                contextUsage: nil,
                pendingExtensionUiRequest: nil,
                notifyMainOnCompletion: nil
            )
        )
        let viewModel = PickySessionListViewModel(
            client: BubbleStubClient(),
            notificationCenter: PickyNoopNotificationCenter()
        )
        let card = PickyConversationCardView(
            viewModel: viewModel,
            session: session,
            width: cardWidth
        )

        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 800)
        host.layoutSubtreeIfNeeded()

        let wrappers = collectSelfSizingTextViews(host)
        #expect(wrappers.count >= 1, "expected at least one inline NSTextView wrapper in the conversation card")
        return try #require(wrappers.first)
    }

    @Test func shortUserMessageHugsToTextWidthInsteadOfStretchingToFullColumn() throws {
        let cardWidth: CGFloat = 600
        let cap = bubbleInteriorCap(forCardWidth: cardWidth)
        let wrapper = try layoutBubble(text: "수정해줘.", cardWidth: cardWidth)

        // "수정해줘." renders at body size; its glyph run is comfortably
        // under 120pt at the body font. A regression that stretches the
        // bubble to the full 85% column ends up at ~`cap` (≈490pt here),
        // which is well outside this allowance.
        let actual = wrapper.frame.width
        #expect(
            actual < 200,
            "short user message should hug its text width, but the wrapper laid out at \(actual)pt (cap=\(cap)pt)"
        )
    }

    @Test func longUserMessageWrapsAtBubbleInteriorCap() throws {
        let cardWidth: CGFloat = 600
        let cap = bubbleInteriorCap(forCardWidth: cardWidth)
        let longText = String(
            repeating: "이것은 충분히 긴 한 줄짜리 사용자 메시지입니다. ",
            count: 8
        )
        let wrapper = try layoutBubble(text: longText, cardWidth: cardWidth)

        // Long content should fill (and wrap at) the bubble interior cap —
        // never wider, never the full column either (we have padding).
        let actual = wrapper.frame.width
        #expect(actual <= cap + 1, "long message must not exceed the bubble interior cap (cap=\(cap), got \(actual))")
        #expect(actual > cap * 0.7, "long message should consume most of the bubble interior cap (cap=\(cap), got \(actual))")
    }
}

private func collectSelfSizingTextViews(_ root: NSView) -> [SelfSizingMarkdownTextView] {
    var out: [SelfSizingMarkdownTextView] = []
    if let match = root as? SelfSizingMarkdownTextView {
        out.append(match)
    }
    for sub in root.subviews {
        out.append(contentsOf: collectSelfSizingTextViews(sub))
    }
    return out
}

/// Minimal `PickyAgentClient` stand-in used only so `PickySessionListViewModel`
/// can be constructed inside these layout-only tests. The card never
/// dispatches a command in this path.
private final class BubbleStubClient: PickyAgentClient {
    let events: AsyncStream<PickyClientEvent>
    private let continuation: AsyncStream<PickyClientEvent>.Continuation

    init() {
        var sink: AsyncStream<PickyClientEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        continuation = sink
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "bubble", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() { continuation.yield(.disconnected) }
}
