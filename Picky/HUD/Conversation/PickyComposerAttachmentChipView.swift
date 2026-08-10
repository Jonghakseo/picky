//
//  PickyComposerAttachmentChipView.swift
//  Picky
//
//  Attachment model and chip UI for the conversation composer.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Composer-only attachment representation. The path is still appended to the
/// outgoing message text at submit time so Pi sees the same payload as before;
/// chips just keep paths out of the editor so they can't be split or corrupted
/// by intervening keystrokes.
struct PickyComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }

    var isImage: Bool {
        Self.isImagePath(path)
    }

    static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }
}

/// Width of the chip's HStack contentSize, used to detect horizontal overflow
/// so the trailing fade hint only shows when more chips lie offscreen.
struct AttachmentContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Width of the ScrollView viewport. Paired with AttachmentContentWidthKey.
struct AttachmentViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PickyComposerAttachmentChipView: View {
    let attachment: PickyComposerAttachment
    let onRemove: () -> Void
    @ObservedObject private var thumbnailLoader = PickyConversationAttachmentThumbnailLoader.shared

    var body: some View {
        HStack(spacing: 5) {
            leading
            Text(attachment.displayName)
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .pickyFont(size: 8, weight: .bold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
            .accessibilityLabel("Remove attachment \(attachment.displayName)")
            .hoverAffordance()
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5))
        .help(attachment.path)
        .task(id: attachment.url) {
            guard attachment.isImage else { return }
            _ = thumbnailLoader.loadThumbnail(for: attachment.url)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let image = thumbnailLoader.thumbnail(for: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .pickyFont(size: 10, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 16, height: 16)
        }
    }
}
