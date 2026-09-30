//
//  PickyMcpServerClient.swift
//  Picky
//
//  Sends MCP server management commands to picky-agentd and waits for the
//  matching reply. agentd edits Pi's global `mcp.json` and runs Pi's own
//  `pi mcp list` / `pi mcp login` implementations.
//

import Foundation

enum PickyMcpServerClient {
    enum Failure: Error, Equatable {
        /// agentd refused the change. `detail` is Pi's message, for example a validation error.
        case rejected(code: PickyMcpServerErrorCode?, detail: String)
        case timedOut
        case disconnected
        case failed(String)
    }

    struct Listing: Equatable {
        let configPath: String?
        let servers: [PickyMcpServer]
        let configErrors: [String]
    }

    /// `pi mcp list` connects to every enabled server, so allow for slow stdio startups.
    static func list(client: any PickyAgentClient, timeoutNanoseconds: UInt64 = 120_000_000_000) async -> Result<Listing, Failure> {
        await request(PickyCommandEnvelope(type: .listMcpServers), client: client, timeoutNanoseconds: timeoutNanoseconds) { event, commandID in
            guard case .mcpServerList(let result) = event, result.commandId == commandID else { return nil }
            guard result.ok else { throw Failure.failed(result.errorMessage ?? "MCP server list failed.") }
            return Listing(configPath: result.configPath, servers: result.servers, configErrors: result.configErrors)
        }
    }

    static func add(name: String, configJson: String, scope: PickyMcpScope, client: any PickyAgentClient) async -> Result<Void, Failure> {
        await perform(PickyCommandEnvelope(type: .addMcpServer, name: name, configJson: configJson, pickyScope: scope), client: client)
    }

    static func update(name: String, enabled: Bool? = nil, scope: PickyMcpScope? = nil, client: any PickyAgentClient) async -> Result<Void, Failure> {
        await perform(PickyCommandEnvelope(type: .updateMcpServer, enabled: enabled, name: name, pickyScope: scope), client: client)
    }

    static func remove(name: String, client: any PickyAgentClient) async -> Result<Void, Failure> {
        await perform(PickyCommandEnvelope(type: .removeMcpServer, name: name), client: client)
    }

    /// Opens the authorization page in the browser; agentd waits up to 300 seconds for the callback.
    static func signIn(name: String, client: any PickyAgentClient) async -> Result<Void, Failure> {
        await perform(PickyCommandEnvelope(type: .signInMcpServer, name: name), client: client, timeoutNanoseconds: 330_000_000_000)
    }

    static func signOut(name: String, client: any PickyAgentClient) async -> Result<Void, Failure> {
        await perform(PickyCommandEnvelope(type: .signOutMcpServer, name: name), client: client)
    }

    private static func perform(
        _ command: PickyCommandEnvelope,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async -> Result<Void, Failure> {
        await request(command, client: client, timeoutNanoseconds: timeoutNanoseconds) { event, commandID in
            guard case .mcpServerOperationCompleted(let result) = event, result.requestId == commandID else { return nil }
            guard result.ok else {
                throw Failure.rejected(code: result.code, detail: result.errorMessage ?? "MCP server operation failed.")
            }
            return ()
        }
    }

    /// Sends one command and waits for the event whose `match` returns a value.
    private static func request<Value: Sendable>(
        _ command: PickyCommandEnvelope,
        client: any PickyAgentClient,
        timeoutNanoseconds: UInt64,
        match: @escaping @Sendable (PickyEvent, String) throws -> Value?
    ) async -> Result<Value, Failure> {
        // Subscribe before sending so a fast reply cannot be missed.
        let stream = await client.events
        let commandID = command.id
        do {
            try await client.send(command)
            let value = try await withThrowingTaskGroup(of: Value.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    for await clientEvent in stream {
                        switch clientEvent {
                        case .protocolEvent(let envelope):
                            if let value = try match(envelope.event, commandID) { return value }
                        case .disconnected:
                            throw Failure.disconnected
                        case .connected, .sessionProjectionBootstrapCompletion, .recoverableError:
                            continue
                        }
                    }
                    throw Failure.disconnected
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    try Task.checkCancellation()
                    throw Failure.timedOut
                }
                guard let value = try await group.next() else { throw Failure.disconnected }
                return value
            }
            return .success(value)
        } catch let error as Failure {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}

/// One server to add, parsed from what the user pasted.
struct PickyMcpServerDraft: Equatable {
    let name: String
    /// A single `mcpServers` entry as JSON. agentd validates it with Pi's rules.
    let configJson: String

    enum ParseError: Error, Equatable {
        case empty
        case invalidJSON
        case missingName
        case noServerConfig
    }

    /// Accepts a bare server entry (`{"command": ...}` or `{"url": ...}`) with a name, or a block
    /// copied from another MCP client: `{"mcpServers": {...}}`, VS Code's `{"servers": {...}}`, or
    /// a map of names to entries. A name typed by the user renames a single pasted entry.
    static func parse(name rawName: String, json rawJSON: String) -> Result<[PickyMcpServerDraft], ParseError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty else { return .failure(.empty) }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }

        if isServerEntry(object) {
            guard !name.isEmpty else { return .failure(.missingName) }
            return encode([(name, object)])
        }

        let named = (object["mcpServers"] as? [String: Any]) ?? (object["servers"] as? [String: Any]) ?? object
        let entries = named.compactMap { key, value -> (String, [String: Any])? in
            guard let entry = value as? [String: Any], isServerEntry(entry) else { return nil }
            return (key, entry)
        }
        .sorted { $0.0 < $1.0 }
        guard !entries.isEmpty else { return .failure(.noServerConfig) }
        if entries.count == 1, !name.isEmpty {
            return encode([(name, entries[0].1)])
        }
        return encode(entries)
    }

    private static func isServerEntry(_ object: [String: Any]) -> Bool {
        object["command"] is String || object["url"] is String
    }

    private static func encode(_ entries: [(String, [String: Any])]) -> Result<[PickyMcpServerDraft], ParseError> {
        var drafts: [PickyMcpServerDraft] = []
        for (name, entry) in entries {
            guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else {
                return .failure(.invalidJSON)
            }
            drafts.append(PickyMcpServerDraft(name: name, configJson: text))
        }
        return .success(drafts)
    }
}
