//
//  PickyToolImageBubbleView.swift
//  Picky
//
//  Inline thumbnail for an image a tool handed to the model (Pi `read` on an
//  image file). The journal keeps only the local path; this view decodes a
//  downsampled thumbnail off the main actor and sizes itself from the image
//  header up front so the row does not jump when the pixels arrive.
//

import AppKit
import ImageIO
import SwiftUI

struct PickyToolImageBubbleView: View {
    let toolImage: PickyToolImage
    var createdAt: Date? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @State private var thumbnail: NSImage?
    @State private var loadFailed = false

    init(toolImage: PickyToolImage, createdAt: Date? = nil) {
        self.toolImage = toolImage
        self.createdAt = createdAt
        _thumbnail = State(initialValue: PickyToolImageLoader.cachedThumbnail(path: toolImage.path, maxPixel: PickyToolImageLayout.maxThumbnailPixel))
    }

    var body: some View {
        let _ = PickyPerf.event("tool_image_bubble")
        let pixelSize = PickyToolImageLoader.pixelSize(path: toolImage.path)
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                caption
                if let pixelSize {
                    imageButton(displaySize: PickyToolImageLayout.displaySize(pixelSize: pixelSize, maxWidth: maxImageWidth))
                } else {
                    missingPlaceholder
                }
            }
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .task(id: toolImage.path) {
            thumbnail = PickyToolImageLoader.cachedThumbnail(path: toolImage.path, maxPixel: PickyToolImageLayout.maxThumbnailPixel)
            loadFailed = false
            guard pixelSize != nil else { return }
            let path = toolImage.path
            let image = await PickyToolImageLoader.thumbnail(path: path, maxPixel: PickyToolImageLayout.maxThumbnailPixel)
            guard !Task.isCancelled else { return }
            thumbnail = image
            loadFailed = image == nil
        }
        .contextMenu {
            Button(L10n.t("hud.artifacts.action.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            Button(L10n.t("hud.artifacts.action.copyPath")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(toolImage.path, forType: .string)
            }
        }
    }

    private var fileURL: URL { URL(fileURLWithPath: toolImage.path) }

    private var fileName: String { fileURL.lastPathComponent }

    private var maxImageWidth: CGFloat {
        min(
            PickyToolImageLayout.maxWidth,
            PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth)
        )
    }

    private var caption: some View {
        HStack(spacing: DS.Spacing.space1) {
            Image(systemName: "photo")
            Text("hud.toolImage.title")
                .fontWeight(.semibold)
            Text(fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .font(PickyHUDTypography.meta)
        .foregroundColor(DS.Colors.textSecondary)
        .frame(maxWidth: maxImageWidth, alignment: .leading)
        .help(toolImage.path)
    }

    private func imageButton(displaySize: CGSize) -> some View {
        Button {
            NSWorkspace.shared.open(fileURL)
        } label: {
            ZStack {
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .fill(DS.Colors.surface2)
                if let thumbnail {
                    PickyToolImageThumbnailView(image: thumbnail)
                } else if loadFailed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(PickyHUDTypography.labelMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .clipShape(PickyConversationBubbleLayout.bubbleShape(side: .agent))
            .overlay(
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .contentShape(PickyConversationBubbleLayout.bubbleShape(side: .agent))
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .help(L10n.t("hud.toolImage.open.help"))
        .accessibilityLabel(L10n.t("hud.toolImage.accessibilityLabel", fileName))
        .accessibilityHint(L10n.t("hud.toolImage.open.help"))
    }

    private var missingPlaceholder: some View {
        Label {
            Text("hud.toolImage.missing")
        } icon: {
            Image(systemName: "photo.badge.exclamationmark")
        }
        .font(PickyHUDTypography.labelMedium)
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            PickyConversationBubbleLayout.bubbleShape(side: .agent)
                .fill(DS.Colors.surface2)
        )
        .help(toolImage.path)
    }
}

/// AppKit owns thumbnail drawing, like the neighboring markdown bubble surfaces.
/// This also keeps the same pixels available to the windowless render gallery.
private struct PickyToolImageThumbnailView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> PickyToolImageThumbnailNSView {
        PickyToolImageThumbnailNSView()
    }

    func updateNSView(_ view: PickyToolImageThumbnailNSView, context: Context) {
        view.image = image
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PickyToolImageThumbnailNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? image.size.width, height: proposal.height ?? image.size.height)
    }
}

private final class PickyToolImageThumbnailNSView: NSView {
    var image: NSImage?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

enum PickyToolImageLayout {
    static let maxWidth: CGFloat = 280
    static let maxHeight: CGFloat = 220
    static let minSide: CGFloat = 48
    /// 2x the largest display box so Retina screens stay sharp.
    static let maxThumbnailPixel = Int(max(maxWidth, maxHeight) * 2)

    /// Aspect-fit into `maxWidth` x `maxHeight` without upscaling, with a
    /// minimum side so tiny icons stay tappable.
    static func displaySize(pixelSize: CGSize, maxWidth: CGFloat) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: minSide, height: minSide)
        }
        // Screens and screenshots are 2x; show them at point size, not pixel size.
        let pointSize = CGSize(width: pixelSize.width / 2, height: pixelSize.height / 2)
        let scale = min(1, maxWidth / pointSize.width, maxHeight / pointSize.height)
        return CGSize(
            width: max(minSide, (pointSize.width * scale).rounded()),
            height: max(minSide, (pointSize.height * scale).rounded())
        )
    }
}

@MainActor
enum PickyToolImageLoader {
    private static let thumbnails = NSCache<NSString, NSImage>()
    private static let pixelSizes = NSCache<NSString, NSValue>()

    /// Reads only the image header. Cache entries expire when the file changes.
    static func pixelSize(path: String) -> CGSize? {
        let key = cacheKey(path: path, maxPixel: 0) as NSString
        if let cached = pixelSizes.object(forKey: key) { return cached.sizeValue }
        guard let size = readPixelSize(path: path) else { return nil }
        pixelSizes.setObject(NSValue(size: size), forKey: key)
        return size
    }

    private static func readPixelSize(path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // EXIF orientations 5...8 rotate by 90 degrees.
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func cachedThumbnail(path: String, maxPixel: Int) -> NSImage? {
        thumbnails.object(forKey: cacheKey(path: path, maxPixel: maxPixel) as NSString)
    }

    static func thumbnail(path: String, maxPixel: Int) async -> NSImage? {
        let key = cacheKey(path: path, maxPixel: maxPixel) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        // Decode pixels off-actor; create the AppKit object only on MainActor.
        let pixels = await Task.detached(priority: .utility) {
            decodeThumbnail(path: path, maxPixel: maxPixel)
        }.value
        guard let pixels else { return nil }
        let image = NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private nonisolated static func decodeThumbnail(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The modification date keeps a rewritten screenshot at the same path from
    /// showing a stale cached thumbnail.
    private static func cacheKey(path: String, maxPixel: Int) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(path)|\(modified)|\(maxPixel)"
    }
}
