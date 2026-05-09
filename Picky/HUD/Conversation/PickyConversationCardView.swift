//
//  PickyConversationCardView.swift
//  Picky
//
//  Core conversation-style side-agent card container.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PickyConversationCardView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard
    var onArchiveSession: (String) -> Void = { _ in }
    /// Max height the card may grow to before its inner ScrollView starts handling
    /// overflow. Driven by `PickyHUDPlacement.availableCardMaxHeight` so the card
    /// adapts to whatever space remains below the dock's top edge on this monitor.
    /// Defaults to the historical fixed cap for previews/tests that don't wire a
    /// placement provider.
    var maxHeight: CGFloat = PickyHUDPlacement.defaultAvailableCardMaxHeight
    var isPreviewMode = false
    @State private var droppedFilePaths: [String] = []
    @State private var isFileDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickyConversationHeaderView(viewModel: viewModel, session: session, onArchiveSession: onArchiveSession)
            PickyConversationContextLineView(session: session)
            PickyConversationListView(session: session, viewModel: viewModel)
            PickyConversationComposerView(
                session: session,
                viewModel: viewModel,
                droppedFilePaths: $droppedFilePaths,
                isFileDropTargeted: isFileDropTargeted
            )
        }
        .frame(width: PickyHUDDockLayout.detailContentWidth, alignment: .topLeading)
        .padding(.horizontal, PickyHUDDockLayout.detailHorizontalPadding)
        .padding(.vertical, 12)
        .frame(width: PickyHUDDockLayout.detailWidth)
        // Max height comes from PickyHUDPlacement (per-panel, reactive). When the
        // user drags the dock anchor the conversation card grows or shrinks within
        // whatever space remains below the dock's top edge, instead of clipping at
        // a hardcoded 1080. PickyConversationListView's ScrollView absorbs anything
        // taller than this cap.
        .frame(minHeight: 320, maxHeight: maxHeight, alignment: .top)
        // During first hover the NSPanel grows after SwiftUI reports the measured
        // content size. Without clipping, children can render past the temporary
        // card frame while ScrollView/TextEditor settle into their final layout.
        .clipped()
        .background(cardBackground)
        .contentShape(Rectangle())
        .onDrop(of: PickyConversationFileDrop.acceptedTypeIdentifiers, isTargeted: $isFileDropTargeted, perform: handleFileDrop)
        .onHover(perform: updateVoiceFollowUpHover)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter(PickyConversationFileDrop.acceptsDrop)
        guard !fileProviders.isEmpty else { return false }

        Task {
            let paths = await PickyConversationFileDrop.filePaths(from: fileProviders)
            guard !paths.isEmpty else { return }
            await MainActor.run {
                droppedFilePaths.append(contentsOf: paths)
            }
        }
        return true
    }

    func updateVoiceFollowUpHover(_ hovering: Bool) {
        if hovering {
            viewModel.beginHoveredVoiceFollowUp(sessionID: session.id)
        } else {
            viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(cardBackgroundOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(cardBorderColor, lineWidth: isFileDropTargeted ? 1.3 : 1)
            )
            .shadow(color: .black.opacity(cardShadowOpacity), radius: PickyHUDExpansion.cardShadowRadius, y: PickyHUDExpansion.cardShadowYOffset)
    }

    private var cardBackgroundOpacity: Double {
        isPreviewMode ? 0.82 : 0.95
    }

    private var cardShadowOpacity: Double {
        PickyHUDExpansion.cardShadowOpacity * (isPreviewMode ? 0.45 : 1)
    }

    private var cardBorderColor: Color {
        if isFileDropTargeted { return DS.Colors.accentText.opacity(0.85) }
        return statusColor.opacity(isPreviewMode ? 0.28 : 0.58)
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .completed:
            return DS.Colors.success
        case .waiting_for_input:
            return DS.Colors.warning
        case .failed:
            return DS.Colors.destructiveText
        case .blocked:
            return DS.Colors.warningText
        case .queued, .cancelled:
            return DS.Colors.textTertiary
        }
    }
}

enum PickyConversationFileDrop {
    static let fileURLType = UTType.fileURL.identifier
    static let imageType = UTType.image.identifier
    static let acceptedTypeIdentifiers = [fileURLType, imageType]

    private static let preferredImageTypeIdentifiers = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.tiff.identifier,
    ]

    static func acceptsDrop(_ provider: NSItemProvider) -> Bool {
        acceptsFileURL(provider) || imageTypeIdentifier(for: provider) != nil
    }

    static func acceptsFileURL(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(fileURLType)
    }

    static func filePaths(from providers: [NSItemProvider], destinationDirectory: URL? = nil) async -> [String] {
        var paths: [String] = []
        for provider in providers {
            if let path = await filePath(from: provider) {
                paths.append(path)
                continue
            }
            if let path = await imageFilePath(from: provider, destinationDirectory: destinationDirectory) {
                paths.append(path)
            }
        }
        return paths
    }

    private static func filePath(from provider: NSItemProvider) async -> String? {
        guard acceptsFileURL(provider) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: filePath(fromDropItem: item))
            }
        }
    }

    private static func imageFilePath(from provider: NSItemProvider, destinationDirectory: URL?) async -> String? {
        guard let typeIdentifier = imageTypeIdentifier(for: provider) else { return nil }
        if let path = await imageFilePathFromFileRepresentation(
            provider,
            typeIdentifier: typeIdentifier,
            destinationDirectory: destinationDirectory
        ) {
            return path
        }
        if let path = await imageFilePathFromDataRepresentation(
            provider,
            typeIdentifier: typeIdentifier,
            destinationDirectory: destinationDirectory
        ) {
            return path
        }
        return await imageFilePathFromItem(
            provider,
            typeIdentifier: typeIdentifier,
            destinationDirectory: destinationDirectory
        )
    }

    private static func imageFilePathFromFileRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        destinationDirectory: URL?
    ) async -> String? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
                guard error == nil, let sourceURL else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let destinationURL = try copyImageFile(
                        from: sourceURL,
                        typeIdentifier: typeIdentifier,
                        suggestedName: suggestedName,
                        destinationDirectory: destinationDirectory
                    )
                    continuation.resume(returning: destinationURL.path)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func imageFilePathFromDataRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        destinationDirectory: URL?
    ) async -> String? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                guard error == nil, let data else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let destinationURL = try writeImageData(
                        data,
                        typeIdentifier: typeIdentifier,
                        suggestedName: suggestedName,
                        destinationDirectory: destinationDirectory
                    )
                    continuation.resume(returning: destinationURL.path)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func imageFilePathFromItem(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        destinationDirectory: URL?
    ) async -> String? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    if let sourceURL = fileURL(fromDropItem: item) {
                        let destinationURL = try copyImageFile(
                            from: sourceURL,
                            typeIdentifier: typeIdentifier,
                            suggestedName: suggestedName,
                            destinationDirectory: destinationDirectory
                        )
                        continuation.resume(returning: destinationURL.path)
                        return
                    }
                    guard let data = imageData(fromDropItem: item) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let destinationURL = try writeImageData(
                        data,
                        typeIdentifier: typeIdentifier,
                        suggestedName: suggestedName,
                        destinationDirectory: destinationDirectory
                    )
                    continuation.resume(returning: destinationURL.path)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
        for typeIdentifier in preferredImageTypeIdentifiers where provider.registeredTypeIdentifiers.contains(typeIdentifier) {
            return typeIdentifier
        }
        if let registeredImageType = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }) {
            return registeredImageType
        }
        return provider.hasItemConformingToTypeIdentifier(imageType) ? imageType : nil
    }

    private static func filePath(fromDropItem item: Any?) -> String? {
        if let url = fileURL(fromDropItem: item) { return url.path }
        if let string = item as? String { return filePath(fromDropString: string) }
        if let string = item as? NSString { return filePath(fromDropString: string as String) }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url.path
            }
            if let string = String(data: data, encoding: .utf8) {
                return filePath(fromDropString: string)
            }
        }
        return nil
    }

    private static func fileURL(fromDropItem item: Any?) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, url.isFileURL { return url as URL }
        return nil
    }

    private static func imageData(fromDropItem item: Any?) -> Data? {
        if let data = item as? Data { return data }
        if let image = item as? NSImage,
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData) {
            return bitmap.representation(using: .png, properties: [:])
        }
        return nil
    }

    private static func copyImageFile(
        from sourceURL: URL,
        typeIdentifier: String,
        suggestedName: String?,
        destinationDirectory: URL?
    ) throws -> URL {
        let destinationURL = try makeDestinationURL(
            typeIdentifier: typeIdentifier,
            suggestedName: suggestedName,
            sourceURL: sourceURL,
            destinationDirectory: destinationDirectory
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func writeImageData(
        _ data: Data,
        typeIdentifier: String,
        suggestedName: String?,
        destinationDirectory: URL?
    ) throws -> URL {
        let destinationURL = try makeDestinationURL(
            typeIdentifier: typeIdentifier,
            suggestedName: suggestedName,
            sourceURL: nil,
            destinationDirectory: destinationDirectory
        )
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private static func makeDestinationURL(
        typeIdentifier: String,
        suggestedName: String?,
        sourceURL: URL?,
        destinationDirectory: URL?
    ) throws -> URL {
        let directory = try preparedDestinationDirectory(destinationDirectory)
        let basename = sanitizedBaseName(from: suggestedName)
        let filenameExtension = preferredFilenameExtension(
            typeIdentifier: typeIdentifier,
            suggestedName: suggestedName,
            sourceURL: sourceURL
        )
        return directory.appendingPathComponent("\(basename)-\(UUID().uuidString).\(filenameExtension)")
    }

    private static func preparedDestinationDirectory(_ destinationDirectory: URL?) throws -> URL {
        let directory = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PickyDroppedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sanitizedBaseName(from suggestedName: String?) -> String {
        guard let suggestedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suggestedName.isEmpty else {
            return "picky-drop"
        }
        let lastPathComponent = (suggestedName as NSString).lastPathComponent
        let base = (lastPathComponent as NSString).deletingPathExtension
        let rawBase = base.isEmpty ? lastPathComponent : base
        let invalidCharacters = CharacterSet(charactersIn: "/\\:\0").union(.newlines)
        let cleaned = rawBase.components(separatedBy: invalidCharacters).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "picky-drop" }
        return String(cleaned.prefix(80))
    }

    private static func preferredFilenameExtension(typeIdentifier: String, suggestedName: String?, sourceURL: URL?) -> String {
        let candidates = [
            sourceURL?.pathExtension,
            suggestedName.map { ($0 as NSString).pathExtension },
            UTType(typeIdentifier)?.preferredFilenameExtension,
            "png",
        ]
        for candidate in candidates {
            if let sanitizedExtension = sanitizedFilenameExtension(candidate) {
                return sanitizedExtension
            }
        }
        return "png"
    }

    private static func sanitizedFilenameExtension(_ filenameExtension: String?) -> String? {
        guard let filenameExtension = filenameExtension?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filenameExtension.isEmpty else {
            return nil
        }
        let cleaned = filenameExtension.filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(12)).lowercased()
    }

    private static func filePath(fromDropString string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        if let url = URL(string: trimmed), url.isFileURL { return url.path }
        if trimmed.hasPrefix("/") { return trimmed }
        return nil
    }
}
