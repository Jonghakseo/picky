//
//  PickyPiSettingsReaderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyPiSettingsReaderTests {
    @Test func setHideThinkingBlockCreatesSettingsFileAndPreservesExistingKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"theme":"dark"}"#.utf8).write(to: settingsURL)

        try PickyPiSettingsReader.setHideThinkingBlock(true, in: settingsURL)

        #expect(PickyPiSettingsReader.hideThinkingBlock(in: settingsURL) == true)
        let data = try Data(contentsOf: settingsURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["theme"] as? String == "dark")
        #expect(object["hideThinkingBlock"] as? Bool == true)
    }

    @Test func settingsURLForWritingPrefersExistingProjectSettings() throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectPiDirectory = cwd.appendingPathComponent(".pi", isDirectory: true)
        let projectSettingsURL = projectPiDirectory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: projectPiDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projectSettingsURL)
        defer { try? FileManager.default.removeItem(at: cwd) }

        #expect(PickyPiSettingsReader.settingsURLForWriting(cwd: cwd.path) == projectSettingsURL)
    }
}
