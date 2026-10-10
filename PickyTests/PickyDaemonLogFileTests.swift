//
//  PickyDaemonLogFileTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyDaemonLogFileTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-logfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// The primary launcher and every Pickle's child launcher append to the same `agentd.*.log`.
    /// A per-writer byte counter would let each of them count only its own bytes and overshoot
    /// the cap; the cap has to come from the file's real size.
    @Test func writersSharingOneFileKeepItUnderTheSizeCap() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("agentd.stdout.log")
        let cap: Int64 = 1024
        let first = PickyRotatingLogFile(url: url, maxSize: cap, maxRotations: 2)
        let second = PickyRotatingLogFile(url: url, maxSize: cap, maxRotations: 2)
        let chunk = Data((String(repeating: "x", count: 399) + "\n").utf8)

        for _ in 0..<30 {
            first.append(chunk)
            second.append(chunk)
        }

        // A writer may overshoot by at most the one chunk that crosses the cap.
        let allowed = cap + Int64(chunk.count)
        for name in ["agentd.stdout.log", "agentd.stdout.log.1", "agentd.stdout.log.2"] {
            #expect(size(of: directory.appendingPathComponent(name)) <= allowed, "\(name) exceeded the cap")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("agentd.stdout.log.3").path))
    }

    @Test func recreatesTheFileAfterItIsDeletedWhileOpen() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gateway.stderr.log")
        let log = PickyRotatingLogFile(url: url, maxSize: 0, maxRotations: 0)

        log.append(Data("before\n".utf8))
        try FileManager.default.removeItem(at: url)
        log.append(Data("after\n".utf8))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "after\n")
    }

    @Test func relayDeliversChunksFromABackgroundQueueInOrder() async throws {
        var received = Data()
        let relay = PickyDaemonOutputRelay { received.append($0) }
        let expected = (0..<200).map { "line \($0)\n" }.joined()

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for index in 0..<200 { relay.receive(Data("line \(index)\n".utf8)) }
                continuation.resume()
            }
        }
        try await withPickyTestTimeout("relay drain") {
            while received.count < expected.utf8.count { await Task.yield() }
        }

        #expect(String(decoding: received, as: UTF8.self) == expected)
    }
}
