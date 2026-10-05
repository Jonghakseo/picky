//
//  PickyRemoteProtocol.swift
//  Picky
//
//  Swift mirror of the hub <-> gateway wire contract defined in
//  `agentd/src/remote/hub-protocol.ts`. Example messages for both directions
//  live in `contracts/remote/hub/`; `PickyRemoteProtocolTests` decodes the
//  gateway direction and round-trips the hub direction against those files.
//
//  Keep this file free of UI and process concerns: it is pure wire shape.
//

import Foundation

enum PickyRemoteHubProtocol {
    /// Must match `HUB_PROTOCOL_VERSION` in `agentd/src/remote/hub-protocol.ts`.
    static let version = 1
}

// MARK: - Shared payloads

struct PickyRemoteDictationAvailability: Equatable, Codable {
    enum Reason: String, Equatable, Codable {
        case macPermission
        case macService
        case macUnavailable
    }

    var available: Bool
    /// Present only when `available == false`.
    var reason: Reason?

    static let availableNow = PickyRemoteDictationAvailability(available: true, reason: nil)

    static func unavailable(_ reason: Reason) -> PickyRemoteDictationAvailability {
        PickyRemoteDictationAvailability(available: false, reason: reason)
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case reason
    }

    init(available: Bool, reason: Reason?) {
        self.available = available
        self.reason = available ? nil : reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Bool.self, forKey: .available)
        reason = available ? nil : try container.decodeIfPresent(Reason.self, forKey: .reason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        if !available {
            try container.encode(reason ?? .macUnavailable, forKey: .reason)
        }
    }
}

struct PickyRemoteDaemonEndpoint: Equatable, Codable {
    var url: String
}

struct PickyRemoteDaemonChild: Equatable, Codable {
    var sessionId: String
    var url: String
}

struct PickyRemoteOverlayGroup: Equatable, Codable {
    var id: String
    var name: String
    var color: String
    var memberIds: [String]
}

struct PickyRemoteOverlayFolders: Equatable, Codable {
    var pinned: [String]
    var recent: [String]

    static let empty = PickyRemoteOverlayFolders(pinned: [], recent: [])
}

/// App-owned room state the session projection does not carry.
struct PickyRemoteOverlaySnapshot: Equatable, Codable {
    var activeSessionIds: [String]
    var archivedSessionIds: [String]
    var unreadSessionIds: [String]
    var groups: [PickyRemoteOverlayGroup]
    var folders: PickyRemoteOverlayFolders

    static let empty = PickyRemoteOverlaySnapshot(
        activeSessionIds: [],
        archivedSessionIds: [],
        unreadSessionIds: [],
        groups: [],
        folders: .empty
    )
}

struct PickyRemoteDevice: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var createdAt: Date
    var lastSeenAt: Date?
    var online: Bool
    var pushEnabled: Bool
    /// Paired from a browser on this Mac. Absent on the wire for every other device.
    var local: Bool?

    var isLocal: Bool { local == true }
}

// MARK: - Hub -> gateway

/// Reply to `gateway.request`. Two shapes share one `type`.
enum PickyRemoteHubResponse: Equatable {
    case ok(requestId: String, data: JSONValue?)
    case failure(requestId: String, code: String, message: String)

    var requestId: String {
        switch self {
        case .ok(let requestId, _), .failure(let requestId, _, _): requestId
        }
    }
}

enum PickyHubToGatewayMessage: Equatable {
    case hello(protocolVersion: Int, appVersion: String, macName: String)
    case daemons(token: String, primary: PickyRemoteDaemonEndpoint?, children: [PickyRemoteDaemonChild])
    case overlay(PickyRemoteOverlaySnapshot)
    case config(publicUrl: String?, dictation: PickyRemoteDictationAvailability)
    case pairingStart
    case pairingCancel
    /// "Open in browser": asks for a one-time loopback sign-in link (`gateway.localOpen`).
    case localOpenStart
    case devicesRevoke(deviceId: String)
    case devicesRename(deviceId: String, name: String)
    case response(PickyRemoteHubResponse)

    var type: String {
        switch self {
        case .hello: "hub.hello"
        case .daemons: "hub.daemons"
        case .overlay: "hub.overlay"
        case .config: "hub.config"
        case .pairingStart: "hub.pairing.start"
        case .pairingCancel: "hub.pairing.cancel"
        case .localOpenStart: "hub.localOpen.start"
        case .devicesRevoke: "hub.devices.revoke"
        case .devicesRename: "hub.devices.rename"
        case .response: "hub.response"
        }
    }
}

extension PickyHubToGatewayMessage: Codable {
    private enum Key: String, CodingKey {
        case type
        case protocolVersion, appVersion, macName
        case token, primary, children
        case activeSessionIds, archivedSessionIds, unreadSessionIds, groups, folders
        case publicUrl, dictation
        case deviceId, name
        case requestId, ok, data, error
    }

    private struct ErrorPayload: Codable, Equatable {
        var code: String
        var message: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hub.hello":
            self = .hello(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                appVersion: try container.decode(String.self, forKey: .appVersion),
                macName: try container.decode(String.self, forKey: .macName)
            )
        case "hub.daemons":
            self = .daemons(
                token: try container.decode(String.self, forKey: .token),
                primary: try container.decodeIfPresent(PickyRemoteDaemonEndpoint.self, forKey: .primary),
                children: try container.decode([PickyRemoteDaemonChild].self, forKey: .children)
            )
        case "hub.overlay":
            self = .overlay(PickyRemoteOverlaySnapshot(
                activeSessionIds: try container.decode([String].self, forKey: .activeSessionIds),
                archivedSessionIds: try container.decode([String].self, forKey: .archivedSessionIds),
                unreadSessionIds: try container.decode([String].self, forKey: .unreadSessionIds),
                groups: try container.decode([PickyRemoteOverlayGroup].self, forKey: .groups),
                folders: try container.decode(PickyRemoteOverlayFolders.self, forKey: .folders)
            ))
        case "hub.config":
            self = .config(
                publicUrl: try container.decodeIfPresent(String.self, forKey: .publicUrl),
                dictation: try container.decode(PickyRemoteDictationAvailability.self, forKey: .dictation)
            )
        case "hub.pairing.start":
            self = .pairingStart
        case "hub.pairing.cancel":
            self = .pairingCancel
        case "hub.localOpen.start":
            self = .localOpenStart
        case "hub.devices.revoke":
            self = .devicesRevoke(deviceId: try container.decode(String.self, forKey: .deviceId))
        case "hub.devices.rename":
            self = .devicesRename(
                deviceId: try container.decode(String.self, forKey: .deviceId),
                name: try container.decode(String.self, forKey: .name)
            )
        case "hub.response":
            let requestId = try container.decode(String.self, forKey: .requestId)
            if try container.decode(Bool.self, forKey: .ok) {
                self = .response(.ok(requestId: requestId, data: try container.decodeIfPresent(JSONValue.self, forKey: .data)))
            } else {
                let error = try container.decode(ErrorPayload.self, forKey: .error)
                self = .response(.failure(requestId: requestId, code: error.code, message: error.message))
            }
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown hub message type: \(type)"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .hello(let protocolVersion, let appVersion, let macName):
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(appVersion, forKey: .appVersion)
            try container.encode(macName, forKey: .macName)
        case .daemons(let token, let primary, let children):
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(primary, forKey: .primary)
            try container.encode(children, forKey: .children)
        case .overlay(let overlay):
            try container.encode(overlay.activeSessionIds, forKey: .activeSessionIds)
            try container.encode(overlay.archivedSessionIds, forKey: .archivedSessionIds)
            try container.encode(overlay.unreadSessionIds, forKey: .unreadSessionIds)
            try container.encode(overlay.groups, forKey: .groups)
            try container.encode(overlay.folders, forKey: .folders)
        case .config(let publicUrl, let dictation):
            try container.encodeIfPresent(publicUrl, forKey: .publicUrl)
            try container.encode(dictation, forKey: .dictation)
        case .pairingStart, .pairingCancel, .localOpenStart:
            break
        case .devicesRevoke(let deviceId):
            try container.encode(deviceId, forKey: .deviceId)
        case .devicesRename(let deviceId, let name):
            try container.encode(deviceId, forKey: .deviceId)
            try container.encode(name, forKey: .name)
        case .response(.ok(let requestId, let data)):
            try container.encode(requestId, forKey: .requestId)
            try container.encode(true, forKey: .ok)
            try container.encodeIfPresent(data, forKey: .data)
        case .response(.failure(let requestId, let code, let message)):
            try container.encode(requestId, forKey: .requestId)
            try container.encode(false, forKey: .ok)
            try container.encode(ErrorPayload(code: code, message: message), forKey: .error)
        }
    }
}

// MARK: - Gateway -> hub

/// App-owned actions the gateway asks the hub to run for a paired device.
enum PickyRemoteHubRequest: Equatable {
    case pickleCreate(cwd: String)
    case mainSend(text: String)
    case mainAbort
    case mainAnswer(requestId: String, value: JSONValue)
    case sessionMarkRead(sessionId: String)
    case sessionArchive(sessionId: String, archived: Bool)
    case dictationTranscribe(filePath: String, mime: String)
}

extension PickyRemoteHubRequest: Decodable {
    private enum Key: String, CodingKey {
        case type, cwd, text, requestId, value, sessionId, archived, filePath, mime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pickle.create":
            self = .pickleCreate(cwd: try container.decode(String.self, forKey: .cwd))
        case "main.send":
            self = .mainSend(text: try container.decode(String.self, forKey: .text))
        case "main.abort":
            self = .mainAbort
        case "main.answer":
            self = .mainAnswer(
                requestId: try container.decode(String.self, forKey: .requestId),
                value: try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
            )
        case "session.markRead":
            self = .sessionMarkRead(sessionId: try container.decode(String.self, forKey: .sessionId))
        case "session.archive":
            self = .sessionArchive(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                archived: try container.decode(Bool.self, forKey: .archived)
            )
        case "dictation.transcribe":
            self = .dictationTranscribe(
                filePath: try container.decode(String.self, forKey: .filePath),
                mime: try container.decode(String.self, forKey: .mime)
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown hub request type: \(type)"
            ))
        }
    }
}

enum PickyRemotePairingEndReason: String, Equatable, Decodable {
    case paired
    case expired
    case cancelled
    case exhausted
}

enum PickyGatewayToHubMessage: Equatable {
    case hello(protocolVersion: Int, version: String, port: Int)
    case pairing(code: String, expiresAt: Date, url: String?)
    case pairingEnded(reason: PickyRemotePairingEndReason, deviceName: String?)
    case devices([PickyRemoteDevice])
    /// One-time `http://127.0.0.1:<port>/api/local-open?token=...` for this Mac's default browser.
    case localOpen(url: String)
    case request(requestId: String, deviceId: String, request: PickyRemoteHubRequest)
}

extension PickyGatewayToHubMessage: Decodable {
    private enum Key: String, CodingKey {
        case type, protocolVersion, version, port
        case code, expiresAt, url, reason, deviceName
        case devices, requestId, deviceId, request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "gateway.hello":
            self = .hello(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                version: try container.decode(String.self, forKey: .version),
                port: try container.decode(Int.self, forKey: .port)
            )
        case "gateway.pairing":
            self = .pairing(
                code: try container.decode(String.self, forKey: .code),
                expiresAt: try container.decode(Date.self, forKey: .expiresAt),
                url: try container.decodeIfPresent(String.self, forKey: .url)
            )
        case "gateway.pairing.ended":
            self = .pairingEnded(
                reason: try container.decode(PickyRemotePairingEndReason.self, forKey: .reason),
                deviceName: try container.decodeIfPresent(String.self, forKey: .deviceName)
            )
        case "gateway.devices":
            self = .devices(try container.decode([PickyRemoteDevice].self, forKey: .devices))
        case "gateway.localOpen":
            self = .localOpen(url: try container.decode(String.self, forKey: .url))
        case "gateway.request":
            self = .request(
                requestId: try container.decode(String.self, forKey: .requestId),
                deviceId: try container.decode(String.self, forKey: .deviceId),
                request: try container.decode(PickyRemoteHubRequest.self, forKey: .request)
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown gateway message type: \(type)"
            ))
        }
    }
}

// MARK: - Codec

enum PickyRemoteProtocolCodec {
    static func decodeGatewayMessage(_ data: Data) throws -> PickyGatewayToHubMessage {
        try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyGatewayToHubMessage.self, from: data)
    }

    static func encodeHubMessage(_ message: PickyHubToGatewayMessage) throws -> Data {
        try JSONEncoder.pickyAgentProtocolEncoder().encode(message)
    }
}

/// Error codes the hub replies with. They match the codes listed in
/// `agentd/src/remote/hub-protocol.ts` for `dictation.transcribe` plus the
/// generic codes the gateway maps to a user-facing message.
enum PickyRemoteHubErrorCode {
    static let macUnavailable = "macUnavailable"
    static let macPermission = "macPermission"
    static let macService = "macService"
    static let noSpeech = "noSpeech"
    static let failed = "failed"
    static let invalidRequest = "invalidRequest"
}
