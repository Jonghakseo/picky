//
//  PickyDiffReviewRepoWatcher.swift
//  Picky
//

import CoreServices
import Foundation

final class PickyDiffReviewRepoWatcher {
    static let ignoredPathSegments: Set<String> = [
        ".cache",
        ".git",
        ".hg",
        ".next",
        ".nuxt",
        ".svn",
        ".turbo",
        "build",
        "coverage",
        "dist",
        "node_modules",
        "out",
        "target",
        "tmp",
    ]

    static let ignoredFileNames: Set<String> = [".DS_Store"]

    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let onError: ((Error) -> Void)?
    private var disposed = false

    init(repoRoot: URL, debounceMs: Int = 2000, onChange: @escaping () -> Void, onError: ((Error) -> Void)? = nil) {
        self.onChange = onChange
        self.onError = onError

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [repoRoot.standardizedFileURL.path] as CFArray
        let callback: FSEventStreamCallback = { _, contextInfo, eventCount, eventPaths, _, _ in
            guard let contextInfo else { return }
            let watcher = Unmanaged<PickyDiffReviewRepoWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
            guard !watcher.disposed else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let hasRelevantChange = paths.prefix(eventCount).contains { !PickyDiffReviewRepoWatcher.isIgnoredWatchPath($0) }
            guard hasRelevantChange else { return }
            DispatchQueue.main.async {
                guard !watcher.disposed else { return }
                watcher.onChange()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CFTimeInterval(Double(debounceMs) / 1000.0),
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            onError?(PickyDiffReviewRepoWatcherError.creationFailed(repoRoot.standardizedFileURL.path))
            return
        }

        self.stream = stream
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if !FSEventStreamStart(stream) {
            onError?(PickyDiffReviewRepoWatcherError.startFailed(repoRoot.standardizedFileURL.path))
            dispose()
        }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        dispose()
    }

    static func isIgnoredWatchPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        if normalized.isEmpty { return false }

        let segments = normalized.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if segments.contains(where: { ignoredPathSegments.contains($0) }) { return true }

        let fileName = segments.last ?? normalized
        if ignoredFileNames.contains(fileName) { return true }
        if fileName.hasSuffix("~") || fileName.hasSuffix(".swp") || fileName.hasSuffix(".tmp") { return true }

        return false
    }
}

private enum PickyDiffReviewRepoWatcherError: LocalizedError {
    case creationFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let path):
            return "Failed to create review change watcher for \(path)."
        case .startFailed(let path):
            return "Failed to start review change watcher for \(path)."
        }
    }
}
