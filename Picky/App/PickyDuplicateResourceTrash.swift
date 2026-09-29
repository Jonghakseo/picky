//
//  PickyDuplicateResourceTrash.swift
//  Picky
//
//  Moves a duplicate Pi skill or extension that agentd marked as removable to
//  the user's Trash. agentd only offers paths that sit directly under a Pi
//  resource root; this re-checks that shape so a malformed event cannot send
//  an arbitrary directory, such as the root itself or the home folder, away.
//

import Foundation

enum PickyDuplicateResourceTrash {
    enum TrashError: LocalizedError, Equatable {
        case notAResourceEntry(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .notAResourceEntry(let path):
                return "Refusing to move \(path) because it is not a skill or extension entry."
            case .missing(let path):
                return "\(path) no longer exists."
            }
        }
    }

    /// Pi resource roots are always named `skills` or `extensions`.
    static let resourceRootNames: Set<String> = ["skills", "extensions"]

    static func validate(_ url: URL, fileManager: FileManager = .default) throws {
        let path = url.path
        let standardized = url.standardizedFileURL
        guard url.isFileURL, path.hasPrefix("/"), standardized.path == path,
              resourceRootNames.contains(standardized.deletingLastPathComponent().lastPathComponent),
              !resourceRootNames.contains(standardized.lastPathComponent) else {
            throw TrashError.notAResourceEntry(path)
        }
        guard fileManager.fileExists(atPath: path) else {
            throw TrashError.missing(path)
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try validate(url)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
