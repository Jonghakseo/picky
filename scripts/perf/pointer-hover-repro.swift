// Reproduces NSTrackingArea enter delivery for a Picky-like HUD panel while
// the process is not the active app. It moves the real cursor for about 25
// seconds, so keep the mouse and keyboard idle while it runs.
//
//   swiftc -O scripts/perf/pointer-hover-repro.swift -o /tmp/pointer-hover-repro
//   /tmp/pointer-hover-repro baseline
//   /tmp/pointer-hover-repro global-mouse-moved      # NSEvent global monitor
//   /tmp/pointer-hover-repro listen-tap              # listen-only CGEventTap
//   /tmp/pointer-hover-repro global-mouse-moved active
//
// Each run reports how many of 28 row entries produced `mouseEntered` within
// 300 ms ("prompt"), later ("late", usually at the next pointer movement), or
// never before the next row ("none"). Posting events needs Accessibility for
// the launching terminal. See docs/perf-profiling.md (2026-10 dock hover case).
import AppKit

let variant = CommandLine.arguments.dropFirst().first ?? "baseline"
let makeActive = CommandLine.arguments.contains("active")

let rowCount = 8, rowHeight: CGFloat = 26, rowGap: CGFloat = 1, padding: CGFloat = 10, rowWidth: CGFloat = 158
let panelSize = NSSize(width: rowWidth + 2 * padding, height: padding * 2 + CGFloat(rowCount) * (rowHeight + rowGap))
let panelOrigin = NSPoint(x: 120, y: 260)

let lock = NSLock()
var enters: [(row: Int, time: UInt64)] = []

final class RowView: NSView {
    var index = 0
    var hovered = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func mouseEntered(with event: NSEvent) {
        lock.lock(); enters.append((index, mach_absolute_time())); lock.unlock()
        hovered = true
    }

    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        (hovered ? NSColor.systemBlue : NSColor.darkGray).setFill()
        bounds.fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = NSPanel(contentRect: NSRect(origin: panelOrigin, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = NSWindow.Level(rawValue: 19)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hidesOnDeactivate = false
let root = NSView(frame: NSRect(origin: .zero, size: panelSize))
for index in 0..<rowCount {
    let y = panelSize.height - padding - CGFloat(index) * (rowHeight + rowGap) - rowHeight
    let row = RowView(frame: NSRect(x: padding, y: y, width: rowWidth, height: rowHeight))
    row.index = index
    root.addSubview(row)
}
panel.contentView = root
panel.orderFrontRegardless()

var keepAlive: [Any] = []
let movementMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
switch variant {
case "global-mouse-moved":
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: movementMask, handler: { _ in }) { keepAlive.append(monitor) }
case "listen-tap":
    let mask = (CGEventMask(1) << CGEventType.mouseMoved.rawValue) | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                      callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil),
          let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        print("listen-only tap creation failed"); exit(2)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    keepAlive.append(tap)
case "baseline":
    break
default:
    print("unknown variant \(variant)"); exit(2)
}
if makeActive { app.activate(ignoringOtherApps: true) } else { app.deactivate() }

let mainScreenHeight = NSScreen.screens[0].frame.height
func rowRect(_ index: Int) -> CGRect {
    let cocoaTop = panelOrigin.y + panelSize.height - padding - CGFloat(index) * (rowHeight + rowGap)
    return CGRect(x: panelOrigin.x + padding, y: mainScreenHeight - cocoaTop, width: rowWidth, height: rowHeight)
}
func move(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

Thread.detachNewThread {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    func milliseconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }
    var cursor = CGPoint(x: panelOrigin.x + padding + rowWidth / 2, y: rowRect(0).midY)
    move(cursor)
    usleep(900_000)
    var trials: [(row: Int, time: UInt64)] = []
    let forward = Array(1..<rowCount), backward = Array((0..<(rowCount - 1)).reversed())
    for target in forward + backward + forward + backward {
        let rect = rowRect(target), start = cursor.y
        let steps = max(1, Int(abs(rect.midY - start) / 3))
        for step in 1...steps {
            cursor.y = start + (rect.midY - start) * CGFloat(step) / CGFloat(steps)
            move(cursor)
            if rect.insetBy(dx: 0, dy: 0.5).contains(cursor) { trials.append((target, mach_absolute_time())); break }
            usleep(8_000)
        }
        cursor.y = rect.midY
        move(cursor)
        usleep(800_000)
    }
    lock.lock(); let recorded = enters; lock.unlock()
    var prompt: [Double] = [], late = 0, none = 0
    for (offset, trial) in trials.enumerated() {
        let nextTrial = offset + 1 < trials.count ? trials[offset + 1].time : UInt64.max
        guard let hit = recorded.first(where: { $0.row == trial.row && $0.time >= trial.time && $0.time < nextTrial }) else { none += 1; continue }
        let latency = milliseconds(hit.time - trial.time)
        if latency > 300 { late += 1 } else { prompt.append(latency) }
    }
    prompt.sort()
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let selfFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    if !makeActive && selfFront { print("INVALID: this process became frontmost, so the inactive condition did not hold") }
    if idleSeconds < 25 { print(String(format: "WARNING: a key was pressed %.0fs ago; the run may include user input", idleSeconds)) }
    print(String(format: "%@%@ front=%@ trials=%d prompt=%d late=%d none=%d prompt_p50=%.1fms",
                 variant, makeActive ? " [active]" : "", front, trials.count, prompt.count, late, none,
                 prompt.isEmpty ? -1 : prompt[prompt.count / 2]))
    exit(0)
}
app.run()
