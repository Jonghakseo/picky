//
//  PickyFileMentionSearchService.swift
//  Picky
//

import Foundation

nonisolated enum PickyFileMentionSearchService {
    private static let fdPath: String? = {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["PICKY_FD_PATH"],
            NSHomeDirectory() + "/.pi/agent/bin/fd",
            "/opt/homebrew/bin/fd",
            "/usr/local/bin/fd",
            "/usr/bin/fd",
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool {
        fdPath != nil
    }

    static func suggestions(
        for draft: String,
        cwd: String?
    ) async -> [PickyFileMentionAutocompletePolicy.Suggestion] {
        guard let query = PickyFileMentionAutocompletePolicy.query(in: draft),
              let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty,
              let fdPath
        else { return [] }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }

        let scopedQuery = PickyFileMentionAutocompletePolicy.scopedQuery(for: query.rawQuery, cwd: cwd)
        let baseDirectory = scopedQuery?.baseDirectory ?? cwd
        let pattern = scopedQuery?.pattern ?? query.rawQuery
        let displayBase = scopedQuery?.displayBase ?? ""
        let arguments = PickyFileMentionAutocompletePolicy.fdArguments(baseDirectory: baseDirectory, pattern: pattern)
        guard let output = await runFd(at: fdPath, arguments: arguments), !output.isEmpty else { return [] }
        if Task.isCancelled { return [] }

        let lines = output.split(whereSeparator: \Character.isNewline).map(String.init)
        return PickyFileMentionAutocompletePolicy.suggestions(
            fromFdLines: lines,
            pattern: pattern,
            displayBase: displayBase,
            isQuoted: query.isQuoted
        )
    }

    private static func runFd(at path: String, arguments: [String]) async -> String? {
        let state = ProcessState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let process = Process()
                let stdout = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                let output = ProcessOutputBuffer()
                let stdoutHandle = stdout.fileHandleForReading
                stdoutHandle.readabilityHandler = { handle in
                    output.drain(handle)
                }
                process.terminationHandler = { process in
                    stdoutHandle.readabilityHandler = nil
                    output.drain(stdoutHandle)
                    let data = output.data
                    state.clear()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                }

                state.set(process)
                do {
                    try process.run()
                    state.terminateIfCancelled()
                } catch {
                    state.clear()
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func drain(_ handle: FileHandle) {
        lock.lock()
        let data = handle.availableData
        if !data.isEmpty {
            storage.append(data)
        }
        lock.unlock()
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let runningProcess = process?.isRunning == true ? process : nil
        lock.unlock()
        runningProcess?.terminate()
    }

    func terminateIfCancelled() {
        lock.lock()
        let runningProcess = isCancelled && process?.isRunning == true ? process : nil
        lock.unlock()
        runningProcess?.terminate()
    }
}
