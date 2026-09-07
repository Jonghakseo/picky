//
//  PickyHubQuickStartWorkflow.swift
//  Picky
//
//  The fixed quick-start workflows. Each one ships a bundled markdown guide
//  (`quick-start-<id>.md`) that becomes the first instruction of a new Pickle;
//  Pi drives the interview from there, one question at a time.
//

import Foundation
import SwiftUI

struct PickyHubQuickStartWorkflow: Identifiable, Equatable {
    let id: String
    let titleKey: LocalizedStringKey
    let descriptionKey: LocalizedStringKey
    let systemImage: String
    let guideResourceName: String

    var title: String { L10n.t("hub.quickStart.workflow.\(id).title") }

    static let landingPage = PickyHubQuickStartWorkflow(
        id: "landing",
        titleKey: "hub.quickStart.workflow.landing.title",
        descriptionKey: "hub.quickStart.workflow.landing.description",
        systemImage: "rectangle.on.rectangle.angled",
        guideResourceName: "quick-start-landing"
    )

    static let nativeApp = PickyHubQuickStartWorkflow(
        id: "native",
        titleKey: "hub.quickStart.workflow.native.title",
        descriptionKey: "hub.quickStart.workflow.native.description",
        systemImage: "macbook.and.iphone",
        guideResourceName: "quick-start-native"
    )

    static let appGuide = PickyHubQuickStartWorkflow(
        id: "guide",
        titleKey: "hub.quickStart.workflow.guide.title",
        descriptionKey: "hub.quickStart.workflow.guide.description",
        systemImage: "book.closed",
        guideResourceName: "quick-start-guide"
    )

    static let fileOrganizing = PickyHubQuickStartWorkflow(
        id: "files",
        titleKey: "hub.quickStart.workflow.files.title",
        descriptionKey: "hub.quickStart.workflow.files.description",
        systemImage: "folder.badge.gearshape",
        guideResourceName: "quick-start-files"
    )

    static let all: [PickyHubQuickStartWorkflow] = [.landingPage, .nativeApp, .appGuide, .fileOrganizing]

    static func workflow(id: String) -> PickyHubQuickStartWorkflow? {
        all.first { $0.id == id }
    }

    /// Bundled guide markdown. Falls back to a one-line instruction so a
    /// missing resource degrades to a plain Pickle rather than a failure.
    func loadGuide(bundle: Bundle = .main) -> String {
        if let url = bundle.url(forResource: guideResourceName, withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "# \(title)\n\n\(L10n.t("hub.quickStart.guide.fallback"))"
    }
}

/// The most recent quick-start Pickle, persisted so the "이어서 하기" card can
/// point back at it after a relaunch.
struct PickyHubQuickStartRecord: Codable, Equatable {
    let workflowID: String
    let sessionID: String
    let startedAt: Date
}
