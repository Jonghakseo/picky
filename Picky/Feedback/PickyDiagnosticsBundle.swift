//
//  PickyDiagnosticsBundle.swift
//  Picky
//
//  Stages the diagnostics files the user opted into, zips them up via
//  `NSFileCoordinator(readingItemAt:options:.forUploading)`, and hands the
//  resulting zip to the feedback sender. Uses Foundation's built-in zip
//  pathway so we avoid pulling in a third-party archive dependency.
//

import Foundation

enum PickyDiagnosticsBundleScope {
    case logsOnly
    case full

    var fileSlug: String {
        switch self {
        case .logsOnly: "logs"
        case .full: "full"
        }
    }

    var displayName: String {
        switch self {
        case .logsOnly: "Logs only"
        case .full: "Full bundle"
        }
    }
}

struct PickyDiagnosticsBundle {
    let zipURL: URL
    let filename: String
}

struct PickyDiagnosticsBundleMetadata {
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var runtimeMode: String
    var generatedAt: Date

    func renderText(scope: PickyDiagnosticsBundleScope, maxLogBytes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return [
            "Picky version:      \(appVersion) (build \(appBuild))",
            "macOS:              \(osVersion)",
            "Runtime mode:       \(runtimeMode)",
            "Diagnostics scope:  \(scope.displayName)",
            "Log tail limit:     \(maxLogBytes) bytes for included stderr tail",
            "Privacy:           User chat, tool arguments, and tool results are excluded",
            "Generated at:       \(formatter.string(from: generatedAt))"
        ].joined(separator: "\n")
    }
}

enum PickyDiagnosticsBundleError: Error, Equatable {
    case stagingFailed(String)
    case zipFailed(String)
}

enum PickyDiagnosticsBundleBuilder {
    /// Keep diagnostics uploads small enough for Slack and quick enough for
    /// testers. The agentd stdout log is never attached because it can contain
    /// user chat, prompts, tool arguments, and tool results; only a tool-name
    /// lifecycle summary is derived from it locally.
    static let defaultMaxLogBytes = 1_000_000

    /// Builds a zip in a unique temp directory and returns its URL. Caller is
    /// responsible for deleting `zipURL` and its parent directory after upload.
    static func build(
        scope: PickyDiagnosticsBundleScope,
        metadata: PickyDiagnosticsBundleMetadata,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        fileManager: FileManager = .default,
        maxLogBytes: Int = defaultMaxLogBytes,
        oslogProvider: () -> String = { PickyOSLogCollector.collectCurrentProcess() }
    ) throws -> PickyDiagnosticsBundle {
        let timestamp = filenameTimestamp(from: metadata.generatedAt)
        let bundleName = "picky-diagnostics-\(scope.fileSlug)-\(timestamp)"
        let workRoot = fileManager.temporaryDirectory
            .appendingPathComponent("picky-feedback-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = workRoot.appendingPathComponent(bundleName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            throw PickyDiagnosticsBundleError.stagingFailed(error.localizedDescription)
        }

        try stageAlwaysOnFiles(
            stagingRoot: stagingRoot,
            metadata: metadata,
            scope: scope,
            appSupportRoot: appSupportRoot,
            fileManager: fileManager,
            maxLogBytes: maxLogBytes,
            oslogProvider: oslogProvider
        )

        if scope == .full {
            stageSanitizedSettings(
                stagingRoot: stagingRoot,
                appSupportRoot: appSupportRoot,
                fileManager: fileManager
            )
        }

        let zipURL = workRoot.appendingPathComponent("\(bundleName).zip")
        try zipDirectory(at: stagingRoot, to: zipURL)
        return PickyDiagnosticsBundle(zipURL: zipURL, filename: zipURL.lastPathComponent)
    }

    // MARK: - Staging

    private static func stageAlwaysOnFiles(
        stagingRoot: URL,
        metadata: PickyDiagnosticsBundleMetadata,
        scope: PickyDiagnosticsBundleScope,
        appSupportRoot: URL,
        fileManager: FileManager,
        maxLogBytes: Int,
        oslogProvider: () -> String
    ) throws {
        let logsDir = appSupportRoot.appendingPathComponent("Logs", isDirectory: true)
        // Always stage the agentd stderr tail — even if the source file is
        // missing or empty, write an explicit placeholder so the bundle
        // discloses *why* the file is absent (daemon never launched, never
        // wrote to stderr, etc.) instead of silently dropping the entry.
        copyTailOrPlaceholder(
            from: logsDir.appendingPathComponent("agentd.stderr.log"),
            to: stagingRoot.appendingPathComponent("agentd.stderr.tail.log"),
            maxBytes: maxLogBytes,
            fileManager: fileManager
        )
        // Stage the daemon's last-known status snapshot. This is the only
        // file in the bundle that survives Picky crashes, so it is critical
        // for answering "was the daemon even alive when the user reported
        // this?". Falls back to a placeholder when the launcher never had a
        // chance to write one.
        copyOrPlaceholder(
            from: logsDir.appendingPathComponent("agentd.status.json"),
            to: stagingRoot.appendingPathComponent("agentd.status.json"),
            fileManager: fileManager
        )
        let toolEventsPath = stagingRoot.appendingPathComponent("agentd.tool-events.txt")
        let toolEvents = PickyAgentdToolEventSummarizer.summarize(
            from: logsDir.appendingPathComponent("agentd.stdout.log"),
            fileManager: fileManager
        )
        try? toolEvents.write(to: toolEventsPath, atomically: true, encoding: .utf8)

        let oslogPath = stagingRoot.appendingPathComponent("picky-oslog.txt")
        let oslogText = oslogProvider()
        do {
            try oslogText.write(to: oslogPath, atomically: true, encoding: .utf8)
        } catch {
            try? "(failed to write oslog: \(error.localizedDescription))".write(
                to: oslogPath, atomically: true, encoding: .utf8
            )
        }

        let metadataPath = stagingRoot.appendingPathComponent("metadata.txt")
        do {
            try metadata.renderText(scope: scope, maxLogBytes: maxLogBytes).write(to: metadataPath, atomically: true, encoding: .utf8)
        } catch {
            throw PickyDiagnosticsBundleError.stagingFailed("metadata: \(error.localizedDescription)")
        }
    }

    private static func stageSanitizedSettings(
        stagingRoot: URL,
        appSupportRoot: URL,
        fileManager: FileManager
    ) {
        let settingsURL = appSupportRoot
            .appendingPathComponent("Settings", isDirectory: true)
            .appendingPathComponent("settings.json")
        let destinationURL = stagingRoot.appendingPathComponent("settings.sanitized.json")

        guard fileManager.fileExists(atPath: settingsURL.path) else {
            try? "(settings.json not present)".write(to: destinationURL, atomically: true, encoding: .utf8)
            return
        }
        do {
            let sanitized = try PickySettingsSanitizer.sanitizedJSONData(from: settingsURL)
            try sanitized.write(to: destinationURL, options: .atomic)
        } catch {
            try? "(failed to sanitize settings: \(error.localizedDescription))".write(
                to: destinationURL, atomically: true, encoding: .utf8
            )
        }
    }

    /// Like `copyTailIfExists` but always writes the destination. When the
    /// source is missing or empty we leave an explicit placeholder so the
    /// diagnostics reader can distinguish "file absent" from "file truly
    /// empty" from "we forgot to attach it".
    private static func copyTailOrPlaceholder(
        from sourceURL: URL,
        to destinationURL: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) {
        if !fileManager.fileExists(atPath: sourceURL.path) {
            try? "(absent at \(sourceURL.path) when diagnostics bundle was built — daemon may not have launched or may not have written to this stream)"
                .write(to: destinationURL, atomically: true, encoding: .utf8)
            return
        }
        let attributesSizeProbe = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size]) as? UInt64 ?? 0
        if attributesSizeProbe == 0 {
            try? "(present but empty at \(sourceURL.path))"
                .write(to: destinationURL, atomically: true, encoding: .utf8)
            return
        }
        copyTailIfExists(
            from: sourceURL,
            to: destinationURL,
            maxBytes: maxBytes,
            fileManager: fileManager
        )
    }

    /// Copies the full source file when present, or writes a placeholder note
    /// describing its absence. Used for the daemon status snapshot, which is
    /// small enough not to need tail trimming. The copy is run through
    /// `PickyDiagnosticTextRedactor` so any user paths or token-looking
    /// values that may have leaked into the launcher's `detail` field are
    /// masked the same way they are inside `picky-oslog.txt`.
    private static func copyOrPlaceholder(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) {
        if !fileManager.fileExists(atPath: sourceURL.path) {
            try? "(absent at \(sourceURL.path) — launcher has not written a status snapshot yet, suggesting agentd never reached a known lifecycle state in this Picky session)"
                .write(to: destinationURL, atomically: true, encoding: .utf8)
            return
        }
        do {
            let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
            let redactedText = PickyDiagnosticTextRedactor.redact(sourceText)
            try redactedText.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            try? "(failed to stage \(sourceURL.lastPathComponent): \(error.localizedDescription))"
                .write(to: destinationURL, atomically: true, encoding: .utf8)
        }
    }

    private static func copyTailIfExists(
        from sourceURL: URL,
        to destinationURL: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            let cappedMaxBytes = UInt64(max(1, maxBytes))
            let bytesToRead = min(fileSize, cappedMaxBytes)

            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            if fileSize > bytesToRead {
                try handle.seek(toOffset: fileSize - bytesToRead)
            }
            let tailData = try handle.readToEnd() ?? Data()
            let redactedTailData = PickyDiagnosticTextRedactor.redact(tailData)
            let header = "# Tail of \(sourceURL.lastPathComponent): last \(tailData.count) bytes of \(fileSize) bytes; sensitive token-shaped values redacted\n"
            var output = Data(header.utf8)
            output.append(redactedTailData)
            try output.write(to: destinationURL, options: .atomic)
        } catch {
            try? "(failed to copy tail of \(sourceURL.lastPathComponent): \(error.localizedDescription))".write(
                to: destinationURL, atomically: true, encoding: .utf8
            )
        }
    }

    // MARK: - Zip

    /// Uses NSFileCoordinator's `.forUploading` option, which is Foundation's
    /// supported way to produce a zip of a directory. The coordinator hands us
    /// a temporary zip URL inside its closure and deletes it afterwards, so we
    /// immediately copy it to our own location.
    private static func zipDirectory(at directoryURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var captured: Error?

        coordinator.coordinate(
            readingItemAt: directoryURL,
            options: [.forUploading],
            error: &coordinatorError
        ) { temporaryZipURL in
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: temporaryZipURL, to: destinationURL)
            } catch {
                captured = error
            }
        }

        if let coordinatorError {
            throw PickyDiagnosticsBundleError.zipFailed(coordinatorError.localizedDescription)
        }
        if let captured {
            throw PickyDiagnosticsBundleError.zipFailed(captured.localizedDescription)
        }
    }

    private static func filenameTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
