import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHubConversationScrollTests {
    /// Opening Recent Conversation must show the newest messages on the first
    /// committed frame. A deferred `proxy.scrollTo` leaves the oldest message
    /// visible until the next run-loop turn, then jumps.
    @Test func longConversationFirstLayoutShowsLatestMessages() throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = try PickyHubRenderGalleryFixture()
        defer { fixture.removeTemporaryState() }
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        fixture.dependencies.companionManager.mainConversation.replaceMessages((0..<60).map { index in
            PickyMainAgentMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "Message \(index) " + String(repeating: "lorem ipsum ", count: 12),
                createdAt: start.addingTimeInterval(Double(index))
            )
        })
        let size = NSSize(width: 1020, height: 720)
        let host = NSHostingView(rootView: PickyHubConversationPage(dependencies: fixture.dependencies)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        // One synchronous layout pass: deferred scroll work has not run yet.
        host.layoutSubtreeIfNeeded()

        let transcript = try #require(scrollViews(in: host).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        let documentHeight = try #require(transcript.documentView).frame.height
        let visible = transcript.documentVisibleRect
        #expect(documentHeight > visible.height * 2, "fixture must overflow the viewport")
        let distanceFromBottom = transcript.documentView?.isFlipped == false
            ? visible.minY
            : documentHeight - visible.maxY
        // Same tolerance the page uses to decide that the reader is at the bottom.
        #expect(
            PickyHubConversationPolicy.isNearBottom(
                bottom: visible.height + distanceFromBottom,
                viewportHeight: visible.height
            ),
            "first frame showed \(visible) of \(documentHeight)"
        )
    }

    private func scrollViews(in root: NSView) -> [NSScrollView] {
        ((root as? NSScrollView).map { [$0] } ?? []) + root.subviews.flatMap(scrollViews(in:))
    }
}
