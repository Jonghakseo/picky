//
//  PickyCronJobReaderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyCronJobReaderTests {
    @Test func readsV1StoreFromConfiguredAgentDirectory() throws {
        let scratch = try ScratchCronStore()
        let customAgentDir = scratch.root.appendingPathComponent("custom-agent", isDirectory: true)
        try scratch.write(
            #"{"version":1,"jobs":[{"id":"job-1","name":"Daily report","enabled":true,"kind":"cron","once":false,"schedule":"0 9 * * *","timezone":"Asia/Seoul","cwd":"/private/project","promptFile":"/private/prompt.md","createdAt":"2026-08-25T00:00:00Z","updatedAt":"2026-08-25T00:00:00Z","nextRunAt":"2026-08-26T00:00:00.123Z","lastRunLog":"/private/run.log"}]}"#,
            agentDir: customAgentDir
        )
        let reader = PickyCronJobReader(
            preferences: PickyPiInstallationPreferences(codingAgentDir: customAgentDir.path),
            homeURL: scratch.home,
            environment: [:]
        )

        guard case .jobs(let jobs) = reader.read() else {
            Issue.record("Expected decoded Cron jobs")
            return
        }
        let job = try #require(jobs.first)
        #expect(job.id == "job-1")
        #expect(job.schedule == "0 9 * * *")
        #expect(job.status == .active)
        #expect(job.nextRunAt != nil)
        #expect(job.scheduleText == "0 9 * * *")
    }

    @Test func usesEnvironmentAgentDirectoryWhenNoPreferenceIsConfigured() throws {
        let scratch = try ScratchCronStore()
        let environmentAgentDir = scratch.root.appendingPathComponent("environment-agent", isDirectory: true)
        try scratch.write(#"{"version":1,"jobs":[]}"#, agentDir: environmentAgentDir)
        let reader = PickyCronJobReader(
            preferences: .init(),
            homeURL: scratch.home,
            environment: [PickyPiInstallation.environmentAgentDirKey: environmentAgentDir.path]
        )

        #expect(reader.jobsURL == environmentAgentDir.appendingPathComponent("cron/jobs.json"))
        #expect(reader.read() == .empty)
    }

    @Test func distinguishesMissingEmptyMalformedAndUnsupportedStores() throws {
        let scratch = try ScratchCronStore()
        let reader = scratch.reader()
        #expect(reader.read() == .missing)

        try scratch.write(#"{"version":1,"jobs":[]}"#)
        #expect(reader.read() == .empty)

        try scratch.write("not json")
        #expect(reader.read() == .malformed)

        try scratch.write(#"{"version":2,"jobs":[]}"#)
        #expect(reader.read() == .unsupportedVersion(2))
    }

    @Test func mapsFilesystemFailuresToAnOpaqueUnreadableState() throws {
        let scratch = try ScratchCronStore()
        let reader = scratch.reader()
        try FileManager.default.createDirectory(at: reader.jobsURL, withIntermediateDirectories: true)

        guard case .unreadable = reader.read() else {
            Issue.record("Expected an opaque unreadable state")
            return
        }
    }

    @Test func preservesRawRunAtTextForOneShotJobs() throws {
        let scratch = try ScratchCronStore()
        try scratch.write(
            #"{"version":1,"jobs":[{"id":"once","name":"One shot","enabled":true,"kind":"at","once":true,"runAt":"2026-08-25T01:02:03.456+09:00","timezone":"Asia/Seoul","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z"}]}"#
        )

        guard case .jobs(let jobs) = scratch.reader().read() else {
            Issue.record("Expected projected one-shot job")
            return
        }
        #expect(jobs.first?.scheduleText == "2026-08-25T01:02:03.456+09:00")
    }

    @Test func parsesFractionalAndWholeSecondTimestamps() {
        #expect(PickyCronJobReader.parseDate("2026-08-25T01:02:03.456Z") != nil)
        #expect(PickyCronJobReader.parseDate("2026-08-25T01:02:03Z") != nil)
        #expect(PickyCronJobReader.parseDate("not-a-date") == nil)
    }

    @Test func projectsStatusesAndSortsActivityBeforeHistory() throws {
        let scratch = try ScratchCronStore()
        try scratch.write(
            """
            {
              "version": 1,
              "jobs": [
                {"id":"disabled","name":"Disabled","enabled":false,"kind":"cron","once":false,"schedule":"0 0 * * *","timezone":"UTC","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","lastRunAt":"2026-08-24T00:00:00Z"},
                {"id":"later","name":"Later","enabled":true,"kind":"cron","once":false,"schedule":"0 12 * * *","timezone":"UTC","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","nextRunAt":"2026-08-27T00:00:00Z"},
                {"id":"running","name":"Running","enabled":true,"kind":"cron","once":false,"schedule":"* * * * *","timezone":"UTC","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","running":true},
                {"id":"failed","name":"Failed","enabled":false,"kind":"cron","once":false,"schedule":"0 1 * * *","timezone":"UTC","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","lastExitCode":2,"disabledReason":"error","lastRunAt":"2026-08-25T00:00:00Z"},
                {"id":"completed","name":"Completed","enabled":false,"kind":"at","once":true,"runAt":"2026-08-21T00:00:00Z","timezone":"UTC","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","disabledReason":"completed_once","completedAt":"2026-08-23T00:00:00Z"},
                {"id":"sooner","name":"Sooner","enabled":true,"kind":"cron","once":false,"schedule":"0 10 * * *","timezone":"UTC","cwd":"/tmp","promptFile":"/tmp/p.md","createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","nextRunAt":"2026-08-26T00:00:00Z"}
              ]
            }
            """
        )

        guard case .jobs(let jobs) = scratch.reader().read() else {
            Issue.record("Expected projected jobs")
            return
        }

        #expect(jobs.map(\.id) == ["running", "sooner", "later", "failed", "disabled", "completed"])
        #expect(Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) }) == [
            "running": .running,
            "sooner": .active,
            "later": .active,
            "failed": .failed,
            "disabled": .disabled,
            "completed": .completed,
        ])
    }

    @Test func presentationExposesNoPromptPathCwdOrRunLogFields() throws {
        let scratch = try ScratchCronStore()
        try scratch.write(
            #"{"version":1,"jobs":[{"id":"private","name":"Private","enabled":true,"kind":"cron","once":false,"schedule":"0 9 * * *","timezone":"UTC","cwd":"/secret/cwd","promptFile":"/secret/prompt.md","createdAt":"2026-08-25T00:00:00Z","updatedAt":"2026-08-25T00:00:00Z","lastRunLog":"/secret/run.log"}]}"#
        )

        guard case .jobs(let jobs) = scratch.reader().read(), let job = jobs.first else {
            Issue.record("Expected projected job")
            return
        }
        let labels = Set(Mirror(reflecting: job).children.compactMap(\.label))
        #expect(labels.isDisjoint(with: ["promptFile", "prompt", "cwd", "lastRunLog"]))
    }
}

private struct ScratchCronStore {
    let root: URL
    let home: URL
    let agentDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-cron-reader-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        agentDir = home.appendingPathComponent(".pi/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func reader() -> PickyCronJobReader {
        PickyCronJobReader(
            preferences: PickyPiInstallationPreferences(codingAgentDir: agentDir.path),
            homeURL: home,
            environment: [:]
        )
    }

    func write(_ contents: String, agentDir: URL? = nil) throws {
        let url = (agentDir ?? self.agentDir).appendingPathComponent("cron/jobs.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
