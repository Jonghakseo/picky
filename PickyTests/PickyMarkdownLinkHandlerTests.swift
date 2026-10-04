import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyMarkdownLinkHandlerTests {
    @Test(arguments: [false, true])
    func localMarkdownClicksOpenResolvedFiles(usesSwiftUICoordinator: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("리뷰 자료%20#.html")
        try "<html></html>".write(to: file, atomically: true, encoding: .utf8)

        let delegate: PickyMarkdownLinkTextViewDelegate = usesSwiftUICoordinator
            ? PickyMarkdownInlineTextView.Coordinator()
            : PickyMarkdownLinkTextViewDelegate()
        var opened: [URL] = []
        var failures: [PickyMarkdownLinkFailure] = []
        delegate.linkContext = PickyMarkdownLinkContext(
            workingDirectory: root.path,
            homeDirectory: root,
            onFailure: { failures.append($0) }
        )
        delegate.openFile = { opened.append($0); return true }
        let textView = NSTextView()
        let encodedName = "reports/%EB%A6%AC%EB%B7%B0%20%EC%9E%90%EB%A3%8C%2520%23.html"
        let destinations = [
            encodedName,
            "./" + encodedName,
            "reports/../" + encodedName,
            "~/" + encodedName,
            file.absoluteString,
            String(file.absoluteString.dropFirst("file://".count))
        ]
        for destination in destinations {
            let link = try markdownLink(destination + "?mode=preview#summary")
            #expect(delegate.textView(textView, clickedOnLink: link, at: 0))
            let actual = try #require(opened.last)
            #expect(actual.isFileURL)
            #expect(actual.path == file.standardizedFileURL.path)
            let components = try #require(URLComponents(url: actual, resolvingAgainstBaseURL: false))
            #expect(components.query == "mode=preview")
            #expect(components.fragment == "summary")
        }
        #expect(opened.count == destinations.count)
        #expect(failures.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingFilesAreReportedWithoutSystemOpening(usesSwiftUICoordinator: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let delegate: PickyMarkdownLinkTextViewDelegate = usesSwiftUICoordinator
            ? PickyMarkdownInlineTextView.Coordinator()
            : PickyMarkdownLinkTextViewDelegate()
        var failures: [PickyMarkdownLinkFailure] = []
        var opened = false
        delegate.linkContext = PickyMarkdownLinkContext(
            workingDirectory: root.path,
            onFailure: { failures.append($0) }
        )
        delegate.openFile = { _ in opened = true; return true }
        let link = try markdownLink("missing.html")
        #expect(delegate.textView(NSTextView(), clickedOnLink: link, at: 0))
        #expect(!opened)
        #expect(failures == [.missingFile(root.appendingPathComponent("missing.html").standardizedFileURL.path)])
    }

    @Test func reusedMarkdownUsesTheCurrentSessionsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = PickyMarkdownLinkTextViewDelegate()
        var opened: [URL] = []
        delegate.openFile = { opened.append($0); return true }
        let link = try markdownLink("result.html")
        for folder in ["one", "two"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("result.html")
            try "<html></html>".write(to: file, atomically: true, encoding: .utf8)
            delegate.linkContext = PickyMarkdownLinkContext(
                workingDirectory: directory.path,
                onFailure: { _ in Issue.record("Existing file must open") }
            )
            #expect(delegate.textView(NSTextView(), clickedOnLink: link, at: 0))
            #expect(opened.last?.path == file.standardizedFileURL.path)
        }
        #expect(opened.count == 2)
    }

    @Test func relativeLinksWithoutDirectoryDoNotUseTheProcessDirectory() throws {
        var failures: [PickyMarkdownLinkFailure] = []
        let context = PickyMarkdownLinkContext(onFailure: { failures.append($0) })
        let link = try markdownLink("result.html")
        #expect(context.handle(link, openFile: { _ in Issue.record("Must not open an unresolved URL"); return true }))
        #expect(failures == [.unresolvedPath("result.html")])
    }

    @Test func failedFileOpeningReportsTheResolvedPath() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        try "<html></html>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var failures: [PickyMarkdownLinkFailure] = []
        let context = PickyMarkdownLinkContext(onFailure: { failures.append($0) })
        #expect(context.handle(file, openFile: { _ in false }))
        #expect(failures == [.cannotOpen(file.standardizedFileURL.path)])
    }

    @Test(arguments: ["https://example.com/review?q=hello%20world#summary", "mailto:reader@example.com"])
    func webAndMailLinksKeepTheSystemHandler(destination: String) throws {
        let delegate = PickyMarkdownLinkTextViewDelegate()
        delegate.linkContext = PickyMarkdownLinkContext(onFailure: { _ in Issue.record("Not a local link") })
        delegate.openFile = { _ in Issue.record("Not a local file"); return false }
        #expect(!delegate.textView(NSTextView(), clickedOnLink: try markdownLink(destination), at: 0))
    }

    private func markdownLink(_ destination: String) throws -> URL {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("[report](\(destination))")
        ])
        return try #require(attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
    }
}
