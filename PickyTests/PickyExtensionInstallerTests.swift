//
//  PickyExtensionInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyExtensionInstallerTests {
    // MARK: - Status

    @Test func statusReportsBundleMissingWithoutBundledSource() throws {
        let scratch = try Scratch()

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )

        #expect(status == .bundleMissing)
    }

    @Test func statusReportsNotInstalledWhenTargetMissing() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )

        #expect(status == .notInstalled)
    }

    @Test func statusReportsLegacySymlinkWhenSymlinkPointsAtBundle() throws {
        let scratch = try Scratch()
        let bundle = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: bundle)

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .legacySymlink)
    }

    @Test func statusReportsDeveloperOverrideForExternalSymlink() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let devOverride = scratch.tmp.appendingPathComponent("dev-tree/picky-handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: devOverride, withIntermediateDirectories: true)
        try Data("// dev\n".utf8).write(to: devOverride.appendingPathComponent("index.ts"))
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: devOverride)

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        if case .developerOverride(let dest) = status {
            #expect(dest == devOverride.path)
        } else {
            Issue.record("expected .developerOverride but got \(status)")
        }
    }

    @Test func statusReportsConflictForCustomDirectory() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("hand-rolled".utf8).write(to: target.appendingPathComponent("custom.txt"))

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        if case .conflict(let reason) = status {
            #expect(reason.contains(target.path))
        } else {
            Issue.record("expected .conflict but got \(status)")
        }
    }

    @Test func statusReportsOutdatedWhenBundleContentsChanged() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")

        let firstInstall = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )
        #expect(throws: Never.self) { try firstInstall.get() }

        // Mutate the bundled tree so the fingerprint changes.
        let bundleFile = scratch.bundleResources
            .appendingPathComponent("pi-extensions/picky-handoff/index.ts")
        try Data("// updated\n".utf8).write(to: bundleFile)

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .outdated)
    }

    // MARK: - Install

    @Test func installCopiesDirectoryAndWritesMetadata() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")

        var logs: [String] = []
        let result = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        #expect(throws: Never.self) { try result.get() }
        let target = scratch.targetURL(for: "picky-handoff")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        // Real directory, not a symlink.
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attrs[.type] as? FileAttributeType == .typeDirectory)
        // Bundled file copied through.
        let copied = target.appendingPathComponent("index.ts")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        // Metadata file is present and well-formed.
        let metadata = target.appendingPathComponent(".picky-extension-install.json")
        let data = try Data(contentsOf: metadata)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["managedBy"] as? String == "picky")
        #expect((json?["fingerprint"] as? String)?.isEmpty == false)
        #expect(logs.contains(where: { $0.contains("Installed pi-extension 'picky-handoff'") }))

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .installed)
    }

    @Test func installIsIdempotentWhenAlreadyInstalled() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")

        let first = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )
        #expect(throws: Never.self) { try first.get() }
        let target = scratch.targetURL(for: "picky-handoff")
        let metadata = target.appendingPathComponent(".picky-extension-install.json")
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date

        var logs: [String] = []
        let second = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )
        #expect(throws: Never.self) { try second.get() }
        // No "Installed" log on the idempotent second call.
        #expect(!logs.contains(where: { $0.contains("Installed pi-extension") }))
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test func installUpgradesOutdatedManagedDirectory() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        _ = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        let bundleFile = scratch.bundleResources
            .appendingPathComponent("pi-extensions/picky-handoff/index.ts")
        try Data("// upgraded contents\n".utf8).write(to: bundleFile)

        let result = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )
        #expect(throws: Never.self) { try result.get() }

        let target = scratch.targetURL(for: "picky-handoff")
        let installed = try Data(contentsOf: target.appendingPathComponent("index.ts"))
        #expect(String(data: installed, encoding: .utf8) == "// upgraded contents\n")

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .installed)
    }

    @Test func installMigratesLegacySymlinkIntoCopy() throws {
        let scratch = try Scratch()
        let bundle = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: bundle)

        let result = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )
        #expect(throws: Never.self) { try result.get() }

        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attrs[.type] as? FileAttributeType == .typeDirectory)
        let metadata = target.appendingPathComponent(".picky-extension-install.json")
        #expect(FileManager.default.fileExists(atPath: metadata.path))
    }

    @Test func installLeavesDeveloperOverrideSymlink() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let devOverride = scratch.tmp.appendingPathComponent("dev-tree/picky-handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: devOverride, withIntermediateDirectories: true)
        try Data("// dev\n".utf8).write(to: devOverride.appendingPathComponent("index.ts"))
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: devOverride)

        let result = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickyExtensionInstaller.InstallError.self) { try result.get() }
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        #expect(dest == devOverride.path)
    }

    @Test func installLeavesRealDirectoryAndReportsConflict() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("custom.txt")
        try Data("hand-rolled".utf8).write(to: marker)

        let result = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickyExtensionInstaller.InstallError.self) { try result.get() }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func installFailsWhenBundledExtensionMissing() throws {
        let scratch = try Scratch()
        // Intentionally do not create the bundled extension.

        let result = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickyExtensionInstaller.InstallError.self) { try result.get() }
        let target = scratch.targetURL(for: "picky-handoff")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Uninstall

    @Test func uninstallRemovesManagedDirectory() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        _ = PickyExtensionInstaller.install(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        let result = PickyExtensionInstaller.uninstall(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: Never.self) { try result.get() }
        let target = scratch.targetURL(for: "picky-handoff")
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let status = PickyExtensionInstaller.status(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home
        )
        #expect(status == .notInstalled)
    }

    @Test func uninstallRemovesLegacySymlinkPointingAtBundle() throws {
        let scratch = try Scratch()
        let bundle = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: bundle)

        let result = PickyExtensionInstaller.uninstall(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: Never.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func uninstallRefusesDeveloperOverrideSymlink() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let devOverride = scratch.tmp.appendingPathComponent("dev-tree/picky-handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: devOverride, withIntermediateDirectories: true)
        try Data("// dev\n".utf8).write(to: devOverride.appendingPathComponent("index.ts"))
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: devOverride)

        let result = PickyExtensionInstaller.uninstall(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickyExtensionInstaller.UninstallError.self) { try result.get() }
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        #expect(dest == devOverride.path)
    }

    @Test func uninstallRefusesUnmanagedDirectory() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("hand-rolled".utf8).write(to: target.appendingPathComponent("custom.txt"))

        let result = PickyExtensionInstaller.uninstall(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickyExtensionInstaller.UninstallError.self) { try result.get() }
        // Custom directory left intact.
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("custom.txt").path))
    }

    @Test func uninstallReportsNotInstalledWhenTargetMissing() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")

        let result = PickyExtensionInstaller.uninstall(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { _ in }
        )

        #expect(throws: PickyExtensionInstaller.UninstallError.self) { try result.get() }
    }
}

private struct Scratch {
    let tmp: URL
    let bundleResources: URL
    let home: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-ext-installer-\(UUID().uuidString)", isDirectory: true)
        self.tmp = base
        self.bundleResources = base.appendingPathComponent("Resources", isDirectory: true)
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeBundledExtension(named name: String) throws -> URL {
        let url = bundleResources
            .appendingPathComponent("pi-extensions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("// stub\n".utf8).write(to: url.appendingPathComponent("index.ts"))
        return url
    }

    func targetURL(for name: String) -> URL {
        home.appendingPathComponent(".pi/agent/extensions/\(name)", isDirectory: true)
    }
}
