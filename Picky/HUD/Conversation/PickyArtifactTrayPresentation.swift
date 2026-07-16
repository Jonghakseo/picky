//
//  PickyArtifactTrayPresentation.swift
//  Picky
//
//  Presentation and action policy for session artifact tray rows.
//

import Foundation

struct PickyArtifactTrayPresentation: Equatable, Identifiable {
    enum PrimaryAction: Equatable {
        case openURL(URL)
        case revealPath(URL)
        case missingPath
        case unavailable
    }

    let id: String
    let title: String
    let subtitle: String
    let copyValue: String?
    let action: PrimaryAction

    init(
        artifact: PickyArtifact,
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        id = artifact.id
        title = Self.title(for: artifact)
        subtitle = Self.subtitle(for: artifact, homeURL: homeURL)
        copyValue = artifact.url?.absoluteString ?? artifact.path
        action = Self.primaryAction(for: artifact, fileManager: fileManager, homeURL: homeURL)
    }

    static func trayCount(for artifacts: [PickyArtifact]) -> Int {
        artifacts.count
    }

    static func title(for artifact: PickyArtifact) -> String {
        let title = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? artifact.kind : title
    }

    static func subtitle(for artifact: PickyArtifact, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let url = artifact.url {
            return url.host?.lowercased() ?? url.absoluteString
        }
        if let path = artifact.path {
            return abbreviatedPath(path, homeURL: homeURL)
        }
        return artifact.kind
    }

    static func primaryAction(
        for artifact: PickyArtifact,
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PrimaryAction {
        if let url = artifact.url {
            return .openURL(url)
        }
        guard let path = artifact.path, let localURL = localFileURL(path, homeURL: homeURL) else {
            return .unavailable
        }
        return fileManager.fileExists(atPath: localURL.path) ? .revealPath(localURL) : .missingPath
    }

    static func abbreviatedPath(_ path: String, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard let url = localFileURL(path, homeURL: homeURL) else {
            return path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let homePath = homeURL.standardizedFileURL.path
        let standardizedPath = url.path
        if standardizedPath == homePath { return "~" }
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return standardizedPath
    }

    private static func localFileURL(_ rawPath: String, homeURL: URL) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let expandedPath: String
        if path == "~" {
            expandedPath = homeURL.path
        } else if path.hasPrefix("~/") {
            expandedPath = homeURL.path + String(path.dropFirst())
        } else {
            expandedPath = path
        }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }
}
