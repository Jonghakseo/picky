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
    private func layoutUserBubble(text: String, cardWidth: CGFloat) throws -> PickyUserBubbleSurfaceNSView {
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let surfaces = collectUserBubbleSurfaces(host)
        #expect(surfaces.count >= 1, "expected at least one AppKit user bubble surface in the conversation card")
        return try #require(surfaces.first)
    }

    @Test func shortUserMessageHugsToTextWidthInsteadOfStretchingToFullColumn() throws {
        let cardWidth: CGFloat = 600
        let cap = bubbleInteriorCap(forCardWidth: cardWidth)
        let surface = try layoutUserBubble(text: "수정해줘.", cardWidth: cardWidth)

        // "수정해줘." renders at body size; its glyph run is comfortably
        // under 120pt at the body font. A regression that stretches the
        // visual bubble to the full 85% column ends up near the outer cap
        // (≈510pt here), which is well outside this allowance.
        let actual = surface.lastBubbleRect.width
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
        let surface = try layoutUserBubble(text: longText, cardWidth: cardWidth)

        // Long content should fill (and wrap at) the bubble cap — never wider.
        let actual = surface.lastBubbleRect.width
        let outerCap = cardWidth * 0.85
        #expect(actual <= outerCap + 1, "long message must not exceed the bubble cap (cap=\(outerCap), got \(actual))")
        #expect(actual > cap * 0.7, "long message should consume most of the bubble cap (interior cap=\(cap), got \(actual))")
    }

    private func layoutAgentBubble(text: String, cardWidth: CGFloat) throws -> PickyAgentBubbleSurfaceNSView {
        let agentMessage = PickySessionMessage(
            id: "a-1",
            kind: .agentText,
            createdAt: Date(timeIntervalSince1970: 1_777_777_778),
            originatedBy: nil,
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
                id: "session-agent-bubble",
                title: "Agent bubble test",
                status: .running,
                cwd: "/tmp/picky",
                createdAt: Date(timeIntervalSince1970: 1_777_777_777),
                updatedAt: Date(timeIntervalSince1970: 1_777_777_778),
                lastSummary: "",
                logs: [],
                tools: [],
                artifacts: [],
                changedFiles: [],
                messages: [agentMessage],
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let surfaces = collectAgentBubbleSurfaces(host)
        #expect(surfaces.count >= 1, "expected at least one AppKit agent bubble surface in the conversation card")
        return try #require(surfaces.first)
    }

    @Test func shortAgentMessageHugsToTextWidthInsteadOfStretchingToFullColumn() throws {
        let cardWidth: CGFloat = 600
        let surface = try layoutAgentBubble(text: "Done.", cardWidth: cardWidth)
        let actual = surface.lastBubbleRect.width
        #expect(
            actual < 160,
            "short agent message should hug its text width, but the visual bubble laid out at \(actual)pt"
        )
    }

    @Test func longAgentMessageWrapsAtBubbleInteriorCap() throws {
        let cardWidth: CGFloat = 600
        let longText = String(repeating: "This is a sufficiently long assistant response line. ", count: 10)
        let surface = try layoutAgentBubble(text: longText, cardWidth: cardWidth)
        let outerCap = cardWidth * 0.85
        let actual = surface.lastBubbleRect.width
        #expect(actual <= outerCap + 1, "long agent message must not exceed the bubble cap (cap=\(outerCap), got \(actual))")
        #expect(actual > outerCap * 0.7, "long agent message should consume most of the bubble cap (cap=\(outerCap), got \(actual))")
    }

    @Test func agentCodeBlockUsesDedicatedAppKitCodeBlockInsteadOfInlineFlattening() throws {
        let surface = try layoutAgentBubble(text: "```\nlet value = 42\n```", cardWidth: 600)
        let typeNames = collectSubviewTypeNames(surface)
        #expect(
            typeNames.contains("PickyCodeMarkdownBlockView"),
            "code blocks should render through the AppKit code block view, not flatten into a paragraph-only text view (types=\(typeNames))"
        )
    }

    @Test func agentCodeBlockUsesHorizontalScrollerForLongLines() throws {
        let surface = try layoutAgentBubble(text: "```\n" + String(repeating: "let identifier = veryLongValue ", count: 20) + "\n```", cardWidth: 600)
        let codeBlockScrollViews = collectScrollViews(surface).filter { $0.documentView is NSTextView }

        #expect(codeBlockScrollViews.contains { $0.hasHorizontalScroller })
    }

    @Test func agentTableUsesDedicatedAppKitTableBlockInsteadOfInlineFlattening() throws {
        let markdown = "| Name | Value |\n| --- | --- |\n| Width | Hug |"
        let surface = try layoutAgentBubble(text: markdown, cardWidth: 600)
        let typeNames = collectSubviewTypeNames(surface)
        #expect(
            typeNames.contains("PickyTableMarkdownBlockView"),
            "tables should render through the AppKit table block view, not flatten into a paragraph-only text view (types=\(typeNames))"
        )
    }

    @Test func agentTableRendersCellsSeparatelyInsteadOfDotJoinedPlainText() {
        let markdown = "| # | 일시 | 사용자/출처 | 대상 |\n| --- | --- | --- | --- |\n| 1 | 2026-05 | `npribeiro` | ChatGPT + Codex |"
        let surface = configuredAgentSurface(markdown: markdown, codeBlockMaxLines: PickyAgentResponsePreview.codeBlockMaxLines)
        let strings = collectTextFieldStrings(surface)

        #expect(strings.contains("#"))
        #expect(strings.contains("일시"))
        #expect(strings.contains("사용자/출처"))
        #expect(strings.contains("1"))
        #expect(strings.contains("2026-05"))
        #expect(strings.contains("npribeiro"))
        #expect(!strings.contains { $0.contains(" · ") })
    }

    @Test func agentSurfaceCanDisableCodeBlockTruncationForLatestResponse() {
        let code = "```\n" + (1...6).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        let defaultSurface = configuredAgentSurface(markdown: code, codeBlockMaxLines: PickyAgentResponsePreview.codeBlockMaxLines)
        let fullSurface = configuredAgentSurface(markdown: code, codeBlockMaxLines: 0)

        #expect(collectTextFieldStrings(defaultSurface).contains { $0.contains("more lines") })
        #expect(!collectTextFieldStrings(fullSurface).contains { $0.contains("more lines") })
    }
}

private func collectUserBubbleSurfaces(_ root: NSView) -> [PickyUserBubbleSurfaceNSView] {
    var out: [PickyUserBubbleSurfaceNSView] = []
    if let match = root as? PickyUserBubbleSurfaceNSView {
        out.append(match)
    }
    for sub in root.subviews {
        out.append(contentsOf: collectUserBubbleSurfaces(sub))
    }
    return out
}

private func collectAgentBubbleSurfaces(_ root: NSView) -> [PickyAgentBubbleSurfaceNSView] {
    var out: [PickyAgentBubbleSurfaceNSView] = []
    if let match = root as? PickyAgentBubbleSurfaceNSView {
        out.append(match)
    }
    for sub in root.subviews {
        out.append(contentsOf: collectAgentBubbleSurfaces(sub))
    }
    return out
}

private func collectScrollViews(_ root: NSView) -> [NSScrollView] {
    var out: [NSScrollView] = []
    if let match = root as? NSScrollView {
        out.append(match)
    }
    for sub in root.subviews {
        out.append(contentsOf: collectScrollViews(sub))
    }
    return out
}

@MainActor
private func configuredAgentSurface(markdown: String, codeBlockMaxLines: Int) -> PickyAgentBubbleSurfaceNSView {
    let surface = PickyAgentBubbleSurfaceNSView()
    surface.configure(
        markdown: markdown,
        maxBubbleWidth: 600,
        codeBlockMaxLines: codeBlockMaxLines,
        showsShortcutBadge: false,
        onOpenAsReport: {},
        onCopyText: nil
    )
    let size = surface.measuredSize(forRootWidth: 600)
    surface.frame = NSRect(origin: .zero, size: size)
    surface.layoutSubtreeIfNeeded()
    return surface
}

private func collectTextFieldStrings(_ root: NSView) -> [String] {
    var out: [String] = []
    if let field = root as? NSTextField {
        out.append(field.stringValue)
    }
    for subview in root.subviews {
        out.append(contentsOf: collectTextFieldStrings(subview))
    }
    return out
}

private func collectSubviewTypeNames(_ root: NSView) -> Set<String> {
    var names: Set<String> = [String(describing: type(of: root))]
    for subview in root.subviews {
        names.formUnion(collectSubviewTypeNames(subview))
    }
    return names
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
