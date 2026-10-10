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
    /// Local state, so a chip re-renders only for its own thumbnail.
    @State private var thumbnail: NSImage?

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
            .help(L10n.t("hud.attachment.remove"))
            .accessibilityLabel(L10n.t("hud.attachment.removeNamed", attachment.displayName))
            .hoverAffordance()
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5))
        .help(attachment.path)
        .task(id: attachment.url) {
            guard attachment.isImage else {
                thumbnail = nil
                return
            }
            let image = await PickyConversationAttachmentThumbnailLoader.shared.thumbnail(for: attachment.url)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let image = thumbnail {
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

/// Horizontally scrolling chip row for composer attachments. It owns its own
/// overflow measurement so the editor never re-renders when the row scrolls.
struct PickyComposerAttachmentsRow: View {
    @Binding var attachments: [PickyComposerAttachment]
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.space1) {
                    ForEach(attachments) { attachment in
                        PickyComposerAttachmentChipView(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.horizontal, Self.contentInset)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: AttachmentContentWidthKey.self, value: proxy.size.width)
                    }
                )
            }
            .frame(height: DS.Spacing.space6)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AttachmentViewportWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(AttachmentContentWidthKey.self) { contentWidth = $0 }
            .onPreferenceChange(AttachmentViewportWidthKey.self) { viewportWidth = $0 }
            .mask(scrollMask)
        }
    }

    /// True when the chip row would clip on the right. Drives a small fade mask
    /// at the trailing edge so users see there are more attachments to scroll
    /// into view; collapses to a no-op mask when everything fits.
    var hasOverflow: Bool {
        contentWidth > viewportWidth + Self.overflowTolerance
    }

    private var scrollMask: LinearGradient {
        let fadeStart: Double = hasOverflow ? 0.88 : 1.0
        let trailingOpacity: Double = hasOverflow ? 0 : 1
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: fadeStart),
                .init(color: .black.opacity(trailingOpacity), location: 1.0),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private static let contentInset: CGFloat = 2
    private static let overflowTolerance: CGFloat = 0.5
}
