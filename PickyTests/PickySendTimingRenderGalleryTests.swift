//
//  PickySendTimingRenderGalleryTests.swift
//  PickyTests
//
//  Renders the production send-timing menu and custom-time screen. Writes only
//  when build/render-gallery/.send-timing-output-path names an output folder.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickySendTimingRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.send-timing-output-path")
    private static let renderScale: CGFloat = 2

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }()
    private static let locale = Locale(identifier: "ko_KR")
    /// Saturday 2026-10-03 14:29.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 29))!

    private enum Appearance: String, CaseIterable {
        case dark, light
        var nsAppearance: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    @Test func writesSendTimingRendersWhenOutputDirectoryIsRequested() throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }
        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            for appearance in Appearance.allCases {
                let png = try render({ AnyView(self.board) }, appearance: appearance)
                try png.write(to: output.appendingPathComponent("send-timing-\(appearance.rawValue).png"), options: .atomic)
            }
        }
    }

    // MARK: Scenes

    private var board: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space6) {
            HStack(alignment: .top, spacing: DS.Spacing.space6) {
                labeled("1. 보낼 시점") { popover(list) }
                labeled("2. 사용자 지정 시간") { popover(custom(draft())) }
                labeled("3. 해석할 수 없는 시간") {
                    popover(custom(draft { $0.timeText = "25:70"; $0.showsTimeError = true }))
                }
            }
            HStack(alignment: .top, spacing: DS.Spacing.space6) {
                labeled("4. 지난 시간") { popover(custom(draft { $0.timeText = "오전 9:00" })) }
                labeled("5. 다른 날짜… 달력") {
                    popover(custom(draft {
                        $0.day = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!
                        $0.isCalendarVisible = true
                    }))
                }
            }
        }
    }

    private var list: some View {
        PickySendTimingMenuView(
            options: PickySendTimingPolicy.options(
                now: Self.now,
                canSendAfterCurrentReply: true,
                isPluginInstalled: true,
                calendar: Self.calendar,
                locale: Self.locale
            ),
            isPluginInstalled: true,
            isInstallingPlugin: false,
            installError: nil,
            onSelect: { _ in },
            onInstallPlugin: {}
        )
    }

    private func draft(_ edit: (inout PickyCustomSendTimeDraft) -> Void = { _ in }) -> PickyCustomSendTimeDraft {
        var draft = PickyCustomSendTimePolicy.makeDraft(now: Self.now, calendar: Self.calendar, locale: Self.locale)
        edit(&draft)
        draft.displayedMonth = PickyCustomSendTimePolicy.startOfMonth(for: draft.day, calendar: Self.calendar)
        return draft
    }

    private func custom(_ draft: PickyCustomSendTimeDraft) -> some View {
        PickyCustomSendTimeView(
            draft: .constant(draft),
            calendar: Self.calendar,
            locale: Self.locale,
            fixedNow: Self.now,
            onBack: {},
            onCancel: {},
            onSchedule: { _ in }
        )
        .frame(width: PickySendTimingMenuView.width, alignment: .leading)
    }

    /// Stand-in for NSPopover chrome, which an offscreen host cannot draw.
    private func popover(_ content: some View) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control + 2, style: .continuous)
                    .fill(DS.Colors.surface2)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control + 2, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text(title)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.textSecondary)
            content()
        }
    }

    // MARK: Rendering

    private func render(_ content: @escaping () -> AnyView, appearance: Appearance) throws -> Data {
        func root(frame: CGSize?) -> AnyView {
            AnyView(
                content()
                    .environment(\.locale, Self.locale)
                    .environment(\.timeZone, Self.calendar.timeZone)
                    .environment(\.calendar, Self.calendar)
                    .preferredColorScheme(appearance.colorScheme)
                    .padding(DS.Spacing.space5)
                    .background(DS.Colors.surface1)
                    .fixedSize()
                    .frame(width: frame?.width, height: frame?.height, alignment: .topLeading)
            )
        }
        let measuring = NSHostingView(rootView: root(frame: nil))
        measuring.appearance = NSAppearance(named: appearance.nsAppearance)
        measuring.layoutSubtreeIfNeeded()
        let size = measuring.fittingSize
        let renderSize = CGSize(
            width: (size.width * Self.renderScale).rounded(.up) / Self.renderScale,
            height: (size.height * Self.renderScale).rounded(.up) / Self.renderScale
        )
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            root(frame: renderSize), logicalSize: renderSize, scale: Self.renderScale,
            appearance: appearance.nsAppearance
        ), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.bitmap
        }
        return png
    }

    private enum RenderError: Error { case bitmap }
}
