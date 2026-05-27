//
//  PickySkillInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySkillInstallerTests {
    @Test func statusReportsBundleMissingWithoutBundledSource() throws {
        let scratch = try SkillScratch()

        let status = PickySkillInstaller.status(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )

        #expect(status == .bundleMissing)
    }

    @Test func statusReportsNotInstalledWhenTargetMissing() throws {
        let scratch = try SkillScratch()
        _ = try scratch.makeBundledSkill(named: "picky-cli")

        let status = PickySkillInstaller.status(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )

        #expect(status == .notInstalled)
    }

    @Test func installCopiesSkillDirectoryAndWritesMetadata() throws {
        let scratch = try SkillScratch()
        _ = try scratch.makeBundledSkill(named: "picky-cli")

        var logs: [String] = []
        let result = PickySkillInstaller.install(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        #expect(throws: Never.self) { try result.get() }
        let target = scratch.targetURL(for: "picky-cli")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path))

        let metadata = target.appendingPathComponent(".picky-skill-install.json")
        let data = try Data(contentsOf: metadata)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["managedBy"] as? String == "picky")
        #expect((json?["fingerprint"] as? String)?.isEmpty == false)
        #expect(logs.contains(where: { $0.contains("Installed pi-skill 'picky-cli'") }))

        let status = PickySkillInstaller.status(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .installed)
    }

    @Test func statusReportsOutdatedWhenBundleContentsChanged() throws {
        let scratch = try SkillScratch()
        _ = try scratch.makeBundledSkill(named: "picky-cli")
        _ = PickySkillInstaller.install(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        let skillFile = scratch.bundleResources
            .appendingPathComponent("pi-skills/picky-cli/SKILL.md")
        try Data("# Updated\n".utf8).write(to: skillFile)

        let status = PickySkillInstaller.status(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .outdated)
    }

    @Test func installLeavesRealDirectoryAndReportsConflict() throws {
        let scratch = try SkillScratch()
        _ = try scratch.makeBundledSkill(named: "picky-cli")
        let target = scratch.targetURL(for: "picky-cli")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("SKILL.md")
        try Data("# User skill\n".utf8).write(to: marker)

        let result = PickySkillInstaller.install(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickySkillInstaller.InstallError.self) { try result.get() }
        #expect(String(data: try Data(contentsOf: marker), encoding: .utf8) == "# User skill\n")
    }

    @Test func uninstallRemovesManagedDirectory() throws {
        let scratch = try SkillScratch()
        _ = try scratch.makeBundledSkill(named: "picky-cli")
        _ = PickySkillInstaller.install(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        let result = PickySkillInstaller.uninstall(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: Never.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: scratch.targetURL(for: "picky-cli").path))
    }

    @Test func uninstallRefusesUnmanagedDirectory() throws {
        let scratch = try SkillScratch()
        _ = try scratch.makeBundledSkill(named: "picky-cli")
        let target = scratch.targetURL(for: "picky-cli")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("# User skill\n".utf8).write(to: target.appendingPathComponent("SKILL.md"))

        let result = PickySkillInstaller.uninstall(
            named: "picky-cli",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickySkillInstaller.UninstallError.self) { try result.get() }
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path))
    }
}

private struct SkillScratch {
    let tmp: URL
    let bundleResources: URL
    let home: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-skill-installer-\(UUID().uuidString)", isDirectory: true)
        self.tmp = base
        self.bundleResources = base.appendingPathComponent("Resources", isDirectory: true)
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeBundledSkill(named name: String) throws -> URL {
        let url = bundleResources
            .appendingPathComponent("pi-skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("# Stub\n".utf8).write(to: url.appendingPathComponent("SKILL.md"))
        return url
    }

    func targetURL(for name: String) -> URL {
        home.appendingPathComponent(".pi/agent/skills/\(name)", isDirectory: true)
    }
}
