//
//  PickyFullscreenWorkInfoSnapshot.swift
//  Picky
//
//  Read-only projection for the fullscreen 변경사항 panel.
//

import Foundation

struct PickyFullscreenWorkInfoSnapshot: Equatable {
    struct Artifact: Equatable, Identifiable {
        let id: String
        let kind: String
        let title: String
        let path: String?
        let url: URL?
        let updatedAt: Date
    }

    let sessionID: String
    let changedFiles: [PickyChangedFile]
    let artifacts: [Artifact]

    static func make(from session: PickySessionListViewModel.SessionCard) -> Self {
        Self(
            sessionID: session.id,
            changedFiles: session.changedFiles,
            artifacts: session.artifacts.map {
                Artifact(
                    id: $0.id,
                    kind: $0.kind,
                    title: $0.title,
                    path: $0.path,
                    url: $0.url,
                    updatedAt: $0.updatedAt
                )
            }
        )
    }
}
