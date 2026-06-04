//
//  PickySkillInstaller.swift
//  Picky
//
//  Bridges the skills Picky bundles in `Contents/Resources/pi-skills/` into
//  the user's global Pi skills directory (`PI_CODING_AGENT_DIR/skills`, auto-discovered
//  with a legacy `~/.pi/agent/skills` fallback). Like bundled
//  extensions, installs are opt-in and protected by a small metadata file so
//  Picky only updates/removes copies it owns.
//

import CryptoKit
import Foundation

enum PickySkillInstaller {
    /// The bundled skills Picky can install into the user's Pi skill catalog.
    static let bundledSkills: [String] = ["picky-cli"]

    /// Filename written inside an installed skill directory to mark it as a
    /// Picky-managed copy and record which bundle version produced it.
    fileprivate static let metadataFilename = ".picky-skill-install.json"

    /// Sentinel string in the metadata's `managedBy` field. Used to refuse
    /// uninstalling user-owned skill directories that happen to share the name.
    fileprivate static let managedByMarker = "picky"

    enum Status: Equatable {
        case bundleMissing
        case notInstalled
        case installed
        case outdated
        case legacySymlink
        case developerOverride(target: String)
        case conflict(reason: String)
    }

    enum InstallError: LocalizedError {
        case bundleMissing(name: String)
        case conflict(name: String, reason: String)
        case ioFailure(name: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .bundleMissing(let name):
                return "Bundled pi-skill '\(name)' is not present in this Picky build."
            case .conflict(let name, let reason):
                return "Cannot install '\(name)': \(reason)"
            case .ioFailure(let name, let underlying):
                return "Failed to install '\(name)': \(underlying.localizedDescription)"
            }
        }
    }

    enum UninstallError: LocalizedError {
        case notInstalled(name: String)
        case notManaged(name: String, reason: String)
        case ioFailure(name: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name):
                return "'\(name)' is not currently installed."
            case .notManaged(let name, let reason):
                return "Refusing to remove '\(name)': \(reason)"
            case .ioFailure(let name, let underlying):
                return "Failed to remove '\(name)': \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - Public API

    static func status(
        named name: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Status {
        guard let source = bundledSource(named: name, bundleResourceURL: bundleResourceURL, fileManager: fileManager) else {
            return .bundleMissing
        }
        let target = targetURL(for: name, homeURL: homeURL)
        let bundleFingerprint = fingerprint(of: source, fileManager: fileManager)
        return classify(
            target: target,
            source: source,
            bundleFingerprint: bundleFingerprint,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func install(
        named name: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        appBuildLabel: String = AppBundleConfiguration.buildLabel ?? "",
        log: (String) -> Void = { print($0) }
    ) -> Result<Void, InstallError> {
        guard let source = bundledSource(named: name, bundleResourceURL: bundleResourceURL, fileManager: fileManager) else {
            log("🧩 Picky: Bundled pi-skill '\(name)' not found in Resources; cannot install (dev build).")
            return .failure(.bundleMissing(name: name))
        }
        let target = targetURL(for: name, homeURL: homeURL)
        guard let bundleFingerprint = fingerprint(of: source, fileManager: fileManager) else {
            return .failure(.ioFailure(name: name, underlying: NSError(
                domain: "PickySkillInstaller",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to read bundled skill at \(source.path)"]
            )))
        }
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log("⚠️ Picky: Failed to ensure \(target.deletingLastPathComponent().path): \(error.localizedDescription)")
            return .failure(.ioFailure(name: name, underlying: error))
        }

        let currentStatus = classify(
            target: target,
            source: source,
            bundleFingerprint: bundleFingerprint,
            fileManager: fileManager
        )
        switch currentStatus {
        case .installed:
            return .success(())
        case .notInstalled, .outdated, .legacySymlink:
            return atomicInstall(
                source: source,
                target: target,
                bundleFingerprint: bundleFingerprint,
                appBuildLabel: appBuildLabel,
                fileManager: fileManager,
                name: name,
                log: log
            )
        case .developerOverride(let dest):
            let reason = "Symlink already points to \(dest); leaving developer override in place."
            log("⚠️ Picky: \(reason)")
            return .failure(.conflict(name: name, reason: reason))
        case .conflict(let reason):
            log("⚠️ Picky: \(reason); leaving as-is.")
            return .failure(.conflict(name: name, reason: reason))
        case .bundleMissing:
            return .failure(.bundleMissing(name: name))
        }
    }

    @discardableResult
    static func uninstall(
        named name: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        log: (String) -> Void = { print($0) }
    ) -> Result<Void, UninstallError> {
        let target = targetURL(for: name, homeURL: homeURL)
        let source = bundledSource(named: name, bundleResourceURL: bundleResourceURL, fileManager: fileManager)
        let bundleFingerprint = source.flatMap { fingerprint(of: $0, fileManager: fileManager) }

        let currentStatus = classify(
            target: target,
            source: source,
            bundleFingerprint: bundleFingerprint,
            fileManager: fileManager
        )
        switch currentStatus {
        case .installed, .outdated, .legacySymlink:
            do {
                try fileManager.removeItem(at: target)
                log("🧩 Picky: Removed pi-skill '\(name)' at \(target.path)")
                return .success(())
            } catch {
                log("⚠️ Picky: Failed to remove pi-skill '\(name)': \(error.localizedDescription)")
                return .failure(.ioFailure(name: name, underlying: error))
            }
        case .notInstalled, .bundleMissing:
            return .failure(.notInstalled(name: name))
        case .developerOverride(let dest):
            return .failure(.notManaged(name: name, reason: "Symlink points to \(dest); not a Picky-managed install."))
        case .conflict(let reason):
            return .failure(.notManaged(name: name, reason: reason))
        }
    }

    // MARK: - Classification

    fileprivate static func classify(
        target: URL,
        source: URL?,
        bundleFingerprint: String?,
        fileManager: FileManager
    ) -> Status {
        if let raw = try? fileManager.destinationOfSymbolicLink(atPath: target.path) {
            let resolved = resolveSymlinkDestination(raw, relativeTo: target)
            if let source, resolved == (source.path as NSString).standardizingPath {
                return .legacySymlink
            }
            if fileManager.fileExists(atPath: resolved) {
                return .developerOverride(target: raw)
            }
            return .conflict(reason: "Dangling symlink to \(raw).")
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path),
              let type = attributes[.type] as? FileAttributeType else {
            return .notInstalled
        }
        switch type {
        case .typeDirectory:
            let metadataURL = target.appendingPathComponent(metadataFilename)
            guard let installedFingerprint = readMetadataFingerprint(at: metadataURL) else {
                return .conflict(reason: "Custom directory at \(target.path).")
            }
            if let bundleFingerprint, installedFingerprint == bundleFingerprint {
                return .installed
            }
            return .outdated
        default:
            return .conflict(reason: "Non-directory file at \(target.path).")
        }
    }

    // MARK: - Atomic install

    private static func atomicInstall(
        source: URL,
        target: URL,
        bundleFingerprint: String,
        appBuildLabel: String,
        fileManager: FileManager,
        name: String,
        log: (String) -> Void
    ) -> Result<Void, InstallError> {
        let parent = target.deletingLastPathComponent()
        let stagingName = ".\(target.lastPathComponent).installing-\(UUID().uuidString)"
        let staging = parent.appendingPathComponent(stagingName, isDirectory: true)

        do {
            try fileManager.copyItem(at: source, to: staging)
        } catch {
            log("⚠️ Picky: Failed to stage pi-skill '\(name)': \(error.localizedDescription)")
            return .failure(.ioFailure(name: name, underlying: error))
        }

        let metadata: [String: Any] = [
            "managedBy": managedByMarker,
            "fingerprint": bundleFingerprint,
            "installedAt": Self.iso8601Formatter.string(from: Date()),
            "appBuildLabel": appBuildLabel
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys, .prettyPrinted]
            )
            try data.write(to: staging.appendingPathComponent(metadataFilename))
        } catch {
            try? fileManager.removeItem(at: staging)
            log("⚠️ Picky: Failed to write install metadata for '\(name)': \(error.localizedDescription)")
            return .failure(.ioFailure(name: name, underlying: error))
        }

        try? fileManager.removeItem(at: target)

        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            log("⚠️ Picky: Failed to move pi-skill '\(name)' into place: \(error.localizedDescription)")
            return .failure(.ioFailure(name: name, underlying: error))
        }

        log("🧩 Picky: Installed pi-skill '\(name)' at \(target.path)")
        return .success(())
    }

    // MARK: - Fingerprint

    fileprivate static func fingerprint(of root: URL, fileManager: FileManager) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return nil
        }
        let rootPath = (root.path as NSString).standardizingPath
        var entries: [(relPath: String, data: Data)] = []
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
            if url.lastPathComponent == metadataFilename { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let resolved = (url.path as NSString).standardizingPath
            let relPath: String
            if resolved.hasPrefix(rootPath + "/") {
                relPath = String(resolved.dropFirst(rootPath.count + 1))
            } else {
                relPath = resolved
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            entries.append((relPath, data))
        }
        entries.sort { $0.relPath < $1.relPath }
        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data(entry.relPath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: entry.data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readMetadataFingerprint(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let managed = json["managedBy"] as? String, managed == managedByMarker,
              let fp = json["fingerprint"] as? String, !fp.isEmpty else {
            return nil
        }
        return fp
    }

    // MARK: - Path helpers

    fileprivate static func bundledSource(
        named name: String,
        bundleResourceURL: URL?,
        fileManager: FileManager
    ) -> URL? {
        guard let bundleResourceURL else { return nil }
        let source = bundleResourceURL
            .appendingPathComponent("pi-skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let skillFile = source.appendingPathComponent("SKILL.md", isDirectory: false)
        return fileManager.fileExists(atPath: skillFile.path) ? source : nil
    }

    fileprivate static func targetURL(for name: String, homeURL: URL) -> URL {
        let preferences: PickyPiInstallationPreferences = homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path
            ? PickyPiInstallation.preferences(from: PickySettingsStore().load())
            : .init()
        return PickyPiInstallation.resolve(preferences: preferences, homeURL: homeURL)
            .codingAgentDirURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static func resolveSymlinkDestination(_ destination: String, relativeTo target: URL) -> String {
        if destination.hasPrefix("/") {
            return (destination as NSString).standardizingPath
        }
        let parent = target.deletingLastPathComponent().path
        let joined = (parent as NSString).appendingPathComponent(destination)
        return (joined as NSString).standardizingPath
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
