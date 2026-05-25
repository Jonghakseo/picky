//
//  PickyCuratedPluginInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyCuratedPluginInstallerTests {
    private let source = "npm:@ryan_nookpi/pi-extension-diff-review"

    @Test func statusReportsNotInstalledWhenSettingsAreMissing() throws {
        let scratch = try ScratchCuratedPlugin()

        let status = PickyCuratedPluginInstaller.status(source: source, homeURL: scratch.home)

        #expect(status == .notInstalled)
    }

    @Test func statusReportsInstalledWhenSourceIsInSettingsPackages() throws {
        let scratch = try ScratchCuratedPlugin()
        try scratch.writeSettings(packages: ["npm:@example/other", source])

        let status = PickyCuratedPluginInstaller.status(source: source, homeURL: scratch.home)

        #expect(status == .installed)
    }

    @Test func installRunsPiInstallForSource() throws {
        let scratch = try ScratchCuratedPlugin()
        var receivedArguments: [[String]] = []

        let result = PickyCuratedPluginInstaller.install(
            source: source,
            homeURL: scratch.home,
            commandRunner: { arguments, _, _ in
                receivedArguments.append(arguments)
                return PickyCuratedPluginInstaller.CommandResult(exitCode: 0, output: "installed")
            }
        )

        #expect(receivedArguments == [["install", source]])
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func removeRunsPiRemoveForSource() throws {
        let scratch = try ScratchCuratedPlugin()
        var receivedArguments: [[String]] = []

        let result = PickyCuratedPluginInstaller.remove(
            source: source,
            homeURL: scratch.home,
            commandRunner: { arguments, _, _ in
                receivedArguments.append(arguments)
                return PickyCuratedPluginInstaller.CommandResult(exitCode: 0, output: "removed")
            }
        )

        #expect(receivedArguments == [["remove", source]])
        #expect(throws: Never.self) { try result.get() }
    }

    @Test func commandFailureSurfacesExitCodeAndOutput() throws {
        let scratch = try ScratchCuratedPlugin()

        let result = PickyCuratedPluginInstaller.install(
            source: source,
            homeURL: scratch.home,
            commandRunner: { _, _, _ in
                PickyCuratedPluginInstaller.CommandResult(exitCode: 2, output: "network failed")
            }
        )

        if case .failure(.failed(let command, let exitCode, let output)) = result {
            #expect(command == "install")
            #expect(exitCode == 2)
            #expect(output == "network failed")
        } else {
            Issue.record("expected command failure but got \(result)")
        }
    }
}

private struct ScratchCuratedPlugin {
    let tmp: URL
    let home: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("picky-curated-plugin-\(UUID().uuidString)", isDirectory: true)
        self.tmp = base
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func writeSettings(packages: [String]) throws {
        let settingsURL = home.appendingPathComponent(".pi/agent/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["packages": packages],
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: settingsURL)
    }
}
