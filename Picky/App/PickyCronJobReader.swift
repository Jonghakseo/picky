//
//  PickyCronJobReader.swift
//  Picky
//
//  Reads Cron's local v1 job index without opening prompt files or run logs.
//

import Foundation

enum PickyCronJobStatus: Equatable {
    case running
    case failed
    case completed
    case active
    case disabled
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
    }

    private struct Job: Decodable {
        let id: String
        let name: String
        let enabled: Bool
        let schedule: String?
        let runAt: String?
        let lastRunAt: String?
        let nextRunAt: String?
        let running: Bool?
        let lastExitCode: Int?
        let disabledReason: String?
        let completedAt: String?
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
        guard store.version == 1 else { return .unsupportedVersion(store.version) }

        let jobs = store.jobs.map(Self.project).sorted(by: Self.isOrderedBefore)
        return jobs.isEmpty ? .empty : .jobs(jobs)
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
            lastExitCode: job.lastExitCode
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
