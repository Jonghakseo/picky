//
//  PickyCronJobReader.swift
//  Picky
//
//  Reads Cron's local v1/v2 job index without opening prompt files or run logs.
//

import Foundation

enum PickyCronJobStatus: Equatable {
    case running
    case failed
    case completed
    case active
    case disabled
}

struct PickyCronExecution: Equatable {
    let date: Date
    let exitCode: Int?
    var promptFile: String? = nil
}

struct PickyCronJobPresentation: Equatable, Identifiable {
    let id: String
    let name: String
    let status: PickyCronJobStatus
    let enabled: Bool
    let schedule: String?
    let runAtText: String?
    let nextRunAt: Date?
    let lastRunAt: Date?
    let completedAt: Date?
    let lastExitCode: Int?
    var timezone: String? = nil
    var once: Bool? = nil
    var promptFile: String? = nil
    var executions: [PickyCronExecution] = []
    var historyTruncated = false
    var lastRunLog: String? = nil
    var lastRunPromptFile: String? = nil

    var scheduleText: String? {
        if let schedule, !schedule.isEmpty { return schedule }
        return runAtText
    }
}

enum PickyCronJobReadResult: Equatable {
    case missing
    case empty
    case jobs([PickyCronJobPresentation])
    case malformed
    case unsupportedVersion(Int)
    case unreadable
}

struct PickyCronJobReader {
    private struct Store: Decodable {
        let version: Int
        let jobs: [Job]
        let history: [Job]?
    }

    private struct Job: Decodable {
        let id: String
        let name: String
        let enabled: Bool
        let schedule: String?
        let timezone: String?
        let once: Bool?
        let runAt: String?
        let lastRunAt: String?
        let nextRunAt: String?
        let running: Bool?
        let lastExitCode: Int?
        let disabledReason: String?
        let completedAt: String?
        let promptFile: String?
        let lastRunLog: String?
        let lastRunPromptFile: String?
    }

    private let preferences: PickyPiInstallationPreferences?
    private let homeURL: URL
    private let environment: [String: String]
    private let fileManager: FileManager

    init(
        preferences: PickyPiInstallationPreferences? = nil,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.preferences = preferences
        self.homeURL = homeURL
        self.environment = environment
        self.fileManager = fileManager
    }

    var jobsURL: URL {
        let resolvedPreferences: PickyPiInstallationPreferences
        if let preferences {
            resolvedPreferences = preferences
        } else if homeURL.path == FileManager.default.homeDirectoryForCurrentUser.path {
            resolvedPreferences = PickyPiInstallation.preferences(from: PickySettingsStore().load())
        } else {
            resolvedPreferences = .init()
        }
        return PickyPiInstallation.resolve(
            preferences: resolvedPreferences,
            homeURL: homeURL,
            environment: environment,
            fileManager: fileManager
        )
        .codingAgentDirURL
        .appendingPathComponent("cron/jobs.json", isDirectory: false)
    }

    func read() -> PickyCronJobReadResult {
        let url = jobsURL
        guard fileManager.fileExists(atPath: url.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable
        }
        guard !data.isEmpty else { return .malformed }

        let store: Store
        do {
            store = try JSONDecoder().decode(Store.self, from: data)
        } catch {
            return .malformed
        }
        let storedJobs: [Job]
        switch store.version {
        case 1:
            storedJobs = store.jobs
        case 2:
            guard let history = store.history else { return .malformed }
            storedJobs = store.jobs + history
        default:
            return .unsupportedVersion(store.version)
        }

        let root = url.deletingLastPathComponent()
        let jobs = storedJobs.map { stored in
            var job = Self.project(stored)
            if let path = job.lastRunLog {
                let expected = root.appendingPathComponent("runs").appendingPathComponent(job.id)
                if !path.hasPrefix("/") || path.contains("\0") || path.split(separator: "/").contains("..")
                    || URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL != expected.standardizedFileURL {
                    job.lastRunLog = nil
                }
            }
            return job
        }.sorted(by: Self.isOrderedBefore)
        return jobs.isEmpty ? .empty : .jobs(jobs)
    }

    /// The lightweight index reader above deliberately never opens prompt or log files.
    func readCalendar(interval: DateInterval, maximumLogReads: Int = 10_000) -> PickyCronJobReadResult {
        let result = read()
        guard case .jobs(var jobs) = result else { return result }
        let root = jobsURL.deletingLastPathComponent()
        var remaining = max(0, maximumLogReads)
        var remainingEntries = 100_000
        for index in jobs.indices {
            let job = jobs[index]
            guard !job.id.isEmpty, job.id != ".", job.id != "..",
                  !job.id.contains("/"), !job.id.contains("\0") else { continue }
            let directory = root.appendingPathComponent("runs").appendingPathComponent(job.id)
            // Reject directory symlinks before enumeration. Individual opens are descriptor-confined too.
            var executions: [PickyCronExecution] = []
            if directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath()
                .appendingPathComponent("runs").appendingPathComponent(job.id).path,
               let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard remainingEntries > 0 else { jobs[index].historyTruncated = true; break }
                    remainingEntries -= 1
                    guard let date = Self.runDate(filename: url.lastPathComponent),
                          date >= interval.start, date < interval.end else { continue }
                    guard remaining > 0 else { jobs[index].historyTruncated = true; break }
                    remaining -= 1
                    guard case .loaded(let prefix) = PickyCronLocalFile.read(
                            path: url.path, root: root, limit: 1024, prefixOnly: true
                          ) else { continue }
                    let header = prefix.components(separatedBy: "\n\n")[0].components(separatedBy: "\n")
                    let exitCode: Int?
                    switch header.first {
                    case "# cron run: \(job.id)":
                        let values = header.filter { $0.hasPrefix("exitCode: ") }
                        exitCode = values.count == 1 ? Int(values[0].dropFirst(10)) : nil
                    case "# cron run failure: \(job.id)": exitCode = 1
                    case "# cron session delivery: \(job.id)": exitCode = nil
                    default: continue
                    }
                    let linked = job.lastRunLog.map { URL(fileURLWithPath: $0).standardizedFileURL == url.standardizedFileURL } ?? false
                    executions.append(.init(date: date, exitCode: exitCode,
                        promptFile: linked ? job.lastRunPromptFile : nil))
                }
            }
            // The plugin stores finish time in lastRunAt. Link it to the filename start even
            // when that run lies outside the requested interval, avoiding a false extra event.
            if let path = job.lastRunLog,
               URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
               let start = Self.runDate(filename: URL(fileURLWithPath: path).lastPathComponent) {
                if !executions.contains(where: { $0.date == start }), start >= interval.start, start < interval.end {
                    executions.append(.init(date: start, exitCode: job.lastExitCode, promptFile: job.lastRunPromptFile))
                }
            } else if let latest = job.lastRunAt ?? job.completedAt,
                      latest >= interval.start, latest < interval.end,
                      !executions.contains(where: { $0.date == latest }) {
                executions.append(.init(date: latest, exitCode: job.lastExitCode, promptFile: job.lastRunPromptFile))
            }
            jobs[index].executions = executions.sorted { $0.date < $1.date }
        }
        return .jobs(jobs)
    }

    static func runDate(filename: String) -> Date? {
        guard filename.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z\.log$"#, options: .regularExpression) != nil else { return nil }
        var stamp = Array(filename.dropLast(4))
        stamp[13] = ":"; stamp[16] = ":"; stamp[19] = "."
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(String(stamp))
    }

    private static func project(_ job: Job) -> PickyCronJobPresentation {
        let lastRunAt = parseDate(job.lastRunAt)
        let completedAt = parseDate(job.completedAt)
        let status: PickyCronJobStatus
        if job.running == true {
            status = .running
        } else if job.disabledReason == "error" || (job.lastExitCode.map { $0 != 0 } == true) {
            status = .failed
        } else if job.disabledReason == "completed_once" || completedAt != nil {
            status = .completed
        } else if job.enabled {
            status = .active
        } else {
            status = .disabled
        }

        return PickyCronJobPresentation(
            id: job.id,
            name: job.name,
            status: status,
            enabled: job.enabled,
            schedule: job.schedule,
            runAtText: job.runAt,
            nextRunAt: parseDate(job.nextRunAt),
            lastRunAt: lastRunAt,
            completedAt: completedAt,
            lastExitCode: job.lastExitCode,
            timezone: job.timezone,
            once: job.once,
            promptFile: job.promptFile,
            lastRunLog: job.lastRunLog,
            lastRunPromptFile: job.lastRunPromptFile
        )
    }

    private static func isOrderedBefore(_ lhs: PickyCronJobPresentation, _ rhs: PickyCronJobPresentation) -> Bool {
        if (lhs.status == .running) != (rhs.status == .running) {
            return lhs.status == .running
        }
        if lhs.enabled != rhs.enabled { return lhs.enabled }

        switch (lhs.nextRunAt, rhs.nextRunAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let leftHistory = lhs.lastRunAt ?? lhs.completedAt
        let rightHistory = rhs.lastRunAt ?? rhs.completedAt
        switch (leftHistory, rightHistory) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

}
