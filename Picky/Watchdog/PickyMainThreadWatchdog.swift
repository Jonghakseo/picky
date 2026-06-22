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
    enum SuspensionReason: Hashable {
        case displaySleep
        case screenLock
    }

    // MARK: - Configuration

    private let clock: () -> Date
    private let threshold: TimeInterval
    private let softStallThreshold: TimeInterval
    private let grace: TimeInterval
    private let sleepCooldown: TimeInterval

    // MARK: - Tunable seams (mutable so tests can wire after construction)

    var startedAt: Date
    var onSpinDetected: () -> Void
    var onSoftStallDetected: (_ age: TimeInterval, _ threshold: TimeInterval) -> Void
    var onSoftStallRecovered: (_ age: TimeInterval) -> Void

    // MARK: - State (lock-protected, touched from both main and utility queue)

    private let lock = NSLock()
    private var _heartbeatAt: Date?
    /// Tracks the heartbeat that the last fired spin was anchored to.
    /// Prevents repeat firing across the same stale window: the next spin
    /// can only fire after a fresh heartbeat (or a wake reset) advances
    /// `_heartbeatAt` to a new value.
    private var _lastSpinFiredHeartbeatAt: Date?
    /// Tracks the heartbeat that produced the last soft-stall log. This keeps
    /// diagnostics useful without spamming OSLog every second while the main
    /// thread remains pinned in the same stale window.
    private var _lastSoftStallFiredHeartbeatAt: Date?
    /// The stale heartbeat currently considered a soft stall. A later heartbeat
    /// clears it and emits a single recovery log with the total stale age.
    private var _activeSoftStallHeartbeatAt: Date?
    /// Reasons that make the main run loop an invalid responsiveness signal.
    /// Display sleep and screen lock can pause WindowServer-driven callbacks
    /// while the app is otherwise healthy, so the utility poller must stand
    /// down until every reason has cleared.
    private var _suspensionReasons: Set<SuspensionReason> = []

    // MARK: - Run-loop / poll handles

    private var observer: CFRunLoopObserver?
    private var pollTimer: DispatchSourceTimer?
    private var mainHeartbeatTimer: DispatchSourceTimer?

    // MARK: - Init

    init(
        clock: @escaping () -> Date = Date.init,
        threshold: TimeInterval = 10,
        softStallThreshold: TimeInterval = 2,
        grace: TimeInterval = 30,
        sleepCooldown: TimeInterval = 5,
        onSpinDetected: @escaping () -> Void
    ) {
        self.clock = clock
        self.threshold = threshold
        self.softStallThreshold = softStallThreshold
        self.grace = grace
        self.sleepCooldown = sleepCooldown
        self.onSpinDetected = onSpinDetected
        self.onSoftStallDetected = Self.defaultSoftStallDetected(age:threshold:)
        self.onSoftStallRecovered = Self.defaultSoftStallRecovered(age:)
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

        // Drive a 1Hz heartbeat from the main queue. The CFRunLoopObserver
        // above only refreshes when the loop wakes/sleeps around an event;
        // a UIElement app that sits idle in `mach_msg` for >threshold gets
        // no callbacks and looks spun even though main is healthy. This
        // timer guarantees a heartbeat as long as the main queue can drain.
        // If main is actually pegged, the timer won't fire either and the
        // utility poller still detects the stale heartbeat.
        let mainTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        mainTimer.schedule(deadline: .now() + 1, repeating: 1)
        mainTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.heartbeat(at: self.clock())
        }
        mainTimer.resume()
        self.mainHeartbeatTimer = mainTimer

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
        mainHeartbeatTimer?.cancel()
        mainHeartbeatTimer = nil
    }

    /// Notifies the watchdog that the system just woke from sleep. Pushes the
    /// heartbeat reference forward by `sleepCooldown` so the catch-up window
    /// after wake isn't mistaken for a spin.
    func noteWoke(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        _heartbeatAt = date.addingTimeInterval(sleepCooldown)
        _lastSpinFiredHeartbeatAt = nil
        _lastSoftStallFiredHeartbeatAt = nil
        _activeSoftStallHeartbeatAt = nil
    }

    /// Temporarily disables spin detection while macOS is expected to pause or
    /// heavily throttle main-thread UI callbacks without indicating a real app
    /// hang, such as display sleep or the login-window screen lock.
    func suspendMonitoring(for reason: SuspensionReason, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        _suspensionReasons.insert(reason)
        _heartbeatAt = date
        _lastSpinFiredHeartbeatAt = nil
        _lastSoftStallFiredHeartbeatAt = nil
        _activeSoftStallHeartbeatAt = nil
    }

    /// Re-enables spin detection for `reason`. The final resume gets the same
    /// cooldown treatment as system wake so post-unlock display/layout catch-up
    /// does not immediately look like a stale main-thread heartbeat.
    func resumeMonitoring(for reason: SuspensionReason, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        _suspensionReasons.remove(reason)
        if _suspensionReasons.isEmpty {
            _heartbeatAt = date.addingTimeInterval(sleepCooldown)
            _lastSpinFiredHeartbeatAt = nil
            _lastSoftStallFiredHeartbeatAt = nil
            _activeSoftStallHeartbeatAt = nil
        } else {
            _heartbeatAt = date
        }
    }

    // MARK: - Internal seams (called by run loop / poll timer / tests)

    func heartbeat(at date: Date) {
        var recoveredAge: TimeInterval?

        lock.lock()
        if let activeSoftStallHeartbeatAt = _activeSoftStallHeartbeatAt,
           let heartbeatAt = _heartbeatAt,
           activeSoftStallHeartbeatAt == heartbeatAt,
           date > heartbeatAt {
            recoveredAge = date.timeIntervalSince(heartbeatAt)
            _activeSoftStallHeartbeatAt = nil
        }
        _heartbeatAt = date
        lock.unlock()

        if let recoveredAge {
            onSoftStallRecovered(recoveredAge)
        }
    }

    func checkForSpin(at date: Date) {
        var shouldFire = false
        var softStallAge: TimeInterval?

        lock.lock()
        let heartbeatAt = _heartbeatAt ?? startedAt
        let age = date.timeIntervalSince(heartbeatAt)
        if _suspensionReasons.isEmpty,
           date.timeIntervalSince(startedAt) >= grace {
            if softStallThreshold > 0,
               _lastSoftStallFiredHeartbeatAt != heartbeatAt,
               age > softStallThreshold {
                _lastSoftStallFiredHeartbeatAt = heartbeatAt
                _activeSoftStallHeartbeatAt = heartbeatAt
                softStallAge = age
            }
            if _lastSpinFiredHeartbeatAt != heartbeatAt,
               age > threshold {
                _lastSpinFiredHeartbeatAt = heartbeatAt
                shouldFire = true
            }
        }
        lock.unlock()

        if let softStallAge {
            onSoftStallDetected(softStallAge, softStallThreshold)
        }
        if shouldFire { onSpinDetected() }
    }

    private static func defaultSoftStallDetected(age: TimeInterval, threshold: TimeInterval) {
        PickyLog.notice(
            .watchdog,
            prefix: "🎯 Picky watchdog:",
            message: "main thread soft stall detected ageMs=\(milliseconds(age)) thresholdMs=\(milliseconds(threshold))"
        )
    }

    private static func defaultSoftStallRecovered(age: TimeInterval) {
        PickyLog.notice(
            .watchdog,
            prefix: "🎯 Picky watchdog:",
            message: "main thread soft stall recovered ageMs=\(milliseconds(age))"
        )
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }
}
