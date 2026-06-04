//
//  PickyPiInstallationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyPiInstallationTests {
    @Test func explicitBinaryPathWinsOverPathLookup() throws {
        let scratch = try ScratchPiInstallation()
        let explicitPi = try scratch.makeExecutable(at: "custom/pi")
        _ = try scratch.makeExecutable(at: "path/pi")

        let resolved = PickyPiInstallation.resolve(
            preferences: PickyPiInstallationPreferences(binaryPath: explicitPi.path),
            homeURL: scratch.home,
            environment: ["PATH": scratch.tmp.appendingPathComponent("path").path]
        )

        #expect(resolved.binaryURL?.path == explicitPi.path)
    }

    @Test func configuredAgentDirSuppliesBinaryAndEnvironmentDir() throws {
        let scratch = try ScratchPiInstallation()
        let agentDir = scratch.tmp.appendingPathComponent("agent", isDirectory: true)
        let pi = try scratch.makeExecutable(at: "agent/bin/pi")

        let resolved = PickyPiInstallation.resolve(
            preferences: PickyPiInstallationPreferences(codingAgentDir: agentDir.path),
            homeURL: scratch.home,
            environment: [:]
        )
        let environment = PickyPiInstallation.mergedEnvironment(
            preferences: PickyPiInstallationPreferences(codingAgentDir: agentDir.path),
            homeURL: scratch.home,
            environment: [:]
        )

        #expect(resolved.binaryURL?.path == pi.path)
        #expect(resolved.codingAgentDirURL.path == agentDir.path)
        #expect(environment["PI_CODING_AGENT_DIR"] == agentDir.path)
        #expect(environment["PATH"]?.split(separator: ":").first == Substring(agentDir.appendingPathComponent("bin").path))
    }

    @Test func pathLookupBehavesLikeWhichPiAndInfersAgentDirFromBinPi() throws {
        let scratch = try ScratchPiInstallation()
        let agentDir = scratch.tmp.appendingPathComponent("elsewhere/agent", isDirectory: true)
        let pi = try scratch.makeExecutable(at: "elsewhere/agent/bin/pi")

        let resolved = PickyPiInstallation.resolve(
            homeURL: scratch.home,
            environment: ["PATH": agentDir.appendingPathComponent("bin").path]
        )

        #expect(resolved.binaryURL?.path == pi.path)
        #expect(resolved.codingAgentDirURL.path == agentDir.path)
    }

    @Test func fallsBackToLegacyHomeAgentPi() throws {
        let scratch = try ScratchPiInstallation()
        let pi = try scratch.makeExecutable(at: "home/.pi/agent/bin/pi")

        let resolved = PickyPiInstallation.resolve(homeURL: scratch.home, environment: [:])

        #expect(resolved.binaryURL?.path == pi.path)
        #expect(resolved.codingAgentDirURL.path == scratch.home.appendingPathComponent(".pi/agent").path)
    }
}

private struct ScratchPiInstallation {
    let tmp: URL
    let home: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-pi-installation-\(UUID().uuidString)", isDirectory: true)
        self.tmp = base
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeExecutable(at relativePath: String) throws -> URL {
        let url = tmp.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
