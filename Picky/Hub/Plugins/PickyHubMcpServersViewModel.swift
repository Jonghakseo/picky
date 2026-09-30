//
//  PickyHubMcpServersViewModel.swift
//  Picky
//
//  State for the MCP servers section of the Hub Plugins page. Changes that
//  alter which servers sessions connect to mark the plugin reload banner, the
//  same way plugin installs do; sign-in applies on the next turn without one.
//

import Combine
import Foundation

@MainActor
final class PickyHubMcpServersViewModel: ObservableObject {
    struct Feedback: Equatable {
        let message: String
        let isError: Bool
    }

    @Published private(set) var servers: [PickyMcpServer] = []
    @Published private(set) var configErrors: [String] = []
    @Published private(set) var configPath: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    /// Servers with a change or sign-in in flight.
    @Published private(set) var busyNames: Set<String> = []
    @Published private(set) var signingInName: String?
    @Published var feedback: Feedback?

    private let client: any PickyAgentClient
    private let onSessionConfigChanged: () -> Void
    private var refreshGeneration = 0

    init(client: any PickyAgentClient, onSessionConfigChanged: @escaping () -> Void) {
        self.client = client
        self.onSessionConfigChanged = onSessionConfigChanged
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        loadError = nil
        let result = await PickyMcpServerClient.list(client: client)
        // A later refresh owns the published state.
        guard generation == refreshGeneration else { return }
        isLoading = false
        hasLoaded = true
        switch result {
        case .success(let listing):
            servers = listing.servers
            configErrors = listing.configErrors
            configPath = listing.configPath
        case .failure(let failure):
            loadError = Self.message(for: failure)
        }
    }

    /// Adds every draft. Returns the first failure's message, or nil when all were added.
    func add(_ drafts: [PickyMcpServerDraft], scope: PickyMcpScope) async -> String? {
        var added = 0
        var failure: String?
        for draft in drafts {
            switch await PickyMcpServerClient.add(name: draft.name, configJson: draft.configJson, scope: scope, client: client) {
            case .success:
                added += 1
            case .failure(let error):
                failure = Self.addMessage(for: error, name: draft.name)
            }
            if failure != nil { break }
        }
        if added > 0 {
            onSessionConfigChanged()
            await refresh()
        }
        return failure
    }

    func setScope(_ scope: PickyMcpScope, for server: PickyMcpServer) async {
        guard server.pickyScope != scope else { return }
        await change(server) {
            await PickyMcpServerClient.update(name: server.name, scope: scope, client: self.client)
        } onSuccess: {
            self.replace(server.name) { $0.pickyScope = scope }
        }
    }

    func setEnabled(_ enabled: Bool, for server: PickyMcpServer) async {
        guard server.enabled != enabled else { return }
        await change(server) {
            await PickyMcpServerClient.update(name: server.name, enabled: enabled, client: self.client)
        } onSuccess: {}
        await refresh()
    }

    func remove(_ server: PickyMcpServer) async {
        await change(server) {
            await PickyMcpServerClient.remove(name: server.name, client: self.client)
        } onSuccess: {
            self.servers.removeAll { $0.name == server.name }
            self.feedback = Feedback(message: L10n.t("hub.mcp.feedback.removed", server.name), isError: false)
        }
    }

    func signIn(_ server: PickyMcpServer) async {
        busyNames.insert(server.name)
        signingInName = server.name
        feedback = nil
        let result = await PickyMcpServerClient.signIn(name: server.name, client: client)
        signingInName = nil
        busyNames.remove(server.name)
        switch result {
        case .success:
            feedback = Feedback(message: L10n.t("hub.mcp.feedback.signedIn", server.name), isError: false)
        case .failure(let failure):
            feedback = Feedback(message: L10n.t("hub.mcp.error.signIn", server.name, Self.message(for: failure)), isError: true)
        }
        await refresh()
    }

    func signOut(_ server: PickyMcpServer) async {
        busyNames.insert(server.name)
        feedback = nil
        let result = await PickyMcpServerClient.signOut(name: server.name, client: client)
        busyNames.remove(server.name)
        switch result {
        case .success:
            feedback = Feedback(message: L10n.t("hub.mcp.feedback.signedOut", server.name), isError: false)
        case .failure(let failure):
            feedback = Feedback(message: L10n.t("hub.mcp.error.operation", server.name, Self.message(for: failure)), isError: true)
        }
        await refresh()
    }

    /// Runs a config change. Success marks sessions as needing a plugin reload.
    private func change(
        _ server: PickyMcpServer,
        run: () async -> Result<Void, PickyMcpServerClient.Failure>,
        onSuccess: () -> Void
    ) async {
        busyNames.insert(server.name)
        feedback = nil
        let result = await run()
        busyNames.remove(server.name)
        switch result {
        case .success:
            onSuccess()
            onSessionConfigChanged()
        case .failure(let failure):
            feedback = Feedback(message: L10n.t("hub.mcp.error.operation", server.name, Self.message(for: failure)), isError: true)
        }
    }

    private func replace(_ name: String, _ update: (inout PickyMcpServer) -> Void) {
        guard let index = servers.firstIndex(where: { $0.name == name }) else { return }
        update(&servers[index])
    }

    private static func addMessage(for failure: PickyMcpServerClient.Failure, name: String) -> String {
        switch failure {
        case .rejected(.duplicate, _):
            return L10n.t("hub.mcp.add.error.duplicate", name)
        case .rejected(_, let detail):
            return L10n.t("hub.mcp.add.error.invalid", name, detail)
        default:
            return message(for: failure)
        }
    }

    private static func message(for failure: PickyMcpServerClient.Failure) -> String {
        switch failure {
        case .rejected(_, let detail), .failed(let detail):
            return detail
        case .timedOut:
            return L10n.t("hub.plugins.error.timeout")
        case .disconnected:
            return L10n.t("hub.plugins.error.disconnected")
        }
    }
}
