import AppKit
import QuartzCore
import SwiftUI

/// Rasterizes a SwiftUI view for the render gallery.
///
/// The destination bitmap keeps a logical `size` smaller than its pixel grid,
/// so the written PNG carries 144 dpi and image viewers show the artifact at
/// its true point size instead of magnifying it to twice the intended size.
///
/// Detail is still bounded by the offscreen host: an `NSHostingView` without a
/// window composites its layer contents at `contentsScale == 1`, and neither
/// `ImageRenderer` nor a PDF draw is a usable replacement. `ImageRenderer`
/// ignores the host `NSAppearance` and fills AppKit-backed production views
/// with placeholder color; `dataWithPDF(inside:)` drops layer-drawn surfaces
/// and symbols. Fidelity to the production view wins over extra sharpness.
enum PickyRenderGalleryRasterizer {
    @MainActor
    static func rasterize(
        _ content: some View,
        logicalSize: CGSize,
        scale: CGFloat,
        appearance: NSAppearance.Name
    ) -> NSBitmapImageRep? {
        let pixelWidth = Int((logicalSize.width * scale).rounded(.up))
        let pixelHeight = Int((logicalSize.height * scale).rounded(.up))
        let host = NSHostingView(rootView: AnyView(content))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: logicalSize.width, height: logicalSize.height)
        host.layoutSubtreeIfNeeded()
        applyContentsScale(scale, to: host.layer)
        defer { host.rootView = AnyView(EmptyView()) }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = logicalSize
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private static func applyContentsScale(_ scale: CGFloat, to layer: CALayer?) {
        guard let layer else { return }
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { applyContentsScale(scale, to: $0) }
    }
}
