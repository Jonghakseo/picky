//
//  PickyDaemonLogFile.swift
//  Picky
//
//  Size-capped log file shared by the agentd and gateway launchers, plus the
//  relay that moves child process output onto the main actor in batches.
//

import Darwin
import Foundation

/// Append-only log file with size-based rotation.
///
/// The file descriptor stays open for the writer's lifetime and is replaced
/// only when the file rotates. The size limit is judged from the file itself
/// (`fstat`), never from a per-instance byte counter, so several writers on
/// one path (the primary launcher and each Pickle's child launcher all write
/// `agentd.stdout.log`) still keep the file under its cap. Descriptors are
/// opened with `O_APPEND`, so concurrent writers cannot overwrite each other.
/// A writer whose path was rotated by another writer notices the new inode and
/// reopens instead of rotating a second time.
nonisolated final class PickyRotatingLogFile: @unchecked Sendable {
    private let url: URL
    private let maxSize: Int64
    private let maxRotations: Int
    private let fileManager: FileManager
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    /// - Parameter maxSize: Rotate once the live file reaches this many bytes. `0` disables rotation.
    /// - Parameter maxRotations: Backups kept next to the live file. `0` truncates without history.
    init(url: URL, maxSize: Int64, maxRotations: Int, fileManager: FileManager = .default) {
        self.url = url
        self.maxSize = maxSize
        self.maxRotations = max(maxRotations, 0)
        self.fileManager = fileManager
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard prepareDescriptor() else { return }
        data.withUnsafeBytes { buffer in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    // The descriptor is unusable (for example the disk is full or the
                    // file was removed underneath us). Drop it so the next append reopens.
                    closeDescriptor()
                    return
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
    }

    /// Releases the descriptor. A later `append` reopens the file.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeDescriptor()
    }

    // MARK: - Private (call with the lock held)

    private func prepareDescriptor() -> Bool {
        if descriptor >= 0 {
            if pathStillPointsAtDescriptor() {
                guard shouldRotate() else { return true }
                rotate()
            }
            // Either another writer rotated the path or we just did; start on the new file.
            closeDescriptor()
        }
        descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        // The file may have been at or over the cap before this writer opened it
        // (a previous launch, or another writer that has not rotated yet).
        if shouldRotate() {
            rotate()
            closeDescriptor()
            descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        return descriptor >= 0
    }

    private func shouldRotate() -> Bool {
        guard maxSize > 0, descriptor >= 0 else { return false }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return Int64(info.st_size) >= maxSize
    }

    private func pathStillPointsAtDescriptor() -> Bool {
        var onDisk = stat()
        var opened = stat()
        guard stat(url.path, &onDisk) == 0, fstat(descriptor, &opened) == 0 else { return false }
        return onDisk.st_ino == opened.st_ino && onDisk.st_dev == opened.st_dev
    }

    /// Shifts `<file>.N` to `<file>.N+1`, drops the oldest, and moves the live file to `<file>.1`.
    private func rotate() {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard maxRotations >= 1 else {
            try? fileManager.removeItem(at: url)
            return
        }
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(name).\(maxRotations)"))
        for index in stride(from: maxRotations - 1, through: 1, by: -1) {
            let from = directory.appendingPathComponent("\(name).\(index)")
            let to = directory.appendingPathComponent("\(name).\(index + 1)")
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try? fileManager.removeItem(at: to)
            try? fileManager.moveItem(at: from, to: to)
        }
        let firstBackup = directory.appendingPathComponent("\(name).1")
        try? fileManager.removeItem(at: firstBackup)
        try? fileManager.moveItem(at: url, to: firstBackup)
    }

    private func closeDescriptor() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

/// Hands child process output to the main actor in batches.
///
/// `Pipe` readability handlers run on a background queue, and the launchers'
/// state is main-actor isolated. Hopping with one `Task` per chunk both costs
/// a task per read and gives no ordering guarantee, so chunks are queued under
/// a lock and a single main-actor drain delivers everything queued so far in
/// arrival order. A call that already happens on the main thread delivers
/// synchronously (after anything still queued), which keeps launches driven
/// from the main actor deterministic.
nonisolated final class PickyDaemonOutputRelay: @unchecked Sendable {
    typealias Sink = @MainActor (Data) -> Void

    private let lock = NSLock()
    private var pending = Data()
    private var drainScheduled = false
    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        if Thread.isMainThread {
            let batch = takePending(appending: data)
            MainActor.assumeIsolated { sink(batch) }
            return
        }
        lock.lock()
        pending.append(data)
        let needsDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        guard needsDrain else { return }
        Task { @MainActor [self] in
            let batch = self.finishDrain()
            if !batch.isEmpty { self.sink(batch) }
        }
    }

    private func takePending(appending data: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var batch = pending
        pending = Data()
        batch.append(data)
        return batch
    }

    private func finishDrain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let batch = pending
        pending = Data()
        drainScheduled = false
        return batch
    }
}
