//
//  PickySettings.swift
//  Picky
//
//  Lightweight persisted settings for the local-first MVP.
//

import Combine
import Foundation
import SwiftUI

struct PickySettings: Codable, Equatable {
    var defaultCwd: String
    var worktreeParent: String
    var preferredToolVisibility: String
    var readOnlyInvestigationPreference: Bool
    var daemonPath: String
    var logPath: String

    static func defaults(appSupportRoot: URL = PickyAppSupport.defaultRoot()) -> PickySettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PickySettings(
            defaultCwd: home,
            worktreeParent: home,
            preferredToolVisibility: "visible in context only",
            readOnlyInvestigationPreference: true,
            daemonPath: "bundled picky-agentd or local development agentd",
            logPath: appSupportRoot.appendingPathComponent("Logs", isDirectory: true).path
        )
    }
}

enum PickySettingsValidationError: LocalizedError, Equatable {
    case invalidDefaultCwd(String)
    case invalidWorktreeParent(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefaultCwd(let path): "Default cwd does not exist or is not a directory: \(path)"
        case .invalidWorktreeParent(let path): "Worktree parent does not exist or is not a directory: \(path)"
        }
    }
}

struct PickySettingsStore {
    let url: URL
    var fileManager: FileManager = .default

    init(appSupportRoot: URL = PickyAppSupport.defaultRoot(), fileManager: FileManager = .default) {
        self.url = appSupportRoot.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        self.fileManager = fileManager
    }

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() -> PickySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(PickySettings.self, from: data) else {
            return .defaults(appSupportRoot: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        return settings
    }

    func save(_ settings: PickySettings) throws {
        try validate(settings)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyPickySettings.encode(settings)
        try data.write(to: url, options: .atomic)
    }

    func validate(_ settings: PickySettings) throws {
        try validateDirectory(settings.defaultCwd, error: .invalidDefaultCwd(settings.defaultCwd))
        if !settings.worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateDirectory(settings.worktreeParent, error: .invalidWorktreeParent(settings.worktreeParent))
        }
    }

    private func validateDirectory(_ path: String, error: PickySettingsValidationError) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: NSString(string: path).expandingTildeInPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error
        }
    }
}

private extension JSONEncoder {
    static var prettyPickySettings: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@MainActor
final class PickySettingsViewModel: ObservableObject {
    @Published var settings: PickySettings
    @Published private(set) var validationError: String?

    private let store: PickySettingsStore

    init(store: PickySettingsStore = PickySettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    func save() -> Bool {
        do {
            try store.save(settings)
            validationError = nil
            return true
        } catch {
            validationError = error.localizedDescription
            return false
        }
    }
}

struct PickySettingsView: View {
    @ObservedObject var viewModel: PickySettingsViewModel

    var body: some View {
        Form {
            TextField("Default cwd", text: $viewModel.settings.defaultCwd)
            TextField("Worktree parent", text: $viewModel.settings.worktreeParent)
            TextField("Preferred tool visibility", text: $viewModel.settings.preferredToolVisibility)
            Toggle("Prefer read-only investigation context", isOn: $viewModel.settings.readOnlyInvestigationPreference)
            LabeledContent("Daemon", value: viewModel.settings.daemonPath)
            LabeledContent("Logs", value: viewModel.settings.logPath)
            if let error = viewModel.validationError {
                Text(error).foregroundColor(.red)
            }
            Button("Save") { _ = viewModel.save() }
        }
        .padding()
        .frame(width: 460)
    }
}
