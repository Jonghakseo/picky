//
//  PickyExtensionInstaller.swift
//  Picky
//
//  Bridges the extensions Picky bundles in `Contents/Resources/pi-extensions/`
//  into the user's global Pi extensions directory (`~/.pi/agent/extensions/`)
//  by way of a symlink, so any subsequent Pi session can load them without the
//  user manually wiring anything.
//
//  Conflict policy is conservative: never overwrite an existing entry. If the
//  target path is already a symlink to a different location (e.g. a
//  developer's source-tree symlink) or a real file/directory, leave it alone
//  and emit a warning. Uninstalling Picky leaves the symlink behind on
//  purpose; cleanup is out of scope.
//

import Foundation

enum PickyExtensionInstaller {
    /// The single extension Picky ships today. Kept as an explicit allow-list
    /// instead of an autoscan so adding future extensions is a deliberate code
    /// change rather than a side-effect of dropping a folder into Resources.
    private static let bundledExtensions: [String] = ["picky-handoff"]

    static func install() {
        for name in bundledExtensions {
            installExtension(named: name)
        }
    }

    static func installExtension(
        named name: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        log: (String) -> Void = { print($0) }
    ) {
        guard let bundleResourceURL else {
            log("🧩 Picky: No bundle resource URL; skipping pi-extension auto-install.")
            return
        }
        let source = bundleResourceURL
            .appendingPathComponent("pi-extensions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else {
            log("🧩 Picky: Bundled pi-extension '\(name)' not found in Resources; skipping (dev build).")
            return
        }
        let target = homeURL
            .appendingPathComponent(".pi/agent/extensions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log("⚠️ Picky: Failed to ensure \(target.deletingLastPathComponent().path): \(error.localizedDescription)")
            return
        }
        switch existingState(at: target, expectedDestination: source, fileManager: fileManager) {
        case .missing:
            do {
                try fileManager.createSymbolicLink(at: target, withDestinationURL: source)
                log("🧩 Picky: Linked pi-extension '\(name)' -> \(source.path)")
            } catch {
                log("⚠️ Picky: Failed to link pi-extension '\(name)': \(error.localizedDescription)")
            }
        case .symlinkMatching:
            break
        case .symlinkOther(let destination):
            log("⚠️ Picky: \(target.path) already symlinked to \(destination); leaving existing override in place.")
        case .otherFile:
            log("⚠️ Picky: \(target.path) already exists and is not a Picky-managed symlink; leaving as-is.")
        }
    }

    enum ExistingState: Equatable {
        case missing
        case symlinkMatching
        case symlinkOther(destination: String)
        case otherFile
    }

    static func existingState(
        at target: URL,
        expectedDestination: URL,
        fileManager: FileManager = .default
    ) -> ExistingState {
        // `attributesOfItem(atPath:)` does not follow symlinks, which is the
        // behavior we need to distinguish a symlink (correct or wrong) from a
        // real file/directory. A missing entry — including a dangling symlink
        // — surfaces as a thrown error.
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path),
              let type = attributes[.type] as? FileAttributeType else {
            return .missing
        }
        guard type == .typeSymbolicLink else {
            return .otherFile
        }
        guard let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: target.path) else {
            return .symlinkOther(destination: "<unreadable>")
        }
        let resolved = resolveSymlinkDestination(rawDestination, relativeTo: target)
        let expected = (expectedDestination.path as NSString).standardizingPath
        if resolved == expected {
            return .symlinkMatching
        }
        return .symlinkOther(destination: rawDestination)
    }

    private static func resolveSymlinkDestination(_ destination: String, relativeTo target: URL) -> String {
        if destination.hasPrefix("/") {
            return (destination as NSString).standardizingPath
        }
        let parent = target.deletingLastPathComponent().path
        let joined = (parent as NSString).appendingPathComponent(destination)
        return (joined as NSString).standardizingPath
    }
}
