import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyToolCallPulsingDotTests {
    @Test
    func pulseDoesNotAnimateParentLayoutPosition() async throws {
        // The parent and pulse appear in one transaction, matching a live tool row
        // that shifts when the conversation finishes its initial layout.
        let host = NSHostingView(rootView: PickyToolCallPulseLayoutProbe())
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 360)
        host.layoutSubtreeIfNeeded()

        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(rasterize(host))
        let blueCenter = try #require(colorCenter(in: bitmap, matching: .blue))
        let redCenter = try #require(colorCenter(in: bitmap, matching: .red))

        #expect(abs(blueCenter.y - redCenter.y) <= 2)
    }

    private func rasterize(_ host: NSHostingView<PickyToolCallPulseLayoutProbe>) -> NSBitmapImageRep? {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func colorCenter(
        in bitmap: NSBitmapImageRep,
        matching target: TargetColor
    ) -> CGPoint? {
        var points: [CGPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let matches = switch target {
                case .blue:
                    blue - max(red, green) > 0.18
                case .red:
                    red - max(green, blue) > 0.18
                }
                if matches {
                    points.append(CGPoint(x: x, y: y))
                }
            }
        }
        guard !points.isEmpty else { return nil }
        return CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
    }
}

private enum TargetColor {
    case blue
    case red
}

private struct PickyToolCallPulseLayoutProbe: View {
    @State private var moved = false

    var body: some View {
        VStack(spacing: 0) {
            if moved {
                Color.clear.frame(height: 240)
            }
            HStack(spacing: 12) {
                PickyToolCallPulsingDot(color: .blue)
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 80, height: 360, alignment: .top)
        .background(Color.white)
        .onAppear {
            moved = true
        }
    }
}
