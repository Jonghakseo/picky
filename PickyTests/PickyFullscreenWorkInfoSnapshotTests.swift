//
//  PickyFullscreenWorkInfoSnapshotTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenWorkInfoSnapshot")
struct PickyFullscreenWorkInfoSnapshotTests {
    @Test func projectsEmptySessionWithoutInventingUnavailableData() {
        let session = card(artifacts: [], changedFiles: [])

        let snapshot = PickyFullscreenWorkInfoSnapshot.make(from: session)

        #expect(snapshot.sessionID == "session-1")
        #expect(snapshot.changedFiles.isEmpty)
        #expect(snapshot.artifacts.isEmpty)
    }

    @Test func projectsExistingChangedFilesAndArtifactsOnly() {
        let artifactDate = Date(timeIntervalSince1970: 1_800_000_090)
        let artifactURL = URL(string: "https://github.com/Jonghakseo/picky/pull/123")!
        let session = card(
            artifacts: [
                PickyArtifact(
                    id: "artifact-1",
                    kind: "github",
                    title: "Fullscreen workspace PR",
                    path: nil,
                    url: artifactURL,
                    updatedAt: artifactDate
                )
            ],
            changedFiles: [
                PickyChangedFile(path: "Picky/File.swift", status: "modified", summary: "Updated UI")
            ]
        )

        let snapshot = PickyFullscreenWorkInfoSnapshot.make(from: session)

        #expect(snapshot.sessionID == "session-1")
        #expect(snapshot.changedFiles == [PickyChangedFile(path: "Picky/File.swift", status: "modified", summary: "Updated UI")])
        #expect(snapshot.artifacts == [
            .init(
                id: "artifact-1",
                kind: "github",
                title: "Fullscreen workspace PR",
                path: nil,
                url: artifactURL,
                updatedAt: artifactDate
            )
        ])
    }

    @Test func artifactBadgeTextUsesKnownReferenceLinkKinds() {
        let github = artifact(kind: "github", url: "https://github.com/Jonghakseo/picky/pull/123")
        let slack = artifact(kind: "link", url: "https://creatrip.slack.com/archives/C123/p1800000000000000")
        let googleDocs = artifact(kind: "link", url: "https://docs.google.com/document/d/doc-id/edit")
        let fallback = artifact(kind: "report", url: nil)

        #expect(PickyFullscreenWorkInfoPanelView.artifactBadgeText(for: github) == "GitHub")
        #expect(PickyFullscreenWorkInfoPanelView.artifactBadgeText(for: slack) == "Slack")
        #expect(PickyFullscreenWorkInfoPanelView.artifactBadgeText(for: googleDocs) == "Google")
        #expect(PickyFullscreenWorkInfoPanelView.artifactBadgeText(for: fallback) == "Report")
    }

    private func card(
        artifacts: [PickyArtifact] = [],
        changedFiles: [PickyChangedFile] = []
    ) -> PickySessionListViewModel.SessionCard {
        PickyAgentSession(
            id: "session-1",
            title: "Test Pickle",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_060),
            logs: [],
            tools: [],
            artifacts: artifacts,
            changedFiles: changedFiles,
            messages: []
        ).toSessionCard()
    }

    private func artifact(kind: String, url: String?) -> PickyFullscreenWorkInfoSnapshot.Artifact {
        PickyFullscreenWorkInfoSnapshot.Artifact(
            id: UUID().uuidString,
            kind: kind,
            title: "Reference",
            path: nil,
            url: url.flatMap(URL.init(string:)),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

private extension PickyAgentSession {
    func toSessionCard() -> PickySessionListViewModel.SessionCard {
        PickySessionListViewModel.SessionCard.fromAgentSession(self)
    }
}
