//
//  PickyFileMentionAutocompletePolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyFileMentionAutocompletePolicyTests {
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

    @Test func suggestionsSearchCwdByPrefixWithDirectoriesFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDirectory("Picky/HUD/Conversation", in: root)
        try writeFile("Picky/App.swift", in: root)
        try writeFile("Picky/Readme.md", in: root)
        try createDirectory("PictureAssets", in: root)
        try writeFile("Pico.txt", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@Pic", cwd: root.path)

        #expect(Array(suggestions.map(\.displayPath).prefix(3)) == ["Picky/", "PictureAssets/", "Pico.txt"])
        #expect(Array(suggestions.map(\.completionText).prefix(3)) == ["@Picky/", "@PictureAssets/", "@Pico.txt "])
    }

    @Test func suggestionsCanFindNestedFilesWithFuzzyPathQuery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("Picky/HUD/Conversation/PickyConversationComposerView.swift", in: root)
        try writeFile("Picky/HUD/Conversation/PickyConversationCardView.swift", in: root)
        try writeFile("Picky/Context/PickyContextPacket.swift", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@composer", cwd: root.path)

        #expect(suggestions.first?.displayPath == "Picky/HUD/Conversation/PickyConversationComposerView.swift")
        #expect(suggestions.first?.completionText == "@Picky/HUD/Conversation/PickyConversationComposerView.swift ")
    }

    @Test func suggestionsCanFindNestedFilesWithSubsequenceQuery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("Picky/HUD/Conversation/PickyConversationComposerView.swift", in: root)
        try writeFile("Picky/HUD/Conversation/PickyConversationCardView.swift", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@pcv", cwd: root.path)

        #expect(suggestions.map(\.displayPath).contains("Picky/HUD/Conversation/PickyConversationComposerView.swift"))
    }

    @Test func suggestionsSkipHeavyRecursiveDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("node_modules/pkg/ComposerOnlyInNodeModules.swift", in: root)
        try writeFile("Sources/App/ComposerVisible.swift", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@Composer", cwd: root.path)

        #expect(suggestions.map(\.displayPath).contains("Sources/App/ComposerVisible.swift"))
        #expect(!suggestions.map(\.displayPath).contains("node_modules/pkg/ComposerOnlyInNodeModules.swift"))
    }

    @Test func suggestionsSearchNestedDirectoryByLeafPrefix() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDirectory("Picky/HUD/Conversation", in: root)
        try createDirectory("Picky/HUD/Controls", in: root)
        try writeFile("Picky/HUD/ConversationCard.swift", in: root)
        try writeFile("Picky/HUD/Other.swift", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@Picky/HUD/Conv", cwd: root.path)

        #expect(suggestions.map(\.displayPath) == ["Picky/HUD/Conversation/", "Picky/HUD/ConversationCard.swift"])
        #expect(suggestions.map(\.completionText) == ["@Picky/HUD/Conversation/", "@Picky/HUD/ConversationCard.swift "])
    }

    @Test func suggestionsExcludeDotGitAndDotGitContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDirectory(".git/objects", in: root)
        try writeFile(".gitignore", in: root)
        try writeFile(".git/config", in: root)
        try writeFile("Visible.swift", in: root)

        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@.git", cwd: root.path).isEmpty)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@.git/config", cwd: root.path).isEmpty)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@Vis", cwd: root.path).map(\.displayPath) == ["Visible.swift"])
    }

    @Test func suggestionsDoNotEscapeWorkingDirectoryWithParentTraversal() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try createDirectory("src", in: root)
        try createDirectory("sibling-secret", in: parent)
        try writeFile("sibling-secret/Token.swift", in: parent)

        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@../", cwd: root.path).isEmpty)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@../sibling-secret/T", cwd: root.path).isEmpty)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@src", cwd: root.path).map(\.displayPath) == ["src/"])
    }

    @Test func suggestionsLimitResultsAndReturnEmptyForInvalidCwd() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<25 {
            try writeFile(String(format: "File%02d.swift", index), in: root)
        }

        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@File", cwd: root.path).count == 20)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@File", cwd: nil).isEmpty)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@File", cwd: "").isEmpty)
        #expect(PickyFileMentionAutocompletePolicy.suggestions(for: "@File", cwd: root.appendingPathComponent("missing").path).isEmpty)
    }

    @Test func suggestionsQuoteWhitespacePathCompletion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("Some File.swift", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@\"Some", cwd: root.path)

        #expect(suggestions.map(\.displayPath) == ["Some File.swift"])
        #expect(suggestions.map(\.completionText) == ["@\"Some File.swift\" "])
    }

    @Test func suggestionsQuoteWhitespaceDirectoryCompletionWithoutTrailingSpace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDirectory("Some Directory", in: root)

        let suggestions = PickyFileMentionAutocompletePolicy.suggestions(for: "@\"Some", cwd: root.path)

        #expect(suggestions.map(\.displayPath) == ["Some Directory/"])
        #expect(suggestions.map(\.completionText) == ["@\"Some Directory/"])
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

    private func writeFile(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fixture".write(to: url, atomically: true, encoding: .utf8)
    }
}
