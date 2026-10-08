//
//  CompanionPanelFeedbackView.swift
//  Picky
//
//  Feedback form rendered inside the Settings tab. Pressing Send stores the
//  submission in the durable outbox and closes the form; collecting
//  diagnostics and posting to Slack happen afterwards in
//  `PickyFeedbackOutboxCenter`, which also owns retries and restart recovery.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PickyFeedbackSendErrorDescription {
    /// Detailed backend failures stay in the diagnostic log; this copy is not
    /// shown to users because Slack codes and transport details are not useful
    /// recovery guidance.
    static func technicalDescription(_ error: Error) -> String {
        if let uncertain = error as? PickyFeedbackDeliveryUncertainError {
            return "Publish outcome unknown. \(technicalDescription(uncertain.underlying))"
        }
        if let outboxError = error as? PickyFeedbackOutboxError {
            return outboxError.technicalDescription
        }
        if let sendError = error as? PickyFeedbackSendError {
            switch sendError {
            case .notConfigured:
                return "Feedback channel not configured."
            case .emptyMessage:
                return "Message is empty."
            case .httpStatus(let code, let detail):
                return "Couldn't send (HTTP \(code) at \(detail))."
            case .slackError(let detail):
                return "Slack rejected the request: \(detail)"
            case .malformedResponse(let detail):
                return "Slack's answer could not be read (\(detail))."
            case .transport(let detail):
                return "Couldn't send. \(detail)"
            }
        }
        if let bundleError = error as? PickyDiagnosticsBundleError {
            switch bundleError {
            case .stagingFailed(let detail), .zipFailed(let detail):
                return "Couldn't package diagnostics: \(detail)"
            }
        }
        return "Couldn't send. \(error.localizedDescription)"
    }

    static func userMessage(_ error: Error) -> String {
        if let uncertain = error as? PickyFeedbackDeliveryUncertainError {
            _ = uncertain
            return L10n.t("feedback.outbox.uncertain.reason")
        }
        if error is PickyFeedbackOutboxError {
            return L10n.t("feedback.outbox.enqueueFailed")
        }
        if error is PickyDiagnosticsBundleError {
            return L10n.t("feedback.sendFailure.diagnostics")
        }
        if let sendError = error as? PickyFeedbackSendError {
            switch sendError {
            case .transport:
                return L10n.t("feedback.sendFailure.connection")
            case .httpStatus(_, let detail) where detail == "upload":
                return L10n.t("feedback.sendFailure.attachment")
            case .notConfigured, .emptyMessage, .httpStatus, .slackError, .malformedResponse:
                return L10n.t("feedback.sendFailure.service")
            }
        }
        return L10n.t("feedback.sendFailure.generic")
    }
}

struct CompanionPanelFeedbackView: View {
    @Environment(\.pickyHubTypographyEnabled) private var usesHubTypography
    @ObservedObject var viewModel: PickySettingsViewModel
    @ObservedObject var outbox: PickyFeedbackOutboxCenter = .shared
    /// Called once the submission is durably stored, not once Slack confirms
    /// it. The host closes the form here.
    var onSubmitted: () -> Void = {}

    @State private var category: PickyFeedbackCategory = .bug
    @State private var message: String = ""
    @State private var selectedMediaAttachments: [SelectedMediaAttachment] = []
    @State private var mediaAttachmentNotice: String?
    @State private var attachmentScope: AttachmentScope = .logsOnly
    @State private var sendState = PickyFeedbackSendStateMachine()
    @State private var statusResetTask: Task<Void, Never>?
    /// Identity of the draft currently on screen. Carrying it into the outbox
    /// makes a repeated Send land on the same job instead of queueing a copy.
    @State private var submissionID = UUID()

    private let isConfigured = PickyFeedbackConfiguration.isConfigured

    private enum MediaAttachmentPolicy {
        static let maxCount = 5
        static let maxFileBytes = 100 * 1_024 * 1_024
        static let maxTotalBytes = 250 * 1_024 * 1_024
    }

    private enum MediaAttachmentKind: Equatable, Sendable {
        case image
        case video
        case file

        var iconName: String {
            switch self {
            case .image: "photo"
            case .video: "video"
            case .file: "doc"
            }
        }
    }

    private struct SelectedMediaAttachment: Identifiable, Equatable, Sendable {
        var url: URL
        var filename: String
        var byteCount: Int
        var kind: MediaAttachmentKind

        var id: String { url.standardizedFileURL.path }
    }

    private enum MediaAttachmentError: LocalizedError {
        case notRegularFile(String)
        case fileTooLarge(String, Int)
        case totalTooLarge(Int)
        case tooMany

        var errorDescription: String? {
            switch self {
            case .notRegularFile(let filename):
                return L10n.t("feedback.attachment.notRegular", filename)
            case .fileTooLarge(let filename, let byteCount):
                return L10n.t("feedback.attachment.tooLarge", filename, Self.format(byteCount), Self.format(MediaAttachmentPolicy.maxFileBytes))
            case .totalTooLarge(let byteCount):
                return L10n.t("feedback.attachment.totalTooLarge", Self.format(byteCount), Self.format(MediaAttachmentPolicy.maxTotalBytes))
            case .tooMany:
                return L10n.t("feedback.attachment.tooMany", Int64(MediaAttachmentPolicy.maxCount))
            }
        }

        private static func format(_ byteCount: Int) -> String {
            CompanionPanelFeedbackView.formatBytes(byteCount)
        }
    }

    enum AttachmentScope: String, CaseIterable, Identifiable, Sendable {
        case off
        case logsOnly
        case full

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .off: L10n.t("feedback.diagnostics.off")
            case .logsOnly: L10n.t("feedback.diagnostics.logs")
            case .full: L10n.t("feedback.diagnostics.full")
            }
        }

        var bundleScope: PickyDiagnosticsBundleScope? {
            switch self {
            case .off: nil
            case .logsOnly: .logsOnly
            case .full: .full
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !outbox.items.isEmpty {
                PickyFeedbackOutboxSection(outbox: outbox)
            }
            categoryPicker
            messageEditor
            mediaAttachmentPicker
            attachmentPicker
            metadataFooter

            if case .failed(let reason) = status {
                failureNotice(reason: reason)
            }

            if !isConfigured {
                Text("feedback.notConfigured")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            sendRow
        }
        .onDisappear {
            statusResetTask?.cancel()
            statusResetTask = nil
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("feedback.field.category")
            Picker("feedback.field.category", selection: $category) {
                ForEach(PickyFeedbackCategory.allCases) { value in
                    Text("\(value.emoji) \(L10n.t("feedback.category.\(value.rawValue)"))").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(status == .sending)
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("feedback.field.message")
            ZStack(alignment: .topLeading) {
                PickyIMETextView(
                    text: $message,
                    isEditable: status != .sending,
                    font: NSFont.systemFont(ofSize: PickyHUDTypography.Size.supporting),
                    textColor: status == .sending ? .secondaryLabelColor : NSColor(DS.Colors.textPrimary)
                )
                .frame(minHeight: 96, maxHeight: 160)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface2.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
                )

                if message.isEmpty {
                    Text("feedback.placeholder")
                        .pickyFont(size: 12)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var mediaAttachmentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fieldLabel("feedback.field.attach")
                Spacer()
                Button(action: chooseMediaAttachments) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .pickyFont(size: 10, weight: .semibold)
                        Text("feedback.addFiles")
                            .pickyFont(size: 10.5, weight: .semibold)
                    }
                    .foregroundColor(DS.Colors.accentText)
                }
                .buttonStyle(.plain)
                .disabled(status == .sending || selectedMediaAttachments.count >= MediaAttachmentPolicy.maxCount)
                .hoverAffordance()
            }

            if selectedMediaAttachments.isEmpty {
                Text(L10n.t("feedback.attachmentsHint", Int64(MediaAttachmentPolicy.maxCount), Self.formatBytes(MediaAttachmentPolicy.maxFileBytes), Self.formatBytes(MediaAttachmentPolicy.maxTotalBytes)))
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(selectedMediaAttachments) { attachment in
                        mediaAttachmentRow(attachment)
                    }
                }
            }

            if let mediaAttachmentNotice {
                Text(mediaAttachmentNotice)
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mediaAttachmentRow(_ attachment: SelectedMediaAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.kind.iconName)
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.formatBytes(attachment.byteCount))
                    .font(PickyHUDTypography.minimumMonospacedMedium)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 6)
            Button {
                removeMediaAttachment(attachment)
            } label: {
                Image(systemName: "xmark")
                    .pickyFont(size: 9, weight: usesHubTypography ? .medium : .bold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(DS.Colors.surface2.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("feedback.attachment.remove", attachment.filename))
            .help(L10n.t("feedback.attachment.remove", attachment.filename))
            .disabled(status == .sending)
            .hoverAffordance()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var attachmentPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("feedback.diagnostics.title")
            Picker("feedback.diagnostics.title", selection: $attachmentScope) {
                ForEach(AttachmentScope.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(status == .sending)
            Text(attachmentScopeHint)
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attachmentScopeHint: String {
        switch attachmentScope {
        case .off:
            return L10n.t("feedback.diagnostics.offHint")
        case .logsOnly:
            return L10n.t("feedback.diagnostics.logsHint")
        case .full:
            return L10n.t("feedback.diagnostics.fullHint")
        }
    }

    private var metadataFooter: some View {
        Text(metadataLine)
            .pickyFont(size: 10.5, weight: .medium, design: .monospaced)
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sendRow: some View {
        HStack(spacing: 8) {
            if status == .sent {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .pickyFont(size: 10, weight: .semibold)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("feedback.queued")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            Spacer()
            if !status.isFailed {
                Button(action: send) {
                    HStack(spacing: 6) {
                        Text("feedback.send")
                            .pickyFont(size: 11.5, weight: .semibold)
                    }
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accentText.opacity(isSendEnabled ? 0.16 : 0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .stroke(DS.Colors.accentText.opacity(isSendEnabled ? 0.4 : 0.18), lineWidth: 0.7)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isSendEnabled)
                .hoverAffordance()
            }
        }
    }

    private var status: PickyFeedbackSendStatus {
        sendState.status
    }

    private var isSendEnabled: Bool {
        guard isConfigured else { return false }
        guard status != .sending else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func failureNotice(reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.destructiveText)
            Text(reason)
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(L10n.t("feedback.retry"), action: send)
                .buttonStyle(.plain)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.accentText)
                .disabled(!isSendEnabled)
                .accessibilityLabel(L10n.t("feedback.retry.accessibilityLabel"))
                .hoverAffordance()
        }
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .pickyFont(size: 10.5, weight: .semibold)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private var appVersion: String {
        AppBundleConfiguration.stringValue(forKey: "CFBundleShortVersionString") ?? "dev"
    }

    private var appBuild: String {
        AppBundleConfiguration.stringValue(forKey: "CFBundleVersion") ?? "0"
    }

    private var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private var metadataLine: String {
        "Picky \(appVersion) (build \(appBuild)) · macOS \(osVersionString)"
    }

    private func chooseMediaAttachments() {
        guard status != .sending else { return }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = L10n.t("feedback.attachment.panelTitle")
        panel.message = L10n.t("feedback.attachment.choose", Int64(MediaAttachmentPolicy.maxCount))
        panel.prompt = L10n.t("feedback.attachment.attach")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            addMediaAttachments(panel.urls)
        }
    }

    private func addMediaAttachments(_ urls: [URL]) {
        var next = selectedMediaAttachments
        var notices: [String] = []

        for url in urls {
            guard next.count < MediaAttachmentPolicy.maxCount else {
                notices.append(MediaAttachmentError.tooMany.localizedDescription)
                break
            }

            do {
                let attachment = try selectedMediaAttachment(from: url)
                guard !next.contains(where: { $0.id == attachment.id }) else { continue }

                let proposedTotal = next.reduce(0) { $0 + $1.byteCount } + attachment.byteCount
                guard proposedTotal <= MediaAttachmentPolicy.maxTotalBytes else {
                    throw MediaAttachmentError.totalTooLarge(proposedTotal)
                }

                next.append(attachment)
            } catch {
                notices.append(error.localizedDescription)
            }
        }

        selectedMediaAttachments = next
        mediaAttachmentNotice = compactNotice(from: notices)
    }

    private func removeMediaAttachment(_ attachment: SelectedMediaAttachment) {
        selectedMediaAttachments.removeAll { $0.id == attachment.id }
        mediaAttachmentNotice = nil
    }

    private func selectedMediaAttachment(from url: URL) throws -> SelectedMediaAttachment {
        let standardizedURL = url.standardizedFileURL
        let filename = standardizedURL.lastPathComponent
        let values = try standardizedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        if values.isRegularFile == false {
            throw MediaAttachmentError.notRegularFile(filename)
        }

        let type = values.contentType ?? UTType(filenameExtension: standardizedURL.pathExtension)
        let kind = type.map(mediaAttachmentKind(for:)) ?? .file

        let byteCount = try fileByteCount(for: standardizedURL, resourceValues: values)
        guard byteCount <= MediaAttachmentPolicy.maxFileBytes else {
            throw MediaAttachmentError.fileTooLarge(filename, byteCount)
        }

        return SelectedMediaAttachment(url: standardizedURL, filename: filename, byteCount: byteCount, kind: kind)
    }

    private func mediaAttachmentKind(for type: UTType) -> MediaAttachmentKind {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }

    private func fileByteCount(for url: URL, resourceValues: URLResourceValues) throws -> Int {
        if let fileSize = resourceValues.fileSize { return fileSize }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber { return size.intValue }
        return 0
    }

    private func compactNotice(from notices: [String]) -> String? {
        var unique: [String] = []
        for notice in notices where !unique.contains(notice) {
            unique.append(notice)
        }
        guard !unique.isEmpty else { return nil }
        if unique.count <= 2 {
            return unique.joined(separator: " ")
        }
        return unique.prefix(2).joined(separator: " ") + " " + L10n.t("feedback.attachment.moreNotices", Int64(unique.count - 2))
    }

    private static func formatBytes(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Durably stores the submission and hands it to the app-owned outbox.
    /// Nothing is uploaded here, so the form can close right away; a throw
    /// means nothing was stored and the draft must stay on screen.
    private func send() {
        guard isSendEnabled, sendState.beginSending() else { return }
        statusResetTask?.cancel()
        statusResetTask = nil

        let draft = PickyFeedbackOutboxDraft(
            submissionID: submissionID,
            category: category,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: osVersionString,
            requestedAt: Date(),
            diagnosticsScope: attachmentScope.bundleScope,
            attachmentSources: selectedMediaAttachments.map(\.url)
        )

        // Copying the attachments can be hundreds of megabytes; the outbox
        // does that off the main actor and the form stays responsive while
        // `status == .sending` blocks a second submit. Deliberately not tied
        // to the view's lifetime: once the user pressed Send, the snapshot has
        // to finish even if the panel goes away.
        Task { @MainActor in
            do {
                try await outbox.enqueue(draft)
                submissionID = UUID()
                completeSend(.success(()))
            } catch {
                NSLog("Picky feedback enqueue failed: \(PickyFeedbackSendErrorDescription.technicalDescription(error))")
                completeSend(.failure(PickyFeedbackSendFailure(
                    message: PickyFeedbackSendErrorDescription.userMessage(error)
                )))
            }
        }
    }

    private func completeSend(_ result: Result<Void, PickyFeedbackSendFailure>) {
        switch sendState.finish(result) {
        case .clear:
            message = ""
            selectedMediaAttachments = []
            mediaAttachmentNotice = nil
            scheduleSentStatusReset()
            onSubmitted()
        case .preserve:
            break
        }
    }

    private func scheduleSentStatusReset() {
        statusResetTask?.cancel()
        statusResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            sendState.resetSentStatus()
        }
    }
}
