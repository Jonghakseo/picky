//
//  PickyWatchdogSampleStoreTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyWatchdogSampleStore")
struct PickyWatchdogSampleStoreTests {
    private final class FakeRunner: PickyWatchdogSampleStore.ProcessRunner {
        private(set) var invocations: [(pid: Int32, duration: Int, outputPath: URL)] = []
        var shouldFail = false

        func runSample(pid: Int32, duration: Int, outputPath: URL) throws {
            invocations.append((pid, duration, outputPath))
            if shouldFail { throw NSError(domain: "FakeRunner", code: 1) }
            // Simulate sample writing a file.
            try Data("sample stub".utf8).write(to: outputPath)
        }
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picky-sample-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeContext(
        trigger: PickyWatchdogCaptureContext.Trigger = .softStall,
        heartbeatAgeAtStart: TimeInterval = 2.5,
        stallStartedAt: Date? = Date(timeIntervalSinceReferenceDate: 0)
    ) -> PickyWatchdogCaptureContext {
        PickyWatchdogCaptureContext(
            trigger: trigger,
            heartbeatAgeAtStart: heartbeatAgeAtStart,
            stallStartedAt: stallStartedAt
        )
    }

    private func idleLoad() -> PickyWatchdogSystemLoad {
        PickyWatchdogSystemLoad(
            loadAverage1: 1.5,
            loadAverage5: 1.4,
            loadAverage15: 1.3,
            processorCount: 10,
            swapUsedBytes: 0,
            swapTotalBytes: 2 * 1_073_741_824
        )
    }

    @Test("capture는 sample 프로세스를 정확한 인자로 호출하고 경로를 반환")
    func captureInvokesRunner() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeRunner()
        var nowCalls = 0
        let store = PickyWatchdogSampleStore(
            directory: dir,
            runner: runner,
            clock: {
                nowCalls += 1
                return Date(timeIntervalSinceReferenceDate: 0)
            }
        )

        let url = try store.capture(pid: 1234, duration: 10, context: makeContext())

        #expect(runner.invocations.count == 1)
        #expect(runner.invocations.first?.pid == 1234)
        #expect(runner.invocations.first?.duration == 10)
        #expect(url.lastPathComponent.hasPrefix("spin-"))
        #expect(url.pathExtension == "txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("capture는 디렉토리가 없으면 생성")
    func captureCreatesDirectoryIfMissing() throws {
        let parent = makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nested = parent.appendingPathComponent("nested/logs", isDirectory: true)
        let runner = FakeRunner()
        let store = PickyWatchdogSampleStore(directory: nested, runner: runner)
        _ = try store.capture(pid: 1, duration: 3, context: makeContext())
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("기본 캡처 길이는 stall 창을 좁게 잡도록 짧게 유지")
    func defaultDurationIsShort() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeRunner()
        let store = PickyWatchdogSampleStore(directory: dir, runner: runner)

        _ = try store.capture(pid: 1, context: makeContext())

        #expect(runner.invocations.first?.duration == PickyWatchdogSampleStore.defaultSampleDuration)
        #expect(PickyWatchdogSampleStore.defaultSampleDuration <= 5)
    }

    @Test("헤더는 stall 맥락과 시스템 부하를 sample 본문 앞에 기록")
    func headerDescribesStallAndLoad() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PickyWatchdogSampleStore(
            directory: dir,
            runner: FakeRunner(),
            clock: { Date(timeIntervalSinceReferenceDate: 100) },
            systemLoad: idleLoad
        )
        store.heartbeatAgeProvider = { 6.0 }

        let url = try store.capture(pid: 1, context: makeContext(heartbeatAgeAtStart: 2.5))
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.hasPrefix("=== Picky watchdog capture context ==="))
        #expect(contents.contains("trigger: softStall"))
        #expect(contents.contains("heartbeatAgeAtCaptureStart: 2.500s"))
        #expect(contents.contains("heartbeatAgeAtCaptureEnd: 6.000s"))
        #expect(contents.contains("stallOutlastedCapture: true"))
        #expect(contents.contains("loadAverage: 1.50"))
        #expect(contents.contains("swap:"))
        // Body is preserved after the header.
        #expect(contents.hasSuffix("sample stub"))
    }

    @Test("캡처 중 회복하면 헤더가 뒷부분이 회복 이후 상태임을 명시")
    func headerFlagsRecoveryDuringCapture() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PickyWatchdogSampleStore(directory: dir, runner: FakeRunner(), systemLoad: idleLoad)
        store.heartbeatAgeProvider = { 0.2 }

        let url = try store.capture(pid: 1, context: makeContext(heartbeatAgeAtStart: 2.5))
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.contains("stallOutlastedCapture: false"))
        #expect(contents.contains("main thread recovered during this capture"))
    }

    @Test("spin 트리거 캡처는 창이 늦을 수 있다고 표시")
    func headerFlagsLateSpinCapture() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PickyWatchdogSampleStore(directory: dir, runner: FakeRunner(), systemLoad: idleLoad)

        let url = try store.capture(pid: 1, context: makeContext(trigger: .spin))
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.contains("trigger: spin"))
        #expect(contents.contains("may trail the stall it reports"))
    }

    @Test("코어당 로드가 1을 넘으면 CPU 기아 가능성을 헤더에 남김")
    func headerFlagsOversubscribedMachine() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let starved = PickyWatchdogSystemLoad(
            loadAverage1: 12.4,
            loadAverage5: 10.0,
            loadAverage15: 12.2,
            processorCount: 10,
            swapUsedBytes: 6_741 * 1_048_576,
            swapTotalBytes: 8_192 * 1_048_576
        )
        let store = PickyWatchdogSampleStore(directory: dir, runner: FakeRunner(), systemLoad: { starved })

        let url = try store.capture(pid: 1, context: makeContext())
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.contains("machine is oversubscribed"))
        #expect(contents.contains("6741M used"))
    }

    @Test("purgeExcess는 spin-*.txt 중 keeping 수를 초과하는 오래된 파일을 삭제")
    func purgeExcessDropsOldest() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PickyWatchdogSampleStore(directory: dir, runner: FakeRunner())

        // Seed 12 files with increasing mtimes.
        let fm = FileManager.default
        var seeded: [URL] = []
        for i in 0..<12 {
            let url = dir.appendingPathComponent("spin-\(String(format: "%02d", i)).txt")
            try Data("payload-\(i)".utf8).write(to: url)
            // Stagger mtimes so sort by date is deterministic.
            let mtime = Date(timeIntervalSinceReferenceDate: TimeInterval(i))
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            seeded.append(url)
        }
        // Drop an unrelated file to verify it's untouched.
        let unrelated = dir.appendingPathComponent("agentd.stdout.log")
        try Data("keep-me".utf8).write(to: unrelated)

        try store.purgeExcess(keeping: 10)

        let remaining = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        // Unrelated file preserved.
        #expect(remaining.contains("agentd.stdout.log"))
        // Only the 10 newest spin files remain (indexes 2..11).
        let spinFiles = remaining.filter { $0.hasPrefix("spin-") }
        #expect(spinFiles.count == 10)
        #expect(spinFiles.contains("spin-11.txt"))
        #expect(spinFiles.contains("spin-02.txt"))
        #expect(!spinFiles.contains("spin-00.txt"))
        #expect(!spinFiles.contains("spin-01.txt"))
    }

    @Test("purgeExcess는 파일 수가 keeping 이하면 아무것도 하지 않음")
    func purgeExcessNoopWhenUnderLimit() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PickyWatchdogSampleStore(directory: dir, runner: FakeRunner())
        for i in 0..<3 {
            let url = dir.appendingPathComponent("spin-\(i).txt")
            try Data("x".utf8).write(to: url)
        }
        try store.purgeExcess(keeping: 10)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining.count == 3)
    }
}
