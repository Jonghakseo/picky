//
//  PickySessionArtifactsViewTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySessionArtifactsViewTests {
    @Test func artifactsPresentationFiltersSortsAndCountsUnseenFiles() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let artifacts = [
            PickyArtifact(id: "link", kind: "github", title: "PR", path: nil, url: URL(string: "https://github.com")!, updatedAt: newer),
            PickyArtifact(id: "old-file", kind: "file", title: "Old", path: "/tmp/old.md", url: nil, updatedAt: older),
            PickyArtifact(id: "new-file", kind: "file", title: "New", path: "/tmp/new.pdf", url: nil, updatedAt: newer),
        ]

        #expect(PickySessionArtifactsPresentation.fileArtifacts(from: artifacts).map(\.id) == ["new-file", "old-file"])
        #expect(PickySessionArtifactsPresentation.latestUpdatedAt(artifacts: artifacts) == newer)
        #expect(PickySessionArtifactsPresentation.unseenCount(artifacts: artifacts, lastSeenArtifactsAt: nil) == 2)
        #expect(PickySessionArtifactsPresentation.unseenCount(artifacts: artifacts, lastSeenArtifactsAt: older) == 1)
        #expect(PickySessionArtifactsPresentation.unseenCount(artifacts: artifacts, lastSeenArtifactsAt: newer) == 0)
    }

    @Test func artifactRowMarksMissingPathsAndKeepsTheirCopyablePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("report.md")
        try "report".write(to: existing, atomically: true, encoding: .utf8)
        let present = PickySessionArtifactRowPresentation(
            artifact: PickyArtifact(id: "present", kind: "file", title: "Report", path: existing.path, url: nil, updatedAt: .now),
            homeURL: root
        )
        let missing = PickySessionArtifactRowPresentation(
            artifact: PickyArtifact(id: "missing", kind: "file", title: "Missing", path: root.appendingPathComponent("missing.md").path, url: nil, updatedAt: .now),
            homeURL: root
        )

        #expect(present.isMissing == false)
        #expect(missing.isMissing)
        #expect(missing.artifact.path?.hasSuffix("missing.md") == true)
    }
}
