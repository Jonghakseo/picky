//
//  PickyComposerDraftStore.swift
//  Picky
//
//  Persists unsent Pickle composer text and file attachments per session so
//  drafts survive HUD/app restarts and session switches.
//

import Foundation

protocol PickyComposerDraftStoring: AnyObject {
    func draft(for sessionID: String) -> String?
    func setDraft(_ draft: String?, for sessionID: String)
    func prune(knownSessionIDs: Set<String>)
}

final class PickyUserDefaultsComposerDraftStore: PickyComposerDraftStoring {
    static let shared = PickyUserDefaultsComposerDraftStore()
    static let key = "PickyComposerDraftsBySessionID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func draft(for sessionID: String) -> String? {
        guard !sessionID.isEmpty else { return nil }
        let drafts = defaults.dictionary(forKey: Self.key) as? [String: String]
        guard let draft = drafts?[sessionID], !draft.isEmpty else { return nil }
        return draft
    }

    func setDraft(_ draft: String?, for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        var drafts = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        if let draft, !draft.isEmpty {
            drafts[sessionID] = draft
        } else {
            drafts.removeValue(forKey: sessionID)
        }
        persist(drafts)
    }

    func prune(knownSessionIDs: Set<String>) {
        guard !knownSessionIDs.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        let drafts = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        let filtered = drafts.filter { knownSessionIDs.contains($0.key) && !$0.value.isEmpty }
        persist(filtered)
    }

    private func persist(_ drafts: [String: String]) {
        if drafts.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(drafts, forKey: Self.key)
        }
    }
}

enum PickyLegacySessionNoteData {
    static let key = "PickySessionNotesBySessionID"

    static func remove(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// Persists composer file attachments per session as a list of absolute paths.
/// Kept separate from the text draft store so the on-disk schema stays simple
/// (a String dict vs. an array dict) and either store can evolve independently.
protocol PickyComposerAttachmentDraftStoring: AnyObject {
    func attachmentPaths(for sessionID: String) -> [String]
    func setAttachmentPaths(_ paths: [String], for sessionID: String)
    func prune(knownSessionIDs: Set<String>)
}

final class PickyUserDefaultsComposerAttachmentDraftStore: PickyComposerAttachmentDraftStoring {
    static let shared = PickyUserDefaultsComposerAttachmentDraftStore()
    static let key = "PickyComposerAttachmentsBySessionID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attachmentPaths(for sessionID: String) -> [String] {
        guard !sessionID.isEmpty else { return [] }
        let all = defaults.dictionary(forKey: Self.key) as? [String: [String]]
        return all?[sessionID] ?? []
    }

    func setAttachmentPaths(_ paths: [String], for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        var all = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            all.removeValue(forKey: sessionID)
        } else {
            all[sessionID] = cleaned
        }
        persist(all)
    }

    func prune(knownSessionIDs: Set<String>) {
        guard !knownSessionIDs.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        let all = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        let filtered = all.filter { knownSessionIDs.contains($0.key) && !$0.value.isEmpty }
        persist(filtered)
    }

    private func persist(_ all: [String: [String]]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(all, forKey: Self.key)
        }
    }
}
