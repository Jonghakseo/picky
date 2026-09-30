//
//  PickyHubMcpServersTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyHubMcpServersTests {
    // MARK: - Pasting server configurations

    @Test func bareEntryUsesTheTypedName() throws {
        let drafts = try PickyMcpServerDraft.parse(name: " docs ", json: #"{"url":"https://example.com/mcp"}"#).get()

        #expect(drafts == [PickyMcpServerDraft(name: "docs", configJson: #"{"url":"https://example.com/mcp"}"#)])
    }

    @Test func bareEntryWithoutNameIsRejected() {
        #expect(PickyMcpServerDraft.parse(name: "", json: #"{"command":"npx"}"#) == .failure(.missingName))
    }

    @Test func pastedClientBlocksKeepTheirServerNames() throws {
        let claudeDesktop = #"""
        {"mcpServers": {
          "filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]},
          "sentry": {"url": "https://mcp.sentry.dev/mcp"}
        }}
        """#
        let vsCode = #"{"servers": {"github": {"url": "https://api.githubcopilot.com/mcp/"}}}"#

        #expect(try PickyMcpServerDraft.parse(name: "", json: claudeDesktop).get().map(\.name) == ["filesystem", "sentry"])
        #expect(try PickyMcpServerDraft.parse(name: "", json: vsCode).get().map(\.name) == ["github"])
        #expect(try PickyMcpServerDraft.parse(name: "", json: #"{"linear": {"url": "https://mcp.linear.app/mcp"}}"#).get().map(\.name) == ["linear"])
    }

    @Test func typedNameRenamesASinglePastedEntry() throws {
        let drafts = try PickyMcpServerDraft.parse(name: "errors", json: #"{"mcpServers":{"sentry":{"url":"https://mcp.sentry.dev/mcp"}}}"#).get()

        #expect(drafts.map(\.name) == ["errors"])
    }

    @Test func rejectsTextThatIsNotAServerConfiguration() {
        #expect(PickyMcpServerDraft.parse(name: "x", json: "  ") == .failure(.empty))
        #expect(PickyMcpServerDraft.parse(name: "x", json: "{") == .failure(.invalidJSON))
        #expect(PickyMcpServerDraft.parse(name: "x", json: #"{"theme": "dark"}"#) == .failure(.noServerConfig))
    }

    // MARK: - Managing servers through agentd

    @Test func changingScopeUpdatesTheServerAndAsksForAPluginReload() async {
        let client = McpServerFakeClient(servers: [Self.server(name: "sentry", scope: .all)])
        var reloadRequests = 0
        let model = PickyHubMcpServersViewModel(client: client, onSessionConfigChanged: { reloadRequests += 1 })
        await model.refresh()

        await model.setScope(.main, for: model.servers[0])

        let update = client.sent.last
        #expect(update?.type == .updateMcpServer)
        #expect(update?.name == "sentry")
        #expect(update?.pickyScope == .main)
        #expect(update?.enabled == nil)
        #expect(model.servers.map(\.pickyScope) == [.main])
        #expect(reloadRequests == 1)
        #expect(model.feedback == nil)
    }

    @Test func rejectedAddKeepsTheDialogErrorAndDoesNotAskForReload() async {
        let client = McpServerFakeClient(servers: [])
        client.rejectAdd = ("duplicate", "MCP server \"sentry\" already exists")
        var reloadRequests = 0
        let model = PickyHubMcpServersViewModel(client: client, onSessionConfigChanged: { reloadRequests += 1 })

        let error = await model.add([PickyMcpServerDraft(name: "sentry", configJson: #"{"url":"https://mcp.sentry.dev/mcp"}"#)], scope: .main)

        #expect(error == L10n.t("hub.mcp.add.error.duplicate", "sentry"))
        #expect(client.sent.map(\.type) == [.addMcpServer])
        #expect(client.sent.first?.pickyScope == .main)
        #expect(reloadRequests == 0)
    }

    @Test func decodesPiConnectionStatesIncludingFutureOnes() {
        #expect(Self.server(name: "a", scope: .all, state: "needs-auth").state == .needsAuth)
        #expect(Self.server(name: "a", scope: .all, state: "rate-limited").state == .failed)
    }

    private static func server(name: String, scope: PickyMcpScope, state: String = "connected") -> PickyMcpServer {
        let json = """
        {"name":"\(name)","pickyScope":"\(scope.rawValue)","enabled":true,"exposure":"codemode","transport":"https://example.com/mcp","state":"\(state)","tools":["search"],"usesOAuth":true}
        """
        return try! JSONDecoder().decode(PickyMcpServer.self, from: Data(json.utf8))
    }
}

/// Answers MCP commands the way agentd does, on every open event stream.
@MainActor
private final class McpServerFakeClient: PickyAgentClient {
    private(set) var sent: [PickyCommandEnvelope] = []
    var rejectAdd: (code: String, message: String)?
    private let servers: [PickyMcpServer]
    private var continuations: [AsyncStream<PickyClientEvent>.Continuation] = []

    init(servers: [PickyMcpServer]) {
        self.servers = servers
    }

    var events: AsyncStream<PickyClientEvent> {
        AsyncStream { continuations.append($0) }
    }

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        throw PickyAgentClientError.disconnected
    }
    func disconnect() {}

    func send(_ command: PickyCommandEnvelope) async throws {
        sent.append(command)
        let event: PickyEvent
        switch command.type {
        case .listMcpServers:
            event = .mcpServerList(PickyMcpServerListEvent(commandId: command.id, ok: true, configPath: "/tmp/mcp.json", servers: servers, configErrors: [], errorMessage: nil))
        case .addMcpServer where rejectAdd != nil:
            event = .mcpServerOperationCompleted(PickyMcpServerOperationCompletedEvent(requestId: command.id, operation: .add, name: command.name ?? "", ok: false, errorCode: rejectAdd?.code, errorMessage: rejectAdd?.message))
        default:
            event = .mcpServerOperationCompleted(PickyMcpServerOperationCompletedEvent(requestId: command.id, operation: .update, name: command.name ?? "", ok: true, errorCode: nil, errorMessage: nil))
        }
        let envelope = PickyEventEnvelope(id: UUID().uuidString, protocolVersion: pickyAgentProtocolVersion, timestamp: Date(), event: event)
        for continuation in continuations { continuation.yield(.protocolEvent(envelope)) }
    }
}
