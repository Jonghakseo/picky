//
//  PickyMainThreadWatchdog.swift
//  Picky
//
//  Watches the main thread for unresponsiveness ("spin") by refreshing a
//  heartbeat from a CFRunLoopObserver on every run-loop tick and polling
//  for staleness from a utility queue. When the heartbeat is older than
//  `threshold`, the watchdog fires `onSpinDetected` once — the responder
//  layer decides what to do (capture sample, prompt user, restart).
//

import Foundation

final class PickyMainThreadWatchdog {
    // MARK: - Configuration

    private let clock: () -> Date
    private let threshold: TimeInterval
    private let grace: TimeInterval
    private let sleepCooldown: TimeInterval

    // MARK: - Tunable seams (mutable so tests can wire after construction)

    var startedAt: Date
    var onSpinDetected: () -> Void

    // MARK: - State (lock-protected, touched from both main and utility queue)

    private let lock = NSLock()
    private var _heartbeatAt: Date?
    /// Tracks the heartbeat that the last fired spin was anchored to.
    /// Prevents repeat firing across the same stale window: the next spin
    /// can only fire after a fresh heartbeat (or a wake reset) advances
    /// `_heartbeatAt` to a new value.
    private var _lastSpinFiredHeartbeatAt: Date?

    // MARK: - Run-loop / poll handles

    private var observer: CFRunLoopObserver?
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Init

    init(
        clock: @escaping () -> Date = Date.init,
        threshold: TimeInterval = 5,
        grace: TimeInterval = 30,
        sleepCooldown: TimeInterval = 5,
        onSpinDetected: @escaping () -> Void
    ) {
        self.clock = clock
        self.threshold = threshold
        self.grace = grace
        self.sleepCooldown = sleepCooldown
        self.onSpinDetected = onSpinDetected
        self.startedAt = clock()
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        // RunLoop observer refreshes heartbeat on every tick. `.commonModes`
        // includes `eventTracking` so heartbeat keeps updating during normal
        // mouse drags; a spin that holds the main thread inside a single
        // event handler (e.g. TextKit `enumerateSubstringsFromLocation`)
        // suppresses these callbacks and the heartbeat goes stale.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
            true,
            0
        ) { [weak self] _, _ in
            guard let self else { return }
            self.heartbeat(at: self.clock())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer

        // Poll from a utility queue at 1Hz. Spin pegs the main thread but
        // utility QoS still runs, so we can detect staleness independent
        // of whatever holds main.
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.jonghakseo.picky.watchdog", qos: .utility)
        )
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkForSpin(at: self.clock())
        }
        timer.resume()
        self.pollTimer = timer
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Notifies the watchdog that the system just woke from sleep. Pushes the
    /// heartbeat reference forward by `sleepCooldown` so the catch-up window
    /// after wake isn't mistaken for a spin.
    func noteWoke(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        _heartbeatAt = date.addingTimeInterval(sleepCooldown)
        _lastSpinFiredHeartbeatAt = nil
    }

    // MARK: - Internal seams (called by run loop / poll timer / tests)

    func heartbeat(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        _heartbeatAt = date
    }

    func checkForSpin(at date: Date) {
        lock.lock()
        let heartbeatAt = _heartbeatAt ?? startedAt
        let lastFired = _lastSpinFiredHeartbeatAt
        lock.unlock()

        // Within initial grace window — too early to judge.
        if date.timeIntervalSince(startedAt) < grace { return }
        // Already fired against this stale heartbeat reference.
        if lastFired == heartbeatAt { return }
        // Heartbeat is fresh enough.
        if date.timeIntervalSince(heartbeatAt) <= threshold { return }

        lock.lock()
        _lastSpinFiredHeartbeatAt = heartbeatAt
        lock.unlock()

        onSpinDetected()
    }
}
