//
//  PickyConversationAttachmentThumbnailLoader.swift
//  Picky
//
//  Loads and caches 64px attachment thumbnails for composer image chips.
//

import AppKit
import Combine
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

@MainActor
final class PickyConversationAttachmentThumbnailLoader: ObservableObject {
    static let shared = PickyConversationAttachmentThumbnailLoader()

    @Published private(set) var thumbnailsByCacheKey: [PickyConversationAttachmentThumbnailPolicy.CacheKey: NSImage] = [:]

    private var inFlightTasks: [PickyConversationAttachmentThumbnailPolicy.CacheKey: Task<Void, Never>] = [:]

    func thumbnail(for attachmentURL: URL) -> NSImage? {
        guard let key = PickyConversationAttachmentThumbnailPolicy.cacheKey(for: attachmentURL) else {
            return nil
        }

        return thumbnailsByCacheKey[key]
    }

    @discardableResult
    func loadThumbnail(for attachmentURL: URL) -> Task<Void, Never> {
        guard attachmentURL.isFileURL,
              let key = PickyConversationAttachmentThumbnailPolicy.cacheKey(for: attachmentURL) else {
            return Task {}
        }

        if thumbnailsByCacheKey[key] != nil {
            PickyPerf.event("attachment_thumbnail_cache_hit")
            return Task {}
        }

        if let existingTask = inFlightTasks[key] {
            PickyPerf.event("attachment_thumbnail_cache_hit")
            return existingTask
        }

        PickyPerf.event("attachment_thumbnail_cache_miss")

        let standardizedURL = PickyConversationAttachmentThumbnailPolicy.standardizeURL(attachmentURL)
        let loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlightTasks[key] = nil }

            if self.thumbnailsByCacheKey[key] != nil {
                PickyPerf.event("attachment_thumbnail_cache_hit")
                return
            }

            let decodeTask = Task.detached(priority: .utility) { [standardizedURL] in
                PickyPerf.interval("attachment_thumbnail_decode") {
                    Self.decodeCGImage(for: standardizedURL)
                }
            }

            let decodedImage = await withTaskCancellationHandler(
                operation: { await decodeTask.value },
                onCancel: { decodeTask.cancel() }
            )

            guard !Task.isCancelled else { return }
            guard let decodedImage else { return }

            // NSImage creation and publish happen on MainActor.
            self.thumbnailsByCacheKey[key] = NSImage(
                cgImage: decodedImage,
                size: NSSize(width: decodedImage.width, height: decodedImage.height)
            )
        }

        inFlightTasks[key] = loadTask
        return loadTask
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
