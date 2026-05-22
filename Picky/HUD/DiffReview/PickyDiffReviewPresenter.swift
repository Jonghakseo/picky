//
//  PickyDiffReviewPresenter.swift
//  Picky
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class PickyDiffReviewPresenter {
    static let shared = PickyDiffReviewPresenter()

    private final class ReviewRecord {
        let sessionID: String
        let repoRoot: URL
        let host: PickyDiffReviewWebHost
        let controller: PickyDiffReviewWindowController
        var watcher: PickyDiffReviewRepoWatcher?
        var data: ReviewWindowData
        var didServeInitialData = false
        var isSettled = false
        let onCancel: () -> Void
        var fileMap: [String: ReviewFile]
        var commitFileCache: [String: [ReviewFile]] = [:]
        var contentCache: [String: ReviewFileContents] = [:]

        init(
            sessionID: String,
            repoRoot: URL,
            host: PickyDiffReviewWebHost,
            controller: PickyDiffReviewWindowController,
            data: ReviewWindowData,
            onCancel: @escaping () -> Void
        ) {
            self.sessionID = sessionID
            self.repoRoot = repoRoot
            self.host = host
            self.controller = controller
            self.data = data
            self.onCancel = onCancel
            self.fileMap = Dictionary(uniqueKeysWithValues: data.files.map { ($0.id, $0) })
        }

        func clearRefreshableCaches() {
            contentCache.removeAll()
            commitFileCache = commitFileCache.filter { !PickyDiffReviewGit.isWorkingTreeCommitSha($0.key) }
        }

        func clearWorkingTreeCaches() {
            commitFileCache = commitFileCache.filter { !PickyDiffReviewGit.isWorkingTreeCommitSha($0.key) }
            contentCache = contentCache.filter { !$0.key.contains(PickyDiffReviewGit.workingTreeCommitSha) }
        }
    }

    private var records: [String: ReviewRecord] = [:]
    private var settingsStore = PickySettingsStore()

    private init() {}

    func configure(settingsStore: PickySettingsStore) {
        self.settingsStore = settingsStore
    }

    func open(
        sessionID: String,
        cwd: String,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        if let existing = records[sessionID] {
            focus(existing)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let cwdURL = URL(fileURLWithPath: NSString(string: cwd).standardizingPath, isDirectory: true)
            let repoRoot: URL
            do {
                repoRoot = try await PickyDiffReviewGit.resolveRepoRoot(cwd: cwdURL)
            } catch {
                notify(title: "Review unavailable", body: "Not a git repository at \(cwd).")
                onCancel()
                return
            }

            let reviewData: ReviewWindowData
            do {
                reviewData = try await PickyDiffReviewGit.loadReviewWindowData(cwd: cwdURL)
            } catch {
                notify(title: "Review failed", body: error.localizedDescription)
                onCancel()
                return
            }

            guard !reviewData.files.isEmpty || !reviewData.commits.isEmpty else {
                notify(title: "No reviewable files found", body: repoRoot.path)
                onCancel()
                return
            }

            guard records[sessionID] == nil else {
                focus(records[sessionID]!)
                return
            }

            let host = PickyDiffReviewWebHost(
                onMessage: { [weak self] message in
                    guard let self, let record = self.records[sessionID] else { return }
                    self.handle(message, record: record, onSubmit: onSubmit)
                },
                onClose: { [weak self] in
                    guard let self, let record = self.records[sessionID] else { return }
                    self.handleClose(record: record, shouldCancel: true)
                }
            )
            let title = "Pickle review — \(repoRoot.lastPathComponent)"
            let controller = PickyDiffReviewWindowController(
                host: host,
                title: title,
                frame: PickyDiffReviewWindowController.targetFrame(),
                framePersister: PickyDetachedPanelFramePersister.backed(by: settingsStore, kind: .diffReviewWindow),
                onClose: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                        guard let self, let record = self.records[sessionID] else { return }
                        self.handleClose(record: record, shouldCancel: true)
                    }
                }
            )

            let createdRecord = ReviewRecord(
                sessionID: sessionID,
                repoRoot: repoRoot,
                host: host,
                controller: controller,
                data: reviewData,
                onCancel: onCancel
            )
            records[sessionID] = createdRecord

            createdRecord.watcher = PickyDiffReviewRepoWatcher(
                repoRoot: repoRoot,
                onChange: { [weak createdRecord] in
                    guard let createdRecord else { return }
                    createdRecord.clearWorkingTreeCaches()
                    createdRecord.host.send(.workingTreeChanged(changedAt: Date().millisecondsSince1970))
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.notify(title: "Review change watcher failed", body: error.localizedDescription)
                    }
                }
            )

            host.loadInitialPage()
            focus(createdRecord)
        }
    }

    func close(sessionID: String) {
        guard let record = records[sessionID] else { return }
        handleClose(record: record, shouldCancel: false)
    }

    private func handle(_ message: PickyDiffReviewWebHostMessage, record: ReviewRecord, onSubmit: @escaping (String) -> Void) {
        switch message {
        case .requestReviewData(let requestId):
            Task { [weak self, weak record] in
                guard let self, let record else { return }
                await self.handleRequestReviewData(requestId: requestId, record: record)
            }
        case .requestCommit(let requestId, let sha):
            Task { [weak self, weak record] in
                guard let self, let record else { return }
                await self.handleRequestCommit(requestId: requestId, sha: sha, record: record)
            }
        case .requestFile(let requestId, let fileId, let scope, let commitSha):
            Task { [weak self, weak record] in
                guard let self, let record else { return }
                await self.handleRequestFile(requestId: requestId, fileId: fileId, scope: scope, commitSha: commitSha, record: record)
            }
        case .clipboardRead(let requestId):
            handleClipboardRead(requestId: requestId, record: record)
        case .clipboardWrite(let text):
            PickyDiffReviewClipboard.write(text)
        case .submit(let payload):
            if PickyDiffReviewPrompt.hasFeedback(payload) {
                let prompt = PickyDiffReviewPrompt.compose(files: Array(record.fileMap.values), payload: payload)
                onSubmit(prompt)
            }
            handleClose(record: record, shouldCancel: false)
        case .cancel, .close:
            handleClose(record: record, shouldCancel: true)
        }
    }

    private func handleRequestReviewData(requestId: String, record: ReviewRecord) async {
        if !record.didServeInitialData {
            record.didServeInitialData = true
            sendReviewData(record.data, requestId: requestId, host: record.host)
            return
        }

        do {
            let data = try await PickyDiffReviewGit.loadReviewWindowData(cwd: record.repoRoot)
            record.clearRefreshableCaches()
            record.data = data
            for file in data.files {
                record.fileMap[file.id] = file
            }
            sendReviewData(data, requestId: requestId, host: record.host)
        } catch {
            record.host.send(.reviewDataError(requestId: requestId, message: error.localizedDescription))
        }
    }

    private func handleRequestCommit(requestId: String, sha: String, record: ReviewRecord) async {
        if let files = record.commitFileCache[sha] {
            record.host.send(.commitData(requestId: requestId, sha: sha, files: files))
            return
        }

        do {
            let files = try await PickyDiffReviewGit.loadCommitFiles(repoRoot: record.repoRoot, sha: sha)
            record.commitFileCache[sha] = files
            for file in files {
                record.fileMap[file.id] = file
            }
            record.host.send(.commitData(requestId: requestId, sha: sha, files: files))
        } catch {
            record.host.send(.commitError(requestId: requestId, sha: sha, message: error.localizedDescription))
        }
    }

    private func handleRequestFile(requestId: String, fileId: String, scope: ReviewScope, commitSha: String?, record: ReviewRecord) async {
        guard let file = record.fileMap[fileId] else {
            record.host.send(.fileError(requestId: requestId, fileId: fileId, scope: scope, commitSha: commitSha, message: "Unknown file requested."))
            return
        }

        let cacheKey = "\(scope.rawValue):\(commitSha ?? ""):\(fileId)"
        if let contents = record.contentCache[cacheKey] {
            record.host.send(.fileData(requestId: requestId, fileId: fileId, scope: scope, commitSha: commitSha, contents: contents))
            return
        }

        do {
            let contents = try await PickyDiffReviewGit.loadFileContents(
                repoRoot: record.repoRoot,
                file: file,
                scope: scope,
                commitSha: commitSha,
                branchMergeBaseSha: record.data.branchMergeBaseSha
            )
            record.contentCache[cacheKey] = contents
            record.host.send(.fileData(requestId: requestId, fileId: fileId, scope: scope, commitSha: commitSha, contents: contents))
        } catch {
            record.host.send(.fileError(requestId: requestId, fileId: fileId, scope: scope, commitSha: commitSha, message: error.localizedDescription))
        }
    }

    private func handleClipboardRead(requestId: String, record: ReviewRecord) {
        let text = PickyDiffReviewClipboard.read()
        record.host.send(.clipboardData(requestId: requestId, text: text, message: nil))
    }

    private func sendReviewData(_ data: ReviewWindowData, requestId: String, host: PickyDiffReviewWebHost) {
        host.send(.reviewData(
            requestId: requestId,
            files: data.files,
            commits: data.commits,
            branchBaseRef: data.branchBaseRef,
            branchMergeBaseSha: data.branchMergeBaseSha,
            repositoryHasHead: data.repositoryHasHead
        ))
    }

    private func handleClose(record: ReviewRecord, shouldCancel: Bool) {
        guard records[record.sessionID] === record else { return }
        record.host.dispose()
        records.removeValue(forKey: record.sessionID)
        record.watcher?.dispose()
        record.watcher = nil
        record.commitFileCache.removeAll()
        record.contentCache.removeAll()
        if !record.isSettled {
            record.isSettled = true
            if shouldCancel {
                record.onCancel()
            }
        }
        if record.controller.window?.isVisible == true {
            record.controller.close()
        }
    }

    private func focus(_ record: ReviewRecord) {
        NSApp.activate(ignoringOtherApps: true)
        record.controller.window?.orderFrontRegardless()
        record.controller.window?.makeKey()
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(280))
        content.sound = nil
        let request = UNNotificationRequest(identifier: "picky-diff-review-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

private extension Date {
    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000.0).rounded())
    }
}
