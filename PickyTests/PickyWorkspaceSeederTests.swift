//
//  PickyWorkspaceSeederTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyWorkspaceSeederTests {
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

    @Test func seedRemovesLegacyPickyTellPlanExtensionWhenPresent() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceURL = URL(fileURLWithPath: PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root), isDirectory: true)
        let extensionsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.extensionsDirectoryRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        let legacyURL = extensionsURL.appendingPathComponent("picky-tell-plan.ts", isDirectory: false)
        try Data("// legacy\n".utf8).write(to: legacyURL)

        _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func seedIsNoOpWhenLegacyPickyTellPlanExtensionDoesNotExist() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspacePath = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })
        let legacyURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(PickyWorkspaceSeeder.extensionsDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent("picky-tell-plan.ts", isDirectory: false)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func seedWithArbitraryWorkspacePathDoesNotRemoveLegacyTellPlan() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceURL = root.appendingPathComponent("CustomRepo", isDirectory: true)
        let extensionsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.extensionsDirectoryRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        let legacyURL = extensionsURL.appendingPathComponent("picky-tell-plan.ts", isDirectory: false)
        try Data("// user-owned legacy extension\n".utf8).write(to: legacyURL)

        PickyWorkspaceSeeder.seed(workspacePath: workspaceURL.path, log: { _ in })

        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func seedMigratesLegacyAgentsMarkdownWhenContentMatches() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceURL = URL(fileURLWithPath: PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let agentsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
        try PickyWorkspaceSeeder.legacyAgentsMarkdownWithTellPlanForTesting.write(to: agentsURL, atomically: true, encoding: .utf8)

        _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })

        let body = try String(contentsOf: agentsURL, encoding: .utf8)
        #expect(body == PickyWorkspaceSeeder.defaultAgentsMarkdown)
        #expect(!body.contains("Announce the plan before tool calls"))
    }

    @Test func seedPreservesAgentsMarkdownWhenUserModified() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceURL = URL(fileURLWithPath: PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let agentsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
        let customized = PickyWorkspaceSeeder.legacyAgentsMarkdownWithTellPlanForTesting + "\n# user customized\n"
        try customized.write(to: agentsURL, atomically: true, encoding: .utf8)

        _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })

        let body = try String(contentsOf: agentsURL, encoding: .utf8)
        #expect(body == customized)
    }

    @Test func seedDoesNotMigrateUnrelatedAgentsMarkdown() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceURL = URL(fileURLWithPath: PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: root), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let agentsURL = workspaceURL.appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename)
        let unrelated = "# user customized\n"
        try unrelated.write(to: agentsURL, atomically: true, encoding: .utf8)

        _ = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: root, log: { _ in })

        let body = try String(contentsOf: agentsURL, encoding: .utf8)
        #expect(body == unrelated)
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

    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("picky-workspace-\(UUID().uuidString)", isDirectory: true)
    }
}
