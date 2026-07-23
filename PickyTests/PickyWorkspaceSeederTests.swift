//
//  PickyWorkspaceSeederTests.swift
//  PickyTests
//

import CryptoKit
import Foundation
import Testing
@testable import Picky

struct PickyWorkspaceSeederTests {
    private let historicalLegacyFixtures: [(filename: String, byteCount: Int, sha256: String)] = [
        ("legacy-default-70b88e29.md", 6051, "1b5b4c9e945550a12ff0ce69133b5fd9af0a26f7203319508658842adaf9450c"),
        ("legacy-default-0e45238b.md", 6154, "d2f0f0e3f7c0630a3280ea8a53f8a8baa15c39759fcf6afc5af788bdd05ec616"),
        ("legacy-default-238fd9b8.md", 6055, "9bf890b3ebbf4f9a2b845bbbd92f22895b05e7d5581e6c2030baf79d900f3a9b"),
        ("legacy-default-526c8e44.md", 6134, "a51cb73cc976670185eb0270eeb495920c00239a2d35c13b3a51a3e1df56933c"),
    ]

    @Test func defaultWorkspacePathLivesUnderAppSupport() {
        let root = URL(fileURLWithPath: "/tmp/picky-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        let path = PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root)
        #expect(path == root.appendingPathComponent("Workspace", isDirectory: true).path)
    }

    @Test func seedCreatesDirectoryAndAgentsMarkdown() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspacePath = PickyWorkspaceSeeder.seedDefaultWorkspace(
            appSupportRoot: root,
            log: { _ in }
        )

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let agentsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
        let body = try String(contentsOf: agentsURL, encoding: .utf8)
        #expect(body.contains("# Picky main agent"))
        #expect(body.contains("picky_start_pickle"))
    }

    @Test func historicalLegacyFixturesMatchPublishedBytes() throws {
        for fixture in historicalLegacyFixtures {
            let data = try historicalFixtureData(named: fixture.filename)
            #expect(data.count == fixture.byteCount)
            #expect(sha256Hex(of: data) == fixture.sha256)
        }
    }

    @Test func seedMigratesEveryExactShippedLegacyDefaultAndIsIdempotent() throws {
        for fixture in historicalLegacyFixtures {
            let root = scratchRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            let agentsURL = try makeAgentsURL(in: root)
            try historicalFixtureData(named: fixture.filename).write(to: agentsURL)

            _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
            let migrated = try Data(contentsOf: agentsURL)
            #expect(migrated == Data(PickyWorkspaceSeeder.defaultAgentsMarkdown.utf8))

            _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
            #expect(try Data(contentsOf: agentsURL) == migrated)
        }
    }

    @Test func seedPreservesOneCharacterModificationOfEveryShippedLegacyDefault() throws {
        for fixture in historicalLegacyFixtures {
            let root = scratchRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            let agentsURL = try makeAgentsURL(in: root)
            var userModified = try historicalFixtureData(named: fixture.filename)
            userModified.append(UInt8(ascii: "!"))
            try userModified.write(to: agentsURL)

            _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
            #expect(try Data(contentsOf: agentsURL) == userModified)
        }
    }

    @Test func seedPreservesCurrentAndUnknownAgentsMarkdown() throws {
        let contents = [
            Data(PickyWorkspaceSeeder.defaultAgentsMarkdown.utf8),
            Data("# a user-owned workspace\n".utf8),
        ]

        for content in contents {
            let root = scratchRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            let agentsURL = try makeAgentsURL(in: root)
            try content.write(to: agentsURL)

            _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
            #expect(try Data(contentsOf: agentsURL) == content)
        }
    }

    @Test func seedWritesCurrentDefaultWhenAgentsMarkdownIsMissing() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspacePath = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
        let agentsURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)

        #expect(try Data(contentsOf: agentsURL) == Data(PickyWorkspaceSeeder.defaultAgentsMarkdown.utf8))
    }

    @Test func seedNeverOverwritesExistingAgentsMarkdown() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceURL = URL(fileURLWithPath: PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let agentsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
        try Data("# user customized\n".utf8).write(to: agentsURL)

        _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })

        let body = try String(contentsOf: agentsURL, encoding: .utf8)
        #expect(body == "# user customized\n")
    }

    @Test func seedIsIdempotent() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
        let second = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })

        #expect(first == second)
        let agentsURL = URL(fileURLWithPath: first, isDirectory: true)
            .appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
        #expect(FileManager.default.fileExists(atPath: agentsURL.path))
    }

    @Test func defaultsResolveCwdAndMainAgentCwdToSeededWorkspace() {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = PickySettings.defaults(appSupportRoot: root)
        let expected = PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root)

        #expect(settings.defaultCwd == expected)
        #expect(settings.mainAgentCwd == expected)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: expected, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    private func historicalFixtureData(named filename: String) throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Workspace", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        return try Data(contentsOf: fixtureURL)
    }

    private func makeAgentsURL(in root: URL) throws -> URL {
        let workspaceURL = URL(
            fileURLWithPath: PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        return workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("picky-workspace-\(UUID().uuidString)", isDirectory: true)
    }
}
