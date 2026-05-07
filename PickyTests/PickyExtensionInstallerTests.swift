//
//  PickyExtensionInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyExtensionInstallerTests {
    @Test func installCreatesSymlinkWhenTargetMissing() throws {
        let scratch = try Scratch()
        let bundle = try scratch.makeBundledExtension(named: "picky-handoff")

        var logs: [String] = []
        PickyExtensionInstaller.installExtension(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        let target = scratch.targetURL(for: "picky-handoff")
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        #expect(dest == bundle.path)
        #expect(logs.contains(where: { $0.contains("Linked pi-extension 'picky-handoff'") }))
    }

    @Test func installIsIdempotentWhenSymlinkAlreadyMatches() throws {
        let scratch = try Scratch()
        let bundle = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: bundle)

        var logs: [String] = []
        PickyExtensionInstaller.installExtension(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        #expect(logs.isEmpty)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        #expect(dest == bundle.path)
    }

    @Test func installLeavesUnrelatedSymlinkAndWarns() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let devOverride = scratch.tmp.appendingPathComponent("dev-tree/picky-handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: devOverride, withIntermediateDirectories: true)
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: devOverride)

        var logs: [String] = []
        PickyExtensionInstaller.installExtension(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        #expect(dest == devOverride.path)
        #expect(logs.contains(where: { $0.contains("already symlinked") }))
    }

    @Test func installLeavesRealDirectoryAndWarns() throws {
        let scratch = try Scratch()
        _ = try scratch.makeBundledExtension(named: "picky-handoff")
        let target = scratch.targetURL(for: "picky-handoff")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("custom.txt")
        try Data("hand-rolled".utf8).write(to: marker)

        var logs: [String] = []
        PickyExtensionInstaller.installExtension(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(logs.contains(where: { $0.contains("already exists and is not a Picky-managed symlink") }))
    }

    @Test func installSkipsSilentlyWhenBundledExtensionMissing() throws {
        let scratch = try Scratch()
        // Intentionally do not create the bundled extension.

        var logs: [String] = []
        PickyExtensionInstaller.installExtension(
            named: "picky-handoff",
            bundleResourceURL: scratch.bundleResources,
            homeURL: scratch.home,
            log: { logs.append($0) }
        )

        let target = scratch.targetURL(for: "picky-handoff")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(logs.contains(where: { $0.contains("not found in Resources") }))
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
