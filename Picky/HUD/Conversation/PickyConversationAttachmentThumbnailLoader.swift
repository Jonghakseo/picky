//
//  PickyConversationAttachmentThumbnailLoader.swift
//  Picky
//
//  Loads and caches 64px attachment thumbnails for composer image chips.
//

import AppKit
import Foundation
import ImageIO

// MARK: - Cache policy

nonisolated enum PickyConversationAttachmentThumbnailPolicy {
    /// Maximum pixel size for the generated attachment thumbnail.
    static let thumbnailMaxPixelSize = 64

    struct CacheKey: Hashable {
        let standardizedPath: String
        let modificationVersion: Int64

        /// Deterministic cache key used by the loader map.
        var keyString: String {
            "\(standardizedPath)|\(modificationVersion)"
        }
    }

    static func cacheKey(for path: String, modificationDate: Date) -> CacheKey {
        let standardizedPath = standardizeURL(URL(fileURLWithPath: path)).path
        return CacheKey(standardizedPath: standardizedPath, modificationVersion: modificationVersion(for: modificationDate))
    }

    static func cacheKey(for url: URL) -> CacheKey? {
        guard url.isFileURL else { return nil }

        let standardizedURL = standardizeURL(url)
        guard let modificationDate = try? standardizedURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else {
            return nil
        }

        return cacheKey(for: standardizedURL.path, modificationDate: modificationDate)
    }

    static func standardizePath(_ path: String) -> String {
        standardizeURL(URL(fileURLWithPath: path)).path
    }

    static func standardizeURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func modificationVersion(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}

// MARK: - Thumbnail loader

/// Not an `ObservableObject` on purpose: publishing one shared dictionary made
/// every chip re-evaluate its body whenever any other thumbnail finished
/// decoding. Chips await their own thumbnail and keep it in local state.
@MainActor
final class PickyConversationAttachmentThumbnailLoader {
    static let shared = PickyConversationAttachmentThumbnailLoader()

    /// Bounds memory for long sessions that attach many images.
    static let cacheCountLimit = 64

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = PickyConversationAttachmentThumbnailLoader.cacheCountLimit
        return cache
    }()

    private var inFlightTasks: [PickyConversationAttachmentThumbnailPolicy.CacheKey: Task<NSImage?, Never>] = [:]

    /// Returns the thumbnail for a file URL, decoding it off the main actor on a
    /// cache miss. Concurrent requests for the same file share one decode.
    func thumbnail(for attachmentURL: URL) async -> NSImage? {
        guard attachmentURL.isFileURL,
              let key = PickyConversationAttachmentThumbnailPolicy.cacheKey(for: attachmentURL) else {
            return nil
        }

        let cacheKey = key.keyString as NSString
        if let cached = cache.object(forKey: cacheKey) {
            PickyPerf.event("attachment_thumbnail_cache_hit")
            return cached
        }

        if let existingTask = inFlightTasks[key] {
            PickyPerf.event("attachment_thumbnail_cache_hit")
            return await existingTask.value
        }

        PickyPerf.event("attachment_thumbnail_cache_miss")

        let standardizedURL = PickyConversationAttachmentThumbnailPolicy.standardizeURL(attachmentURL)
        let loadTask = Task { [weak self] () -> NSImage? in
            defer { self?.inFlightTasks[key] = nil }

            let decodeTask = Task.detached(priority: .utility) { [standardizedURL] in
                PickyPerf.interval("attachment_thumbnail_decode") {
                    Self.decodeCGImage(for: standardizedURL)
                }
            }

            let decodedImage = await withTaskCancellationHandler(
                operation: { await decodeTask.value },
                onCancel: { decodeTask.cancel() }
            )

            guard let decodedImage else { return nil }

            // NSImage creation and publish happen on MainActor.
            let image = NSImage(
                cgImage: decodedImage,
                size: NSSize(width: decodedImage.width, height: decodedImage.height)
            )
            self?.cache.setObject(image, forKey: cacheKey)
            return image
        }

        inFlightTasks[key] = loadTask
        return await loadTask.value
    }

    private nonisolated static func decodeCGImage(for url: URL) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: PickyConversationAttachmentThumbnailPolicy.thumbnailMaxPixelSize,
        ]

        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }
}
