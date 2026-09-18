import Foundation
import Darwin

enum PickyCronPromptReadResult: Equatable {
    case loaded(String), missing, unreadable, unsafePath, tooLarge
}

struct PickyCronInstructions: Equatable {
    let result: PickyCronPromptReadResult
    var isHistorical = false
}

struct PickyCronJobContentReader {
    let cronDirectory: URL
    static let maximumPromptBytes = 256 * 1024

    func readInstructions(for job: PickyCronJobPresentation, executionDate: Date? = nil) -> PickyCronInstructions {
        if let executionDate {
            let historical = readPrompt(for: job, executionDate: executionDate)
            if historical != .missing { return .init(result: historical, isHistorical: true) }
        }
        return .init(result: readPrompt(for: job))
    }

    func readPrompt(for job: PickyCronJobPresentation, executionDate: Date? = nil) -> PickyCronPromptReadResult {
        let path: String?
        if let executionDate {
            // Never present today's instructions as an historical execution snapshot.
            path = job.executions.first { $0.date == executionDate }?.promptFile
        } else {
            path = job.promptFile
        }
        guard let path else { return .missing }
        return PickyCronLocalFile.read(path: path, root: cronDirectory, limit: Self.maximumPromptBytes)
    }
}

/// Walk directory descriptors rather than following symlinks between validation and open.
/// No prompt or log content escapes this boundary until its size and UTF-8 are checked.
enum PickyCronLocalFile {
    static func read(path: String, root: URL, limit: Int, prefixOnly: Bool = false) -> PickyCronPromptReadResult {
        guard !path.contains("\0"), path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { return .unsafePath }
        let rootPath = root.standardizedFileURL.path
        guard let resolved = realpath(root.path, nil) else { return errno == ENOENT ? .missing : .unreadable }
        let canonicalRoot = String(cString: resolved)
        free(resolved)
        let relative: String
        if path.hasPrefix(rootPath + "/") {
            relative = String(path.dropFirst(rootPath.count + 1))
        } else if path.hasPrefix(canonicalRoot + "/") {
            relative = String(path.dropFirst(canonicalRoot.count + 1))
        } else { return .unsafePath }
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else { return .unsafePath }
        var descriptor = open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        defer { close(descriptor) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < components.count - 1 ? O_DIRECTORY : 0)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else {
                if errno == ENOENT { return .missing }
                if errno == ELOOP || errno == ENOTDIR { return .unsafePath }
                return .unreadable
            }
            close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .unsafePath }
        if !prefixOnly && info.st_size > limit { return .tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: limit + (prefixOnly ? 0 : 1)) else { return .unreadable }
        if !prefixOnly && data.count > limit { return .tooLarge }
        // A prefix can end inside a UTF-8 sequence in private output; only headers are consumed.
        if prefixOnly { return .loaded(String(decoding: data, as: UTF8.self)) }
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .loaded(text)
    }
}
