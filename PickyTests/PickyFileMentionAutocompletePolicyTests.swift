//
//  PickyFileMentionAutocompletePolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyFileMentionAutocompletePolicyTests {
    @Test func acceptDecisionConsumesPendingSearch() {
        #expect(PickyFileMentionAutocompletePolicy.acceptDecision(
            isVisible: true,
            searchDraft: "inspect @Conf",
            draft: "inspect @Confidential",
            hasSuggestions: true
        ) == .consume)
    }

    @Test func acceptDecisionAcceptsCurrentSuggestions() {
        #expect(PickyFileMentionAutocompletePolicy.acceptDecision(
            isVisible: true,
            searchDraft: "inspect @Conf",
            draft: "inspect @Conf",
            hasSuggestions: true
        ) == .accept)
    }

    @Test func acceptDecisionPassesThroughCompletedEmptySearch() {
        #expect(PickyFileMentionAutocompletePolicy.acceptDecision(
            isVisible: true,
            searchDraft: "inspect @Missing",
            draft: "inspect @Missing",
            hasSuggestions: false
        ) == .passthrough)
    }

    @Test func queryParsesUnquotedMentionAtDraftEnd() throws {
        let query = try #require(PickyFileMentionAutocompletePolicy.query(in: "please inspect @Picky/HUD/Conv"))

        #expect(query.rawQuery == "Picky/HUD/Conv")
        #expect(query.isQuoted == false)
        #expect(query.replacementText == "@Picky/HUD/Conv")
    }

    @Test func queryParsesQuotedMentionWithWhitespaceAtDraftEnd() throws {
        let query = try #require(PickyFileMentionAutocompletePolicy.query(in: "open @\"Some File"))

        #expect(query.rawQuery == "Some File")
        #expect(query.isQuoted == true)
        #expect(query.replacementText == "@\"Some File")
    }

    @Test func queryParsesQuotedMentionWithTrailingInternalWhitespace() throws {
        let query = try #require(PickyFileMentionAutocompletePolicy.query(in: "open @\"Some "))

        #expect(query.rawQuery == "Some ")
        #expect(query.isQuoted == true)
        #expect(query.replacementText == "@\"Some ")
    }

    @Test func queryParsesClosedQuotedMentionAtDraftEnd() throws {
        let query = try #require(PickyFileMentionAutocompletePolicy.query(in: "open @\"Some File.swift\""))

        #expect(query.rawQuery == "Some File.swift")
        #expect(query.isQuoted == true)
        #expect(query.replacementText == "@\"Some File.swift\"")
    }

    @Test func queryIsNilWhenUnquotedMentionEndsWithWhitespace() {
        #expect(PickyFileMentionAutocompletePolicy.query(in: "open @Picky ") == nil)
        #expect(PickyFileMentionAutocompletePolicy.query(in: "open @Picky/HUD\n") == nil)
    }

    @Test func completionTextAddsSpaceForFilesAndKeepsDirectorySlashWithoutSpace() {
        let file = PickyFileMentionAutocompletePolicy.Suggestion(
            label: "App.swift",
            displayPath: "Picky/App.swift",
            isDirectory: false,
            completionText: "@Picky/App.swift "
        )
        let directory = PickyFileMentionAutocompletePolicy.Suggestion(
            label: "Picky/",
            displayPath: "Picky/",
            isDirectory: true,
            completionText: "@Picky/"
        )

        #expect(file.completionText == "@Picky/App.swift ")
        #expect(directory.completionText == "@Picky/")
    }

    @Test func completedTextReplacesActiveMentionTokenOnly() {
        let suggestion = PickyFileMentionAutocompletePolicy.Suggestion(
            label: "Conversation/",
            displayPath: "Picky/HUD/Conversation/",
            isDirectory: true,
            completionText: "@Picky/HUD/Conversation/"
        )

        #expect(PickyFileMentionAutocompletePolicy.completedText(in: "inspect @Picky/HUD/Conv", with: suggestion) == "inspect @Picky/HUD/Conversation/")
    }

    @Test func completedTextReplacesQuotedMentionTokenOnly() {
        let suggestion = PickyFileMentionAutocompletePolicy.Suggestion(
            label: "Some File.swift",
            displayPath: "Some File.swift",
            isDirectory: false,
            completionText: "@\"Some File.swift\" "
        )

        #expect(PickyFileMentionAutocompletePolicy.completedText(in: "open @\"Some ", with: suggestion) == "open @\"Some File.swift\" ")
    }

    @Test func fdPathQueryBuildsFullPathRegex() {
        #expect(PickyFileMentionAutocompletePolicy.fdPathQuery("Composer") == "Composer")
        #expect(PickyFileMentionAutocompletePolicy.fdPathQuery("a/b") == "a[\\\\/]b")
        #expect(PickyFileMentionAutocompletePolicy.fdPathQuery("a.b/c") == "a\\.b[\\\\/]c")
        #expect(PickyFileMentionAutocompletePolicy.fdPathQuery("a/b/") == "a[\\\\/]b[\\\\/]")
        #expect(PickyFileMentionAutocompletePolicy.fdPathQuery("/") == "/")
    }

    @Test func fdArgumentsMatchPiArguments() {
        let expectedBase = [
            "--base-directory", "/tmp/project",
            "--max-results", "100",
            "--type", "f",
            "--type", "d",
            "--follow",
            "--hidden",
            "--exclude", ".git",
            "--exclude", ".git/*",
            "--exclude", ".git/**",
        ]

        #expect(PickyFileMentionAutocompletePolicy.fdArguments(baseDirectory: "/tmp/project", pattern: "") == expectedBase)
        #expect(PickyFileMentionAutocompletePolicy.fdArguments(baseDirectory: "/tmp/project", pattern: "Composer") == expectedBase + ["Composer"])
        #expect(PickyFileMentionAutocompletePolicy.fdArguments(baseDirectory: "/tmp/project", pattern: "HUD/Composer") == expectedBase + ["--full-path", "HUD[\\\\/]Composer"])
    }

    @Test func scopedQueryResolvesRelativeDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDirectory("Picky/HUD", in: root)

        let scoped = try #require(PickyFileMentionAutocompletePolicy.scopedQuery(for: "Picky/HUD/Conv", cwd: root.path))
        #expect(scoped.baseDirectory == root.appendingPathComponent("Picky/HUD").path)
        #expect(scoped.pattern == "Conv")
        #expect(scoped.displayBase == "Picky/HUD/")
        #expect(PickyFileMentionAutocompletePolicy.scopedQuery(for: "Missing/Conv", cwd: root.path) == nil)
        #expect(PickyFileMentionAutocompletePolicy.scopedQuery(for: "Composer", cwd: root.path) == nil)
    }

    @Test func scopedQueryExpandsHomeAndAllowsAbsoluteAndParentPaths() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let project = parent.appendingPathComponent("project", isDirectory: true)
        let home = parent.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try createDirectory("Sources", in: home)

        let homeScoped = try #require(PickyFileMentionAutocompletePolicy.scopedQuery(for: "~/Sources/Comp", cwd: project.path, home: home.path))
        #expect(homeScoped.baseDirectory == home.appendingPathComponent("Sources").path)
        #expect(homeScoped.displayBase == "~/Sources/")

        let absoluteQuery = parent.path + "/"
        let absoluteScoped = try #require(PickyFileMentionAutocompletePolicy.scopedQuery(for: absoluteQuery, cwd: project.path))
        #expect(absoluteScoped.baseDirectory == absoluteQuery)
        #expect(absoluteScoped.pattern.isEmpty)

        let parentScoped = try #require(PickyFileMentionAutocompletePolicy.scopedQuery(for: "../", cwd: project.path))
        #expect(parentScoped.baseDirectory == parent.path)
        #expect(parentScoped.pattern.isEmpty)
    }

    @Test func scoreEntryMatchesPiBandsAndDirectoryBonus() {
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "Sources/Composer", query: "Composer", isDirectory: false) == 100)
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "Sources/ComposerView.swift", query: "Composer", isDirectory: false) == 80)
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "Sources/MyComposer.swift", query: "Composer", isDirectory: false) == 50)
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "Composer/Unrelated.swift", query: "Composer", isDirectory: false) == 30)
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "Sources/Other.swift", query: "Composer", isDirectory: false) == 0)
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "Sources/Composer", query: "Composer", isDirectory: true) == 110)
    }

    @Test func directoryTrailingSlashParticipatesInPathScoringWithoutChangingFilenameBands() {
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "sub/deep/", query: "deep/", isDirectory: true) == 40)
        #expect(PickyFileMentionAutocompletePolicy.scoreEntry(path: "sub/deep/", query: "deep", isDirectory: true) == 110)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(
            fromFdLines: ["sub/deep/"],
            pattern: "deep/",
            displayBase: ""
        )
        #expect(suggestions.map(\.displayPath) == ["sub/deep"])
    }

    @Test func suggestionsParseFilterAndRankFdOutput() {
        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(
            fromFdLines: [
                ".git/", ".git/config", "nested/.git/config", "Other/Composer/", "Composer.swift",
                "MyComposer.swift", "Nested/Composer", "Composer/",
            ],
            pattern: "Composer",
            displayBase: "Picky/HUD/"
        )

        #expect(suggestions.map(\.displayPath) == [
            "Picky/HUD/Other/Composer", "Picky/HUD/Composer", "Picky/HUD/Nested/Composer",
            "Picky/HUD/Composer.swift", "Picky/HUD/MyComposer.swift",
        ])
        #expect(suggestions.map(\.label) == ["Composer/", "Composer/", "Composer", "Composer.swift", "MyComposer.swift"])
        #expect(suggestions[1].isDirectory)
        #expect(suggestions[1].completionText == "@Picky/HUD/Composer/")
    }

    @Test func suggestionsPreserveFdOrderForEqualScoresAndCapAtTwenty() {
        let lines = (0..<25).map { "Composer\($0).swift" }
        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(fromFdLines: lines, pattern: "Composer", displayBase: "")

        #expect(suggestions.count == 20)
        #expect(suggestions.map(\.displayPath) == Array(lines.prefix(20)))
    }

    @Test func suggestionsWithEmptyPatternPreserveFdOrderAndRootDisplay() {
        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(
            fromFdLines: ["z.swift", "Folder/", "a.swift"],
            pattern: "",
            displayBase: "/"
        )

        #expect(suggestions.map(\.displayPath) == ["/z.swift", "/Folder", "/a.swift"])
        #expect(suggestions.map(\.completionText) == ["@/z.swift ", "@/Folder/", "@/a.swift "])
    }

    @Test func suggestionsQuoteWhitespaceCompletions() {
        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(
            fromFdLines: ["Some File.swift", "Some Directory/", "Plain.swift"],
            pattern: "Some",
            displayBase: ""
        )

        #expect(suggestions.map(\.completionText) == ["@\"Some Directory/", "@\"Some File.swift\" "])

        let quoted = PickyFileMentionAutocompletePolicy.suggestions(
            fromFdLines: ["Plain.swift"],
            pattern: "Plain",
            displayBase: "",
            isQuoted: true
        )
        #expect(quoted.first?.completionText == "@\"Plain.swift\" ")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-file-mention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createDirectory(_ relativePath: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}
