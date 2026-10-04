import Foundation
import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyToolImageBubbleTests {
    // Wire shape written by agentd's `toolImageMessage`: a `system` message whose text is the
    // fallback older apps show. The current app must render the image, not that text.
    @Test func daemonToolImageMessageRendersAsImageBubbleInsteadOfFallbackText() throws {
        let json = """
        {"id":"msg-tool-image-call-1","kind":"system","createdAt":"2026-05-05T00:00:00.000Z","text":"Read image: /tmp/screen.png","toolImage":{"toolCallId":"call-1","toolName":"read","path":"/tmp/screen.png","mimeType":"image/png"}}
        """
        let message = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionMessage.self, from: Data(json.utf8))

        #expect(message.toolImage == PickyToolImage(toolCallId: "call-1", toolName: "read", path: "/tmp/screen.png", mimeType: "image/png"))
        #expect(PickyConversationBubbleKind(message: message) == .toolImage)
        #expect(message.openAsReportMarkdown == nil)
    }

    @Test func v2ProjectionRetainsTheImageAndRendersExactlyOneImageBubble() throws {
        let json = """
        {"id":"msg-tool-image-call-1","kind":"system","createdAt":"2026-05-05T00:00:00.000Z","text":"Read image: /tmp/screen.png","toolImage":{"toolCallId":"call-1","toolName":"read","path":"/tmp/screen.png","mimeType":"image/png"}}
        """
        let record = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionMessage.self, from: Data(json.utf8))
        let storage = PickyRegistrySessionProjectionStorage()
        let model = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        let session = PickyProjectionReplayFixtures.bootstrapSession(id: "image-session", index: 0,
            status: .running, archived: false, messages: [record], messageJournalAvailable: true)
        let projection = try JSONSerialization.jsonObject(with: JSONEncoder.pickyAgentProtocolEncoder().encode(session))
        let data = try JSONSerialization.data(withJSONObject: ["sessionId": session.id,
            "epoch": "image-test-epoch", "revision": 1, "complete": true, "omittedFields": [], "projection": projection])
        let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: data)
        #expect(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
        let store = storage.registry.sessionStore(sessionID: session.id)
        let list = PickyConversationListView(session: try #require(PickyConversationStoreResolver.card(from: store)),
            viewModel: model, conversationStore: store.conversationStore)
        #expect(list.visibleMessages.map(\.id) == [record.id])
        #expect(list.visibleMessages.first?.toolImage?.path == "/tmp/screen.png")
        #expect(list.renderSnapshot.toolImageBubbleCount == 1)
    }

    @Test func plainSystemMessageStaysTextBubble() throws {
        let json = """
        {"id":"m","kind":"system","createdAt":"2026-05-05T00:00:00.000Z","text":"Read image: /tmp/screen.png"}
        """
        let message = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionMessage.self, from: Data(json.utf8))
        #expect(PickyConversationBubbleKind(message: message) == .systemText)
    }

    @Test func thumbnailFitsTheBoxWithoutUpscaling() {
        // 2880x1800 Retina screenshot: width-bound at 280pt, aspect preserved.
        #expect(PickyToolImageLayout.displaySize(pixelSize: CGSize(width: 2880, height: 1800), maxWidth: 280) == CGSize(width: 280, height: 175))
        // Tall image is height-bound at 220pt.
        #expect(PickyToolImageLayout.displaySize(pixelSize: CGSize(width: 1000, height: 4000), maxWidth: 280) == CGSize(width: 55, height: 220))
        // A small icon keeps its point size; a tiny one gets the minimum tap target.
        #expect(PickyToolImageLayout.displaySize(pixelSize: CGSize(width: 200, height: 120), maxWidth: 280) == CGSize(width: 100, height: 60))
        #expect(PickyToolImageLayout.displaySize(pixelSize: CGSize(width: 32, height: 32), maxWidth: 280) == CGSize(width: 48, height: 48))
        // A narrow card shrinks the width cap.
        #expect(PickyToolImageLayout.displaySize(pixelSize: CGSize(width: 2880, height: 1800), maxWidth: 160) == CGSize(width: 160, height: 100))
    }
}
