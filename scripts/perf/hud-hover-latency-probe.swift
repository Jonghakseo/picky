// Measures, from the outside, how long a running Picky HUD takes to show a
// dock row's hover after the cursor enters the row. It never restarts Picky:
// it reads row frames through Accessibility, glides the real cursor between
// rows, and samples each row's leading padding until its pixels change.
//
//   swiftc -O scripts/perf/hud-hover-latency-probe.swift -o /tmp/hud-hover-latency-probe
//   /tmp/hud-hover-latency-probe <picky-pid> [rows=8] [csv=/tmp/hud-hover.csv] [label-suffix]
//
// The default label suffix matches the Korean dock-row accessibility label
// ("... 열거나 닫기"); pass the localized suffix for other languages. Keep the
// mouse and keyboard idle for about 25 seconds. The terminal needs
// Accessibility (AX reads, event posting) and Screen Recording (pixels).
//
// Each CSV row records the probe's `mach_absolute_time` at row entry, so it can
// be aligned with an xctrace recording: subtract the trace's `time-info`
// `mabs-epoch` and multiply by the timebase. `secs_since_key` separates idle
// trials from trials where someone typed. Rows that are already selected show
// no hover change and report an empty `first_ms`. Compare runs with Picky
// frontmost and with another app frontmost; see docs/perf-profiling.md.
import AppKit
import ApplicationServices

typealias WindowCapture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
// CGWindowListCreateImage is unavailable to new Swift code but still exported;
// a 6pt sample every ~15 ms is enough here and avoids a ScreenCaptureKit stream.
let windowCapture = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"), to: WindowCapture.self)

let arguments = Array(CommandLine.arguments.dropFirst())
guard let pidArgument = arguments.first, let pid = pid_t(pidArgument) else {
    print("usage: hud-hover-latency-probe <picky-pid> [rows=8] [csv-path] [label-suffix]"); exit(2)
}
let maxRows = arguments.count > 1 ? Int(arguments[1]) ?? 8 : 8
let csvPath = arguments.count > 2 ? arguments[2] : "/tmp/hud-hover.csv"
let labelSuffix = arguments.count > 3 ? arguments[3] : "열거나 닫기"

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func frame(of element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}
var rowFrames: [(String, CGRect)] = []
func collectRows(_ element: AXUIElement, depth: Int) {
    guard depth < 30 else { return }
    let label = (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
    if (attribute(element, kAXRoleAttribute) as? String) == "AXButton", label.hasSuffix(labelSuffix) {
        rowFrames.append((String(label.prefix(16)), frame(of: element)))
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { collectRows(child, depth: depth + 1) }
}
// Picky has one HUD panel per display; use the one with the most visible rows.
let windows = (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
var rows: [(String, CGRect)] = []
for window in windows {
    rowFrames = []
    collectRows(window, depth: 0)
    let visibleWindow = frame(of: window).insetBy(dx: 0, dy: 40)
    let onScreen = NSScreen.screens.map { screen -> CGRect in
        let f = screen.frame
        return CGRect(x: f.minX, y: NSScreen.screens[0].frame.height - f.maxY, width: f.width, height: f.height)
    }
    let visible = rowFrames.filter { row in visibleWindow.contains(row.1) && onScreen.contains { $0.contains(row.1) } }
    if visible.count > rows.count { rows = Array(visible.prefix(maxRows)) }
}
guard rows.count >= 2 else { print("found \(rows.count) visible dock rows; open the dock and retry"); exit(2) }
print("rows:", rows.map { "\($0.0)@\(Int($0.1.minY))" }.joined(separator: ", "))

func nowMilliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
func move(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func meanColor(_ rect: CGRect) -> [Double] {
    guard let image = windowCapture(rect, 1, 0, 8)?.takeRetainedValue(),
          let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [0, 0, 0] }
    var sum = [0.0, 0.0, 0.0], count = 0.0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
            for channel in 0..<3 { sum[channel] += Double(bytes[offset + channel]) }
            count += 1
        }
    }
    return sum.map { $0 / max(count, 1) }
}
func distance(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }

var cursor = CGPoint(x: rows[0].1.midX, y: rows[0].1.midY)
move(cursor)
usleep(700_000)
var csv = ["mabs_enter,first_ms,settled_ms,delta,secs_since_key,from,to"]
var firstVisible: [Double] = []

func trial(from: Int, to: Int) {
    let target = rows[to].1
    let sample = CGRect(x: target.minX + 1.5, y: target.midY - 3, width: 3, height: 6)
    let baseline = meanColor(sample)
    let start = cursor.y, steps = max(1, Int(abs(target.midY - start) / 3))
    var enteredAt = nowMilliseconds(), enteredMach: UInt64 = 0
    for step in 1...steps {
        cursor.y = start + (target.midY - start) * CGFloat(step) / CGFloat(steps)
        move(cursor)
        if target.insetBy(dx: 0, dy: 0.5).contains(cursor) { enteredAt = nowMilliseconds(); enteredMach = mach_absolute_time(); break }
        usleep(8_000)
    }
    var first: Double?, last = baseline, lastChange = enteredAt, finalDelta = 0.0
    while nowMilliseconds() - enteredAt < 600 {
        let color = meanColor(sample)
        if first == nil && distance(color, baseline) > 2 { first = nowMilliseconds() }
        if distance(color, last) > 0.8 { lastChange = nowMilliseconds(); last = color; finalDelta = distance(color, baseline) }
        if first != nil && nowMilliseconds() - lastChange > 150 { break }
    }
    if let first { firstVisible.append(first - enteredAt) }
    let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    csv.append([
        "\(enteredMach)",
        first.map { String(format: "%.1f", $0 - enteredAt) } ?? "",
        String(format: "%.1f", lastChange - enteredAt),
        String(format: "%.1f", finalDelta),
        String(format: "%.2f", sinceKey),
        "\(from)", "\(to)",
    ].joined(separator: ","))
    cursor.y = target.midY
    move(cursor)
    usleep(200_000)
}

let forward = Array(1..<rows.count), backward = Array((0..<(rows.count - 1)).reversed())
var current = 0
for target in forward + backward + forward + backward {
    trial(from: current, to: target)
    current = target
}
try csv.joined(separator: "\n").write(toFile: csvPath, atomically: true, encoding: .utf8)
let sorted = firstVisible.sorted()
func percentile(_ p: Double) -> String { sorted.isEmpty ? "-" : String(format: "%.0f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) }
let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
print("front=\(front) visible=\(sorted.count)/\(csv.count - 1) first_ms p50=\(percentile(0.5)) p90=\(percentile(0.9)) max=\(percentile(1)) csv=\(csvPath)")
