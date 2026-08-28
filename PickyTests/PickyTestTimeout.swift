import Foundation
import Testing

struct PickyTestTimeoutError: Error, CustomStringConvertible {
    let operation: String
    let timeout: Duration

    var description: String {
        "Timed out waiting for \(operation) after \(timeout)."
    }
}

private final class PickyTestTimeoutRace<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completion: Result<Value, Error>?
    private var bodyTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<Value, Error>,
        operation: String,
        timeout: Duration,
        body: @escaping () async throws -> Value
    ) {
        install(continuation)

        let bodyTask = Task {
            do {
                resolve(.success(try await body()))
            } catch {
                resolve(.failure(error))
            }
        }
        installBodyTask(bodyTask)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                resolve(.failure(PickyTestTimeoutError(operation: operation, timeout: timeout)))
            } catch {
                // The body or caller completed first and cancelled the timer.
            }
        }
        installTimeoutTask(timeoutTask)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) {
        let completed = lock.withLock { () -> Result<Value, Error>? in
            if let completion { return completion }
            self.continuation = continuation
            return nil
        }
        if let completed {
            continuation.resume(with: completed)
        }
    }

    private func installBodyTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard completion == nil else { return true }
            bodyTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    private func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard completion == nil else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    private func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> (
            CheckedContinuation<Value, Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        )? in
            guard completion == nil else { return nil }
            completion = result
            let pending = (continuation, bodyTask, timeoutTask)
            continuation = nil
            bodyTask = nil
            timeoutTask = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel()
        pending.2?.cancel()
        pending.0?.resume(with: result)
    }
}

func withPickyTestTimeout<Value>(
    _ operation: String,
    timeout: Duration = .seconds(2),
    _ body: @escaping () async throws -> Value
) async throws -> Value {
    let race = PickyTestTimeoutRace<Value>()
    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            race.start(
                continuation: continuation,
                operation: operation,
                timeout: timeout,
                body: body
            )
        }
    }, onCancel: {
        race.cancel()
    })
}

@Suite
struct PickyTestTimeoutTests {
    @Test func timeoutReturnsWithoutWaitingForANonCooperativeBody() async {
        do {
            try await withPickyTestTimeout(
                "non-cooperative test body",
                timeout: .milliseconds(20)
            ) {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
            Issue.record("Expected timeout")
        } catch let error as PickyTestTimeoutError {
            #expect(error.operation == "non-cooperative test body")
        } catch {
            Issue.record("Expected PickyTestTimeoutError, got \(error)")
        }
    }
}
