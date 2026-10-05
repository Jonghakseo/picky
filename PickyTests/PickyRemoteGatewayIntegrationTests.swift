//
//  PickyRemoteGatewayIntegrationTests.swift
//  PickyTests
//
//  The only remote test that runs the real gateway process. Every other one
//  uses fakes, so the pieces that only exist between the app and Node -- the
//  environment variable names, the readiness line, the bearer token, the hub
//  handshake, the pairing round trip and the shutdown -- are unproven there.
//
//  Opt-in, because it spawns Node and binds a port:
//
//    TEST_RUNNER_PICKY_REMOTE_GATEWAY_INTEGRATION=1 xcodebuild ... test \
//      -only-testing:PickyTests/PickyRemoteGatewayIntegrationTests
//
//  It never touches the user's gateway: a random free port (never 17631 or
//  17640) and a throwaway application support directory.
//

import Combine
import Darwin
import Foundation
import Testing

@testable import Picky

// MARK: - Opt-in switch

private enum RemoteGatewayIntegrationSwitch {
    static let environmentKey = "PICKY_REMOTE_GATEWAY_INTEGRATION"
    static var isEnabled: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    /// Reaches Cloudflare over the internet, so it has its own switch and
    /// needs Homebrew's `cloudflared`.
    static let quickTunnelKey = "PICKY_REMOTE_QUICK_TUNNEL_INTEGRATION"
    static var isQuickTunnelEnabled: Bool {
        ProcessInfo.processInfo.environment[quickTunnelKey] == "1" && PickyCloudflaredCLI.locate() != nil
    }
}

// MARK: - Minimal sources (no daemons needed)

@MainActor
private final class EmptyOverlaySource: PickyRemoteOverlaySource {
    private let subject = PassthroughSubject<PickyRemoteOverlaySnapshot, Never>()
    func currentRemoteOverlay() -> PickyRemoteOverlaySnapshot { .empty }
    var remoteOverlayPublisher: AnyPublisher<PickyRemoteOverlaySnapshot, Never> { subject.eraseToAnyPublisher() }
}

/// No primary and no children, so the gateway never dials a daemon on this Mac.
@MainActor
private final class EmptyTopologySource: PickyRemoteDaemonTopologySource {
    private let subject = PassthroughSubject<PickyRemoteDaemonTopology, Never>()
    func currentRemoteDaemonTopology() -> PickyRemoteDaemonTopology {
        PickyRemoteDaemonTopology(token: "integration-token", primaryURL: nil, children: [])
    }
    var remoteDaemonTopologyPublisher: AnyPublisher<PickyRemoteDaemonTopology, Never> { subject.eraseToAnyPublisher() }
}

// MARK: - Local helpers

private enum IntegrationSupport {
    /// `<repo>/PickyTests/<this file>` -> `<repo>`.
    static func repositoryRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A port nobody is listening on right now. Picked by binding to 0, so the
    /// kernel never hands back something already in use.
    static func freeLoopbackPort() -> Int? {
        for _ in 0..<20 {
            guard let port = bindEphemeralPort() else { return nil }
            guard port != 17631, port != PickyRemoteAccessSettings.defaultPort else { continue }
            return port
        }
        return nil
    }

    private static func bindEphemeralPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// True while something accepts TCP on 127.0.0.1:port.
    static func portAcceptsConnections(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}

/// Stands in for the phone's browser: no cookie jar, so every request carries
/// exactly the cookie the test decided to send.
private struct PhoneHTTPClient {
    /// The address the phone opened: loopback, or the tunnel's https origin.
    let origin: String
    private let session: URLSession

    init(port: Int) {
        self.init(origin: "http://127.0.0.1:\(port)")
    }

    init(origin: String) {
        self.origin = origin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
    }

    struct Response {
        var status: Int
        var setCookie: String?
        var json: [String: Any]
    }

    func pair(code: String, deviceName: String) async throws -> Response {
        var request = URLRequest(url: URL(string: "\(origin)/api/pair")!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["code": code, "deviceName": deviceName]
        )
        return try await send(request)
    }

    func me(cookie: String?) async throws -> Response {
        var request = URLRequest(url: URL(string: "\(origin)/api/me")!)
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let cookie { request.setValue("picky_remote=\(cookie)", forHTTPHeaderField: "Cookie") }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(
            status: http?.statusCode ?? -1,
            setCookie: http?.value(forHTTPHeaderField: "Set-Cookie"),
            json: json
        )
    }

    /// `picky_remote=<token>; HttpOnly; ...` -> `<token>`.
    static func deviceToken(fromSetCookie header: String?) -> String? {
        guard let header, let range = header.range(of: "picky_remote=") else { return nil }
        let value = header[range.upperBound...].prefix { $0 != ";" }
        return value.isEmpty ? nil : String(value)
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 20,
    condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    Issue.record("Timed out after \(Int(timeout))s waiting for: \(description)")
    throw CancellationError()
}

// MARK: - The test

@MainActor
@Suite(.serialized)
struct PickyRemoteGatewayIntegrationTests {
    @Test(.enabled(if: RemoteGatewayIntegrationSwitch.isEnabled), .timeLimit(.minutes(2)))
    func theRealGatewayStartsPairsAndStops() async throws {
        let repositoryRoot = IntegrationSupport.repositoryRoot()
        let agentdRoot = repositoryRoot.appendingPathComponent("agentd", isDirectory: true)
        let entryPoint = agentdRoot.appendingPathComponent("dist/gateway/main.js")
        try #require(
            FileManager.default.fileExists(atPath: entryPoint.path),
            "Build the gateway first: pnpm --dir agentd run build (missing \(entryPoint.path))"
        )

        let port = try #require(IntegrationSupport.freeLoopbackPort(), "No free loopback port")
        let appSupportRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-remote-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)

        // The production resolver, pointed at this repository's agentd tree and
        // a PATH that can find node.
        var environment = ProcessInfo.processInfo.environment
        environment["PICKY_AGENTD_ROOT"] = agentdRoot.path
        environment["PATH"] = PickyAgentDaemonConfiguration.augmentedExecutablePATH(from: environment)
        let command = try PickyRemoteGatewayCommandResolver.resolve(
            environment: environment,
            bundleResourceURL: nil
        )

        let launcher = PickyRemoteGatewayLauncher(
            appSupportRoot: appSupportRoot,
            resolveCommand: { command }
        )
        let controller = PickyRemoteAccessController(
            settings: PickyRemoteAccessSettings(enabled: false, entrance: .localOnly, port: port),
            gateway: launcher,
            transport: PickyRemoteHubClient(),
            overlaySource: EmptyOverlaySource(),
            topologySource: EmptyTopologySource(),
            requestHandler: PickyRemoteHubRequestHandler(sessions: nil, mainAgent: nil, dictation: nil),
            dictationReadiness: { .unavailable },
            tailscale: PickyTailscaleService(executableURL: nil),
            appSupportRoot: appSupportRoot,
            appVersion: "integration",
            macName: "Integration Mac",
            tokenFactory: PickyRemoteGatewayCommandResolver.randomHubToken
        )
        defer {
            controller.stopForAppTermination()
            try? FileManager.default.removeItem(at: appSupportRoot)
        }

        // 1. Turning remote access on starts Node and the hub socket comes up.
        //    Connected means the gateway spoke first (`gateway.hello`), so the
        //    token, the env names and the readiness line all held.
        controller.apply(settings: PickyRemoteAccessSettings(enabled: true, entrance: .localOnly, port: port))
        try await waitUntil("the gateway reports it is listening on \(port)", timeout: 30) {
            controller.gatewayState == .running(port: port)
        }
        try await waitUntil("the hub socket is connected", timeout: 30) { controller.isHubConnected }
        #expect(IntegrationSupport.portAcceptsConnections(port))

        // 2. A pairing code comes back from the gateway's own pairing store.
        controller.startPairing()
        try await waitUntil("a pairing code arrives") {
            if case .waiting = controller.pairing { return true }
            return false
        }
        guard case .waiting(let session) = controller.pairing else {
            Issue.record("Expected a waiting pairing session, got \(controller.pairing)")
            return
        }
        #expect(session.code.replacingOccurrences(of: "-", with: "").count == 8)
        #expect(session.expiresAt > Date())

        // 3. The phone posts the code and gets a device cookie.
        let phone = PhoneHTTPClient(port: port)
        let deviceName = "Integration iPhone"
        let paired = try await phone.pair(code: session.code, deviceName: deviceName)
        #expect(paired.status == 200)
        let cookie = try #require(
            PhoneHTTPClient.deviceToken(fromSetCookie: paired.setCookie),
            "No picky_remote cookie in \(paired.setCookie ?? "nil")"
        )
        try await waitUntil("the Mac sees the pairing end") {
            controller.pairing == .ended(reason: .paired, deviceName: deviceName)
        }
        try await waitUntil("the device list reaches the Mac") {
            controller.devices.contains { $0.name == deviceName }
        }

        // 4. That cookie is what makes the phone paired.
        let me = try await phone.me(cookie: cookie)
        #expect(me.status == 200)
        #expect(me.json["paired"] as? Bool == true)

        // 5. Revoking from the Mac invalidates the cookie the phone holds.
        let deviceID = try #require(controller.devices.first { $0.name == deviceName }?.id)
        controller.revokeDevice(id: deviceID)
        try await waitUntil("the revoked device disappears") { controller.devices.isEmpty }
        let afterRevoke = try await phone.me(cookie: cookie)
        #expect(afterRevoke.status == 200)
        #expect(afterRevoke.json["paired"] as? Bool == false)

        // 6. Turning remote access off takes the process and the port with it.
        controller.apply(settings: PickyRemoteAccessSettings(enabled: false, entrance: .localOnly, port: port))
        try await waitUntil("the gateway stops listening on \(port)", timeout: 10) {
            !IntegrationSupport.portAcceptsConnections(port)
        }
        #expect(!launcher.isRunning)
        #expect(!controller.isHubConnected)
    }

    /// What the quick tunnel test needs from the shared setup.
    private struct RealStack {
        let controller: PickyRemoteAccessController
        let appSupportRoot: URL
        let port: Int
    }

    private func makeRealStack(settings: (Int) -> PickyRemoteAccessSettings) throws -> RealStack {
        let agentdRoot = IntegrationSupport.repositoryRoot().appendingPathComponent("agentd", isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: agentdRoot.appendingPathComponent("dist/gateway/main.js").path),
            "Build the gateway first: pnpm --dir agentd run build"
        )
        let port = try #require(IntegrationSupport.freeLoopbackPort(), "No free loopback port")
        let appSupportRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-remote-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PICKY_AGENTD_ROOT"] = agentdRoot.path
        environment["PATH"] = PickyAgentDaemonConfiguration.augmentedExecutablePATH(from: environment)
        let command = try PickyRemoteGatewayCommandResolver.resolve(environment: environment, bundleResourceURL: nil)
        var remembered: String?
        let controller = PickyRemoteAccessController(
            settings: settings(port),
            gateway: PickyRemoteGatewayLauncher(appSupportRoot: appSupportRoot, resolveCommand: { command }),
            transport: PickyRemoteHubClient(),
            overlaySource: EmptyOverlaySource(),
            topologySource: EmptyTopologySource(),
            requestHandler: PickyRemoteHubRequestHandler(sessions: nil, mainAgent: nil, dictation: nil),
            dictationReadiness: { .unavailable },
            tailscale: PickyTailscaleService(executableURL: nil),
            quickTunnelAddressMemory: PickyQuickTunnelAddressMemory(load: { remembered }, save: { remembered = $0 }),
            appSupportRoot: appSupportRoot,
            appVersion: "integration",
            macName: "Integration Mac",
            tokenFactory: PickyRemoteGatewayCommandResolver.randomHubToken
        )
        return RealStack(controller: controller, appSupportRoot: appSupportRoot, port: port)
    }

    /// The temporary Cloudflare address end to end: Picky's own `cloudflared`
    /// gets an address, the gateway learns it, and a phone outside this Mac
    /// pairs through it over https.
    @Test(.enabled(if: RemoteGatewayIntegrationSwitch.isQuickTunnelEnabled), .timeLimit(.minutes(3)))
    func theTemporaryAddressPairsAPhoneThroughCloudflare() async throws {
        let stack = try makeRealStack { port in
            PickyRemoteAccessSettings(enabled: true, entrance: .cloudflare, cloudflareMode: .quick, port: port)
        }
        let controller = stack.controller
        let pidFile = stack.appSupportRoot.appendingPathComponent("Remote/cloudflared.pid")
        defer {
            controller.stopForAppTermination()
            try? FileManager.default.removeItem(at: stack.appSupportRoot)
        }

        try await waitUntil("the hub socket is connected", timeout: 30) { controller.isHubConnected }
        try await waitUntil("Cloudflare hands out a temporary address", timeout: 60) {
            controller.quickTunnelState.url != nil
        }
        let address = try #require(controller.quickTunnelState.url)
        #expect(address.hasSuffix(".trycloudflare.com"))
        #expect(controller.publicURL == address)
        #expect(FileManager.default.fileExists(atPath: pidFile.path))

        // The gateway builds the pairing link from hub.config, so this proves
        // the address reached it.
        controller.startPairing()
        try await waitUntil("a pairing code arrives") {
            if case .waiting = controller.pairing { return true }
            return false
        }
        guard case .waiting(let session) = controller.pairing else { return }
        #expect(session.url?.hasPrefix(address + "/#pair=") == true)

        // A fresh hostname can be missing for a few seconds, and asking that
        // early caches "not found" for trycloudflare.com's 60-second negative
        // TTL, so the wait has to outlast it.
        let phone = PhoneHTTPClient(origin: address)
        var me: PhoneHTTPClient.Response?
        let deadline = Date().addingTimeInterval(100)
        while Date() < deadline {
            if let response = try? await phone.me(cookie: nil), response.status == 200 {
                me = response
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let unpaired = try #require(me, "\(address)/api/me never answered through Cloudflare")
        #expect(unpaired.json["paired"] as? Bool == false)
        // Reached over https, so the gateway sets Secure cookies and allows push.
        #expect(unpaired.json["insecure"] as? Bool == false)

        let paired = try await phone.pair(code: session.code, deviceName: "Tunnel phone")
        #expect(paired.status == 200)
        #expect(paired.setCookie?.contains("Secure") == true)
        let cookie = try #require(PhoneHTTPClient.deviceToken(fromSetCookie: paired.setCookie))
        #expect(try await phone.me(cookie: cookie).json["paired"] as? Bool == true)

        controller.apply(settings: PickyRemoteAccessSettings(enabled: false, entrance: .cloudflare, cloudflareMode: .quick, port: stack.port))
        #expect(controller.quickTunnelState == .stopped)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }
}
