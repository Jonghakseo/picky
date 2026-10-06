//
//  PickyRemoteQuickTunnelTests.swift
//  PickyTests
//
//  Runs the real `PickyCloudflareQuickTunnel` against small shell scripts that
//  print what `cloudflared tunnel --url` prints (lines copied from a real run,
//  2025.9.1), so the process handling, log parsing and state changes are
//  exercised without reaching Cloudflare.
//

import Darwin
import Foundation
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyRemoteQuickTunnelTests {
    private static let realStartLines = [
        #"2026-10-05T05:34:07Z INF Requesting new quick Tunnel on trycloudflare.com..."#,
        #"2026-10-05T05:34:07Z INF |  https://argued-libraries-affiliate-distance.trycloudflare.com                              |"#,
        #"2026-10-05T05:34:07Z ERR Cannot determine default origin certificate path. No file cert.pem in [~/.cloudflared ~/.cloudflare-warp ~/cloudflare-warp /etc/cloudflared /usr/local/etc/cloudflared]. You need to specify the origin certificate path by specifying the origincert option in the configuration file, or set TUNNEL_ORIGIN_CERT environment variable originCertPath="#,
        #"2026-10-05T05:34:09Z INF Registered tunnel connection connIndex=0 connection=e64e2cdb-d97c-4e4d-8463-04a534d1943c event=0 ip=198.41.192.167 location=icn06 protocol=quic"#,
    ]

    private final class Sandbox {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("picky-quick-tunnel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// A stand-in `cloudflared`: prints `lines` to stderr, records its
        /// arguments, then runs `tail` (sleep, or exit with a status).
        func script(lines: [String], then tail: String) throws -> URL {
            let url = root.appendingPathComponent("cloudflared-\(UUID().uuidString.prefix(8))")
            let echoes = lines.map { "printf '%s\\n' '\($0.replacingOccurrences(of: "'", with: "'\\''"))' >&2" }
            let body = (["#!/bin/sh", "echo \"$@\" > \"\(root.path)/args.txt\""] + echoes + [tail]).joined(separator: "\n")
            try body.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
            return url
        }

        var arguments: String? {
            try? String(contentsOf: root.appendingPathComponent("args.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var pidFile: URL { root.appendingPathComponent("Remote/cloudflared.pid") }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for: \(what)")
        throw CancellationError()
    }

    @Test func theAddressIsPublishedOnlyOnceTheEdgeAcceptsTheTunnel() async throws {
        let sandbox = try Sandbox()
        // Address printed, connection never registered.
        let pending = try sandbox.script(lines: Array(Self.realStartLines.prefix(3)), then: "exec sleep 30")
        let tunnel = PickyCloudflareQuickTunnel(appSupportRoot: sandbox.root, locateExecutable: { pending })
        defer { tunnel.stopAndWaitForExit() }

        tunnel.start(port: 17640)
        try await waitUntil("the stand-in starts") { sandbox.arguments != nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(tunnel.state == .starting)
        #expect(sandbox.arguments == "tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:17640")
    }

    @Test func aRunningTunnelKeepsItsAddressAndStopsCleanly() async throws {
        let sandbox = try Sandbox()
        let executable = try sandbox.script(lines: Self.realStartLines, then: "exec sleep 30")
        let tunnel = PickyCloudflareQuickTunnel(appSupportRoot: sandbox.root, locateExecutable: { executable })
        var states: [PickyQuickTunnelState] = []
        tunnel.onStateChange = { states.append($0) }

        tunnel.start(port: 17640)
        let url = "https://argued-libraries-affiliate-distance.trycloudflare.com"
        try await waitUntil("the tunnel reports its address") { tunnel.state == .running(url: url) }
        // The origin certificate line is noise for a Quick Tunnel, not a failure.
        #expect(!states.contains { if case .failed = $0 { true } else { false } })

        let pidText = try String(contentsOf: sandbox.pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Darwin.kill(pid, 0) == 0)

        // Starting again for the same port (every settings save does) must not
        // replace the process, which would hand out a new address.
        tunnel.start(port: 17640)
        #expect(tunnel.state == .running(url: url))
        #expect((try? String(contentsOf: sandbox.pidFile, encoding: .utf8)) == pidText)

        tunnel.stopAndWaitForExit()
        #expect(tunnel.state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile.path))
        try await waitUntil("the process is gone") { Darwin.kill(pid, 0) != 0 }
    }

    @Test func aFailedRequestSurfacesCloudflaredsOwnReason() async throws {
        let sandbox = try Sandbox()
        let failing = try sandbox.script(
            lines: [
                #"2026-10-05T05:34:07Z INF Requesting new quick Tunnel on trycloudflare.com..."#,
                #"2026-10-05T05:34:08Z ERR failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": dial tcp: lookup api.trycloudflare.com: no such host"#,
            ],
            then: "exit 1"
        )
        let tunnel = PickyCloudflareQuickTunnel(appSupportRoot: sandbox.root, locateExecutable: { failing })
        defer { tunnel.stopAndWaitForExit() }

        tunnel.start(port: 17640)
        try await waitUntil("the failure is reported") {
            if case .failed = tunnel.state { return true }
            return false
        }
        guard case .failed(let reason) = tunnel.state else { return }
        #expect(reason.hasPrefix("failed to request quick Tunnel"))
    }

    @Test func noCloudflaredMeansNotInstalledAndCheckingAgainFindsIt() async throws {
        let sandbox = try Sandbox()
        let executable = try sandbox.script(lines: Self.realStartLines, then: "exec sleep 30")
        var installed: URL?
        let tunnel = PickyCloudflareQuickTunnel(appSupportRoot: sandbox.root, locateExecutable: { installed })
        defer { tunnel.stopAndWaitForExit() }

        tunnel.start(port: 17640)
        #expect(tunnel.state == .notInstalled)

        installed = executable
        tunnel.start(port: 17640)
        try await waitUntil("the tunnel starts after install") { tunnel.state.url != nil }
    }

    @Test(arguments: [
        ("2026-10-05T05:34:07Z INF |  https://Argued-Libraries.trycloudflare.com  |", "https://argued-libraries.trycloudflare.com"),
        ("2026-10-05T05:34:07Z INF Requesting new quick Tunnel on trycloudflare.com...", nil),
        ("2026-10-05T05:34:07Z INF Visit it at (it may take some time to be reachable): https://picky.example.com", nil),
    ])
    func onlyATrycloudflareAddressCountsAsTheTunnelAddress(line: String, expected: String?) {
        #expect(PickyQuickTunnelLogParser.publicURL(in: line) == expected)
    }
}
