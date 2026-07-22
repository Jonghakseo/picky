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

enum PickyDiagnosticsBundleScope: Sendable {
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
    var generatedAt: Date

    func renderText(scope: PickyDiagnosticsBundleScope, maxLogBytes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        return [
            "Picky version:      \(appVersion) (build \(appBuild))",
            "macOS:              \(osVersion)",
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

enum PickyPortOccupancyCollector {
    private static let probeTimeout: TimeInterval = 1.0

    static func collect(ports: [Int]) -> String {
        let uniquePorts = Array(Set(ports)).sorted()
        guard !uniquePorts.isEmpty else {
            return "No EADDRINUSE listen ports detected in the included stderr tail."
        }

        var sections: [String] = [
            "Detected EADDRINUSE listen ports in agentd stderr: \(uniquePorts.map(String.init).joined(separator: ", "))",
            "Port occupants were probed at diagnostics build time with lsof; an empty result means the conflicting process exited before feedback was sent."
        ]
        for port in uniquePorts {
            sections.append("\n# TCP listen port \(port)\n\(lsofOutput(for: port))")
        }
        return sections.joined(separator: "\n")
    }

    private static func lsofOutput(for port: Int) -> String {
        let executable = FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") ? "/usr/sbin/lsof" : "/usr/bin/lsof"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "lsof not found on this system."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                finished.signal()
            }
            if finished.wait(timeout: .now() + probeTimeout) == .timedOut {
                process.terminate()
                process.waitUntilExit()
                return "lsof timed out after \(Int(probeTimeout))s."
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? "No listener found for port \(port)." : output
        } catch {
            return "lsof failed: \(error.localizedDescription)"
        }
    }
}

/// Produces a bounded scalar-only view of lifecycle evidence from agentd stdout.
/// Raw stdout is intentionally never staged: this parser renders only predeclared
/// event names, field keys, and enum/numeric/boolean values.
enum PickyAgentdLifecycleEventSummarizer {
    private static let maxEvents = 300
    private static let allowedEvents: Set<String> = [
        "manualCompactStarted", "manualCompactFinished", "manualCompactSettled",
        "followUpRequested", "followUpTerminalRuntimeMismatch", "followUpAccepted",
        "followUpQueued", "followUpDelivered", "followUpRejected", "followUpQueueStalled",
        "queueUpdateReconciled", "runtimeInputDelivery",
        "piPromptPreflight", "piPromptPreflightRejected", "piPromptPreflightAccepted",
        "piPromptResolved", "piPromptRejected", "piPromptAccepted", "piRuntimeEvent"
    ]
    private static let allowedFieldOrder = [
        "timestamp", "event", "sessionStatus", "statusAtRequest", "terminalStatus", "isStreaming", "isCompacting",
        "runtimeActiveWhileTerminal", "queuedSteeringCount", "queuedFollowUpCount", "pendingDeliveryCount",
        "expectedInputDeliveryCount", "steeringCount", "followUpCount", "removedCount", "textChars",
        "instructionChars", "imageCount", "elapsedMs", "ageMs", "wasStreaming", "accepted",
        "promptResolved", "handledSynchronously", "source", "queueKind", "originatedBy",
        "streamingBehavior", "outcome", "piEvent"
    ]
    private static let allowedEnumValues: Set<String> = [
        "queued", "running", "waiting_for_input", "blocked", "completed", "failed", "cancelled", "none",
        "text", "voice", "voice-follow-up", "text-follow-up", "system", "cli",
        "main_agent", "user", "internal", "pi_extension",
        "steer", "steering", "followUp", "resolved", "rejected", "settled",
        "agent_start", "agent_end", "agent_settled", "compaction_start", "compaction_end", "queue_update"
    ]

    static func summarize(from sourceURL: URL, fileManager: FileManager = .default) -> String {
        guard fileManager.fileExists(atPath: sourceURL.path),
              let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return "# agentd lifecycle evidence\n# Privacy: allowlisted scalar fields only; raw stdout, identifiers, user text, prompts, paths, tool data, and errors are excluded.\n(absent — agentd stdout was not available when diagnostics were built)\n"
        }

        let rendered = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { renderAllowlistedEvent(String($0)) }
            .suffix(maxEvents)
        let header = "# agentd lifecycle evidence\n# Privacy: allowlisted scalar fields only; raw stdout, identifiers, user text, prompts, paths, tool data, and errors are excluded.\n# Events: \(rendered.count) (latest \(maxEvents) maximum)\n"
        return header + (rendered.isEmpty ? "(no allowlisted lifecycle events found)\n" : rendered.joined(separator: "\n") + "\n")
    }

    private static func renderAllowlistedEvent(_ line: String) -> String? {
        guard let marker = line.range(of: "picky-agentd lifecycle ") else { return nil }
        var fields: [String: String] = [:]
        if let timestamp = line.split(separator: " ", maxSplits: 1).first {
            fields["timestamp"] = String(timestamp)
        }
        for token in line[marker.upperBound...].split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            fields[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let event = fields["event"], allowedEvents.contains(event) else { return nil }
        return allowedFieldOrder.compactMap { key in
            guard let value = fields[key], isAllowed(value, for: key) else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: " ")
    }

    private static func isAllowed(_ value: String, for key: String) -> Bool {
        if key == "timestamp" {
            return value.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#,
                options: .regularExpression
            ) != nil
        }
        if key == "event" { return allowedEvents.contains(value) }
        if ["isStreaming", "isCompacting", "runtimeActiveWhileTerminal", "wasStreaming", "accepted", "promptResolved", "handledSynchronously"].contains(key) {
            return value == "true" || value == "false"
        }
        if ["queuedSteeringCount", "queuedFollowUpCount", "pendingDeliveryCount", "expectedInputDeliveryCount", "steeringCount", "followUpCount", "removedCount", "textChars", "instructionChars", "imageCount", "elapsedMs", "ageMs"].contains(key) {
            return !value.isEmpty && value.allSatisfy(\.isNumber)
        }
        return allowedEnumValues.contains(value)
    }
}

enum PickyDiagnosticsBundleBuilder {
    /// Keep diagnostics uploads small enough for Slack and quick enough for
    /// testers. The agentd stdout log is never attached because it can contain
    /// user chat, prompts, tool arguments, and tool results; only a tool-name
    /// lifecycle summary is derived from it locally.
    static let defaultMaxLogBytes = 1_000_000
    static let defaultMaxWatchdogSampleBytes = 120_000
    /// New crash/lifecycle evidence is bounded independently of existing
    /// stderr/watchdog limits: 256 KiB OSLog + 384 KiB IPS + 64 KiB scalar
    /// lifecycle/manifest data = 704 KiB maximum uncompressed.
    static let maximumPreviousProcessOSLogBytes = 256 * 1024
    static let maximumIPSExcerptBytes = 384 * 1024
    static let maximumLifecycleAndManifestBytes = 64 * 1024
    static let maximumLifecycleSnapshotBytes = 32 * 1024
    static let maximumIPSManifestBytes = 32 * 1024
    private static let maxWatchdogSampleFiles = 3

    /// Builds a zip in a unique temp directory and returns its URL. Caller is
    /// responsible for deleting `zipURL` and its parent directory after upload.
    static func build(
        scope: PickyDiagnosticsBundleScope,
        metadata: PickyDiagnosticsBundleMetadata,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        fileManager: FileManager = .default,
        maxLogBytes: Int = defaultMaxLogBytes,
        maxWatchdogSampleBytes: Int = defaultMaxWatchdogSampleBytes,
        oslogProvider: () -> String = { PickyOSLogCollector.collectPreviousProcess() },
        portOccupancyProvider: ([Int]) -> String = { PickyPortOccupancyCollector.collect(ports: $0) },
        ipsReportsRoot: URL? = nil,
        diagnosticsNow: Date = Date()
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
            maxWatchdogSampleBytes: maxWatchdogSampleBytes,
            oslogProvider: oslogProvider,
            portOccupancyProvider: portOccupancyProvider,
            ipsReportsRoot: ipsReportsRoot ?? PickyIPSCollector.defaultReportsRoot(fileManager: fileManager),
            diagnosticsNow: diagnosticsNow
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

    private static func stageAlwaysOnFiles(
        stagingRoot: URL,
        metadata: PickyDiagnosticsBundleMetadata,
        scope: PickyDiagnosticsBundleScope,
        appSupportRoot: URL,
        fileManager: FileManager,
        maxLogBytes: Int,
        maxWatchdogSampleBytes: Int,
        oslogProvider: () -> String,
        portOccupancyProvider: ([Int]) -> String,
        ipsReportsRoot: URL,
        diagnosticsNow: Date
    ) throws {
        let logsDir = appSupportRoot.appendingPathComponent("Logs", isDirectory: true)
        // Always stage the agentd stderr tail — even if the source file is
        // missing or empty, write an explicit placeholder so the bundle
        // discloses *why* the file is absent (daemon never launched, never
        // wrote to stderr, etc.) instead of silently dropping the entry.
        let stderrLogURL = logsDir.appendingPathComponent("agentd.stderr.log")
        copyTailOrPlaceholder(
            from: stderrLogURL,
            to: stagingRoot.appendingPathComponent("agentd.stderr.tail.log"),
            maxBytes: maxLogBytes,
            fileManager: fileManager
        )
        stagePortOccupancyDiagnostics(
            from: stderrLogURL,
            to: stagingRoot.appendingPathComponent("agentd.port-occupants.txt"),
            maxBytes: maxLogBytes,
            fileManager: fileManager,
            portOccupancyProvider: portOccupancyProvider
        )
        // Stage the daemon's last-known status snapshots. The legacy
        // `agentd.status.json` remains for compatibility, while role-specific
        // snapshots preserve primary and per-Pickle child state separately so
        // a child failure cannot overwrite the primary daemon's last state.
        stageStatusSnapshots(
            from: logsDir,
            to: stagingRoot,
            fileManager: fileManager
        )
        copyOrPlaceholder(
            from: logsDir.appendingPathComponent("agentd.node-preflight.json"),
            to: stagingRoot.appendingPathComponent("agentd.node-preflight.json"),
            fileManager: fileManager
        )
        let stdoutLogURL = logsDir.appendingPathComponent("agentd.stdout.log")
        let toolEventsPath = stagingRoot.appendingPathComponent("agentd.tool-events.txt")
        let toolEvents = PickyAgentdToolEventSummarizer.summarize(
            from: stdoutLogURL,
            fileManager: fileManager
        )
        try? toolEvents.write(to: toolEventsPath, atomically: true, encoding: .utf8)

        // Privacy-preserving session identity & title timeline derived from the
        // same stdout log. Surfaces late Pickle title flips and whether two
        // sessions share a Pi session file, which the raw bundle could not show.
        let sessionIdentityPath = stagingRoot.appendingPathComponent("agentd.session-identity.txt")
        let sessionIdentity = PickyAgentdSessionIdentitySummarizer.summarize(
            from: stdoutLogURL,
            fileManager: fileManager
        )
        try? sessionIdentity.write(to: sessionIdentityPath, atomically: true, encoding: .utf8)

        let lifecycleEventsPath = stagingRoot.appendingPathComponent("agentd.lifecycle-events.txt")
        let lifecycleEvents = PickyAgentdLifecycleEventSummarizer.summarize(
            from: stdoutLogURL,
            fileManager: fileManager
        )
        try? lifecycleEvents.write(to: lifecycleEventsPath, atomically: true, encoding: .utf8)

        let oslogPath = stagingRoot.appendingPathComponent("picky-oslog.txt")
        let oslogText = PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(oslogProvider()),
            maxBytes: maximumPreviousProcessOSLogBytes,
            keepingNewest: true
        )
        do {
            try oslogText.write(to: oslogPath, atomically: true, encoding: .utf8)
        } catch {
            try? "(failed to write oslog: \(error.localizedDescription))".write(
                to: oslogPath, atomically: true, encoding: .utf8
            )
        }

        let lifecyclePath = stagingRoot.appendingPathComponent("picky-lifecycle.json")
        let lifecycleText = PickyLifecycleDiagnosticsStore.boundedSnapshotText(
            from: logsDir,
            maxBytes: maximumLifecycleSnapshotBytes,
            fileManager: fileManager
        )
        try? lifecycleText.write(to: lifecyclePath, atomically: true, encoding: .utf8)

        let ips = PickyIPSCollector.collect(
            reportsRoot: ipsReportsRoot,
            now: diagnosticsNow,
            fileManager: fileManager
        )
        let ipsManifest = PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(ips.manifestText),
            maxBytes: maximumIPSManifestBytes,
            keepingNewest: false
        )
        try? ipsManifest.write(
            to: stagingRoot.appendingPathComponent("picky-ips-manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
        let ipsExcerpts = PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(ips.excerptsText),
            maxBytes: maximumIPSExcerptBytes,
            keepingNewest: false
        )
        try? ipsExcerpts.write(
            to: stagingRoot.appendingPathComponent("picky-ips-excerpts.txt"),
            atomically: true,
            encoding: .utf8
        )

        stageWatchdogDiagnostics(
            from: logsDir,
            to: stagingRoot,
            oslogText: oslogText,
            fileManager: fileManager,
            maxSampleBytes: maxWatchdogSampleBytes
        )

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

    private static func stageStatusSnapshots(
        from logsDir: URL,
        to stagingRoot: URL,
        fileManager: FileManager
    ) {
        let legacyName = "agentd.status.json"
        var statusURLs: [URL] = []
        if let children = try? fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
            statusURLs = children
                .filter { url in
                    let name = url.lastPathComponent
                    return name.hasPrefix("agentd.status") && name.hasSuffix(".json")
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        if !statusURLs.contains(where: { $0.lastPathComponent == legacyName }) {
            copyOrPlaceholder(
                from: logsDir.appendingPathComponent(legacyName),
                to: stagingRoot.appendingPathComponent(legacyName),
                fileManager: fileManager
            )
        }
        for sourceURL in statusURLs {
            copyOrPlaceholder(
                from: sourceURL,
                to: stagingRoot.appendingPathComponent(sourceURL.lastPathComponent),
                fileManager: fileManager
            )
        }
    }

    private static func stagePortOccupancyDiagnostics(
        from stderrLogURL: URL,
        to destinationURL: URL,
        maxBytes: Int,
        fileManager: FileManager,
        portOccupancyProvider: ([Int]) -> String
    ) {
        let stderrTail = tailTextIfExists(from: stderrLogURL, maxBytes: maxBytes, fileManager: fileManager) ?? ""
        let ports = parseEADDRINUSEPorts(from: stderrTail)
        let text: String
        if ports.isEmpty {
            text = "No EADDRINUSE listen ports detected in the included stderr tail."
        } else {
            text = portOccupancyProvider(ports)
        }
        let redacted = PickyDiagnosticTextRedactor.redact(text)
        try? redacted.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private struct WatchdogSampleEntry {
        let url: URL
        let modifiedAt: Date
        let sizeBytes: UInt64
    }

    private struct WatchdogStallSummary {
        var softStallDetectedCount = 0
        var softStallRecoveredCount = 0
        var maxSoftStallAgeMs = 0
        var maxSoftStallRecoveryAgeMs = 0
        var maxSoftStallThresholdMs = 0
    }

    private static func stageWatchdogDiagnostics(
        from logsDir: URL,
        to stagingRoot: URL,
        oslogText: String,
        fileManager: FileManager,
        maxSampleBytes: Int
    ) {
        let samples = watchdogSampleEntries(in: logsDir, fileManager: fileManager)
        let summary = renderWatchdogSummary(
            stallSummary: watchdogStallSummary(from: oslogText),
            sampleEntries: samples
        )
        try? summary.write(
            to: stagingRoot.appendingPathComponent("watchdog.summary.txt"),
            atomically: true,
            encoding: .utf8
        )

        let sampleExcerpts = renderWatchdogSampleExcerpts(
            sampleEntries: samples,
            fileManager: fileManager,
            maxSampleBytes: maxSampleBytes
        )
        try? sampleExcerpts.write(
            to: stagingRoot.appendingPathComponent("watchdog.samples.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func watchdogSampleEntries(in logsDir: URL, fileManager: FileManager) -> [WatchdogSampleEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> WatchdogSampleEntry? in
            guard url.lastPathComponent.hasPrefix("spin-"), url.pathExtension == "txt" else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            let sizeBytes = UInt64(values?.fileSize ?? 0)
            return WatchdogSampleEntry(url: url, modifiedAt: modifiedAt, sizeBytes: sizeBytes)
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
    }

    private static func renderWatchdogSummary(
        stallSummary: WatchdogStallSummary,
        sampleEntries: [WatchdogSampleEntry]
    ) -> String {
        var lines = [
            "Picky watchdog diagnostics summary",
            "Privacy: scalar counts/durations plus bounded, redacted spin sample excerpts only; user chat, tool arguments, and tool results are excluded.",
            "softStallDetectedCount=\(stallSummary.softStallDetectedCount)",
            "softStallRecoveredCount=\(stallSummary.softStallRecoveredCount)",
            "maxSoftStallAgeMs=\(stallSummary.maxSoftStallAgeMs)",
            "maxSoftStallRecoveryAgeMs=\(stallSummary.maxSoftStallRecoveryAgeMs)",
            "maxSoftStallThresholdMs=\(stallSummary.maxSoftStallThresholdMs)",
            "spinSampleFileCount=\(sampleEntries.count)",
            "includedSpinSampleFileCount=\(min(sampleEntries.count, maxWatchdogSampleFiles))"
        ]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        for (index, sample) in sampleEntries.prefix(maxWatchdogSampleFiles).enumerated() {
            lines.append("sample[\(index)].filename=\(sample.url.lastPathComponent)")
            lines.append("sample[\(index)].sizeBytes=\(sample.sizeBytes)")
            lines.append("sample[\(index)].modifiedAt=\(formatter.string(from: sample.modifiedAt))")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderWatchdogSampleExcerpts(
        sampleEntries: [WatchdogSampleEntry],
        fileManager: FileManager,
        maxSampleBytes: Int
    ) -> String {
        guard !sampleEntries.isEmpty else {
            return "No spin-*.txt watchdog sample files found in Logs."
        }
        guard maxSampleBytes > 0 else {
            return "Watchdog sample excerpt capture disabled because maxSampleBytes=0."
        }

        let included = Array(sampleEntries.prefix(maxWatchdogSampleFiles))
        let perFileLimit = max(1, maxSampleBytes / max(1, included.count))
        var remainingBudget = maxSampleBytes
        var sections = [
            "Picky watchdog spin sample excerpts",
            "Privacy: excerpts are capped and redacted; raw sample files are not bundled in full.",
            "maxTotalExcerptBytes=\(maxSampleBytes)",
            "maxFiles=\(maxWatchdogSampleFiles)"
        ]

        for sample in included {
            guard remainingBudget > 0 else { break }
            let readLimit = min(perFileLimit, remainingBudget)
            let data = prefixData(from: sample.url, maxBytes: readLimit, fileManager: fileManager) ?? Data()
            remainingBudget -= data.count
            let truncated = UInt64(data.count) < sample.sizeBytes
            let excerpt: String
            if let text = String(data: data, encoding: .utf8) {
                excerpt = PickyDiagnosticTextRedactor.redact(text)
            } else {
                excerpt = "(sample excerpt was not valid UTF-8; \(data.count) bytes omitted)"
            }
            sections.append("""

# \(sample.url.lastPathComponent)
originalSizeBytes=\(sample.sizeBytes)
excerptBytes=\(data.count)
truncated=\(truncated)
\(excerpt)
""")
        }
        return sections.joined(separator: "\n")
    }

    private static func prefixData(from sourceURL: URL, maxBytes: Int, fileManager: FileManager) -> Data? {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: max(1, maxBytes))
    }

    private static func watchdogStallSummary(from oslogText: String) -> WatchdogStallSummary {
        var summary = WatchdogStallSummary()
        for line in oslogText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let values = firstIntCaptures(
                in: line,
                pattern: #"main thread soft stall detected ageMs=(\d+) thresholdMs=(\d+)"#
            ), values.count == 2 {
                summary.softStallDetectedCount += 1
                summary.maxSoftStallAgeMs = max(summary.maxSoftStallAgeMs, values[0])
                summary.maxSoftStallThresholdMs = max(summary.maxSoftStallThresholdMs, values[1])
            }
            if let values = firstIntCaptures(
                in: line,
                pattern: #"main thread soft stall recovered ageMs=(\d+)"#
            ), values.count == 1 {
                summary.softStallRecoveredCount += 1
                summary.maxSoftStallRecoveryAgeMs = max(summary.maxSoftStallRecoveryAgeMs, values[0])
            }
        }
        return summary
    }

    private static func firstIntCaptures(in text: String, pattern: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
    }

    static func parseEADDRINUSEPorts(from text: String) -> [Int] {
        let patterns = [
            #"address already in use\s+127\.0\.0\.1:(\d+)"#,
            #"port:\s*(\d+)"#
        ]
        var ports: [Int] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                guard let portRange = Range(match.range(at: 1), in: text),
                      let port = Int(text[portRange]),
                      !ports.contains(port) else { continue }
                ports.append(port)
            }
        }
        return ports
    }

    private static func tailTextIfExists(
        from sourceURL: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) -> String? {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            guard fileSize > 0 else { return "" }
            let bytesToRead = min(fileSize, UInt64(max(1, maxBytes)))
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            if fileSize > bytesToRead {
                try handle.seek(toOffset: fileSize - bytesToRead)
            }
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
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
