import AppKit
import Combine
import Foundation

@MainActor
final class DiffReviewStore: ObservableObject {
    @Published private(set) var snapshot: DiffReviewSnapshot
    @Published var selectedFileID: String?
    @Published var viewedFileIDs: Set<String> = []
    @Published var comments: [DiffReviewComment] = []
    @Published var activeCommentTarget: DiffCommentTarget?
    @Published var draftComment = ""
    @Published var overallComment = ""
    @Published var statusMessage: String?
    @Published var searchText = ""
    @Published var wrapLines = true
    @Published var viewMode: DiffViewMode = .unified
    @Published var collapsedFileIDs: Set<String> = []
    @Published var expandedLargeDiffFileIDs: Set<String> = []
    @Published var isSidebarVisible = true
    @Published var isSubmitReviewPresented = false

    let source: DiffReviewSource
    private let loader = DiffReviewSnapshotLoader()

    init(source: DiffReviewSource) {
        self.source = source
        do {
            let loaded = try loader.load(source: source)
            self.snapshot = loaded
            self.selectedFileID = loaded.files.first?.id
        } catch {
            fputs("DiffReviewPlayground load failed: \(error.localizedDescription)\n", stderr)
            self.snapshot = Self.errorSnapshot(message: error.localizedDescription)
            self.selectedFileID = self.snapshot.files.first?.id
            self.statusMessage = error.localizedDescription
        }
    }

    var filteredFiles: [DiffFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return snapshot.files }
        return snapshot.files.filter { $0.displayPath.lowercased().contains(query) }
    }

    var selectedFile: DiffFile? {
        let id = selectedFileID ?? snapshot.files.first?.id
        return snapshot.files.first { $0.id == id }
    }

    var hasFeedback: Bool {
        !overallComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || comments.contains { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func select(_ file: DiffFile) {
        selectedFileID = file.id
        activeCommentTarget = nil
        draftComment = ""
    }

    func reload() {
        do {
            let loaded = try loader.load(source: source)
            snapshot = loaded
            selectedFileID = loaded.files.first { $0.id == selectedFileID }?.id ?? loaded.files.first?.id
            let validIDs = Set(loaded.files.map(\.id))
            viewedFileIDs = viewedFileIDs.intersection(validIDs)
            collapsedFileIDs = collapsedFileIDs.intersection(validIDs)
            expandedLargeDiffFileIDs = expandedLargeDiffFileIDs.intersection(validIDs)
            comments = comments.filter { comment in validIDs.contains(comment.target.fileID) }
            statusMessage = "Reloaded \(loaded.files.count) file\(loaded.files.count == 1 ? "" : "s")"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleViewed(fileID: String) {
        if viewedFileIDs.contains(fileID) {
            viewedFileIDs.remove(fileID)
            collapsedFileIDs.remove(fileID)
        } else {
            viewedFileIDs.insert(fileID)
            collapsedFileIDs.insert(fileID)
        }
    }

    func toggleCollapsed(fileID: String) {
        if collapsedFileIDs.contains(fileID) {
            collapsedFileIDs.remove(fileID)
        } else {
            collapsedFileIDs.insert(fileID)
        }
    }

    func isLargeDiffExpanded(fileID: String) -> Bool {
        expandedLargeDiffFileIDs.contains(fileID)
    }

    func toggleLargeDiffExpanded(fileID: String) {
        if expandedLargeDiffFileIDs.contains(fileID) {
            expandedLargeDiffFileIDs.remove(fileID)
        } else {
            expandedLargeDiffFileIDs.insert(fileID)
        }
    }

    func beginComment(target: DiffCommentTarget) {
        activeCommentTarget = target
        draftComment = ""
    }

    func cancelComment() {
        activeCommentTarget = nil
        draftComment = ""
    }

    func saveDraftComment() {
        guard let target = activeCommentTarget else { return }
        let body = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        comments.append(DiffReviewComment(target: target, body: body))
        activeCommentTarget = nil
        draftComment = ""
    }

    func comments(for target: DiffCommentTarget) -> [DiffReviewComment] {
        comments.filter { $0.target == target }
    }

    func commentCount(fileID: String) -> Int {
        comments.filter { $0.target.fileID == fileID }.count
    }

    func feedbackPrompt() -> String {
        DiffReviewPromptBuilder().build(snapshot: snapshot, overallComment: overallComment, comments: comments)
    }

    func copyFeedbackPrompt() {
        let prompt = feedbackPrompt()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        statusMessage = "Copied feedback prompt"
    }

    private static func errorSnapshot(message: String) -> DiffReviewSnapshot {
        let line = DiffLine(id: "error-line", kind: .metadata, oldNumber: nil, newNumber: nil, text: message)
        let hunk = DiffHunk(id: "error-hunk", header: "@@ Picky diff review playground @@", oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, section: "", lines: [line])
        let file = DiffFile(
            id: "error-file",
            status: .unknown,
            oldPath: nil,
            newPath: "No diff loaded",
            displayPath: "No diff loaded",
            hunks: [hunk],
            metadataLines: [],
            isBinary: false
        )
        return DiffReviewSnapshot(title: "Diff review playground", repoRoot: "", subtitle: "Load failed", files: [file])
    }
}
