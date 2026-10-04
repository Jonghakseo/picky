//
//  PickyMessengerUXRenderGalleryTests.swift
//  PickyTests
//
//  Offscreen renders for design/proposals/messenger-ux-2026-10.md. Every scene
//  mounts the production components named in that proposal; only the desktop
//  backdrop under the TEXT overlay is a fixture standing in for another app.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyMessengerUXRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.messenger-ux-output-path")
    private static let renderScale: CGFloat = 2
    private static let screenSize = CGSize(width: 720, height: 400)

    private enum Appearance: String {
        case dark, light

        var nsAppearance: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    private struct Scene {
        let name: String
        let appearance: Appearance
        let fixedSize: CGSize?
        let content: () -> AnyView
    }

    private struct ManifestScene: Encodable {
        let file: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
    }

    @Test func writesMessengerUXGalleryWhenOutputDirectoryIsRequested() throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }

        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            var manifest: [ManifestScene] = []
            for scene in try makeScenes() {
                let rendered = try render(scene)
                try rendered.png.write(to: output.appendingPathComponent(scene.name), options: .atomic)
                #expect(NSImage(data: rendered.png) != nil)
                manifest.append(ManifestScene(
                    file: scene.name,
                    logicalWidth: Double(rendered.logicalSize.width),
                    logicalHeight: Double(rendered.logicalSize.height),
                    pixelWidth: rendered.bitmap.pixelsWide,
                    pixelHeight: rendered.bitmap.pixelsHigh,
                    appearance: scene.appearance.rawValue
                ))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["scenes": manifest]).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    // MARK: - Scenes

    private func makeScenes() throws -> [Scene] {
        var scenes: [Scene] = []
        for appearance in [Appearance.dark, .light] {
            scenes.append(Scene(name: "pickle-chat-working-\(appearance.rawValue)-ko.png", appearance: appearance, fixedSize: nil) {
                AnyView(self.pickleChat(hoveredID: nil))
            })
            scenes.append(Scene(name: "pickle-chat-hover-\(appearance.rawValue)-ko.png", appearance: appearance, fixedSize: nil) {
                AnyView(self.pickleChat(hoveredID: "a1"))
            })
            scenes.append(Scene(name: "pickle-presence-states-\(appearance.rawValue)-ko.png", appearance: appearance, fixedSize: nil) {
                AnyView(self.presenceStates())
            })
            scenes.append(Scene(name: "translate-overlay-\(appearance.rawValue)-ko.png", appearance: appearance, fixedSize: Self.screenSize) {
                AnyView(self.translateOverlay())
            })
        }
        scenes.append(Scene(name: "translate-original.png", appearance: .light, fixedSize: Self.screenSize) {
            AnyView(TranslationBackdrop())
        })
        scenes.append(Scene(name: "main-chips-dark-ko.png", appearance: .dark, fixedSize: nil) {
            AnyView(self.mainChips())
        })
        return scenes
    }

    // MARK: Pickle chat

    private static let chatWidth: CGFloat = 460

    /// `hoveredID` pins that bubble's time label, standing in for the pointer
    /// hover that an offscreen render cannot produce.
    private func pickleChat(hoveredID: String?) -> some View {
        let olderReply = """
            어제 배포는 문제없이 끝났어요.

            - 웹: 10:02 배포, 오류율 변화 없음
            - API: 10:05 배포, p95 응답 시간 180ms → 172ms
            - 워커: 10:09 배포, 큐 적체 없음
            - 마이그레이션: 2건 적용, 롤백 계획 확인
            - 알림: 슬랙 #deploy 채널에 요약 게시
            - 남은 일: 결제 웹훅 재시도 설정은 다음 배포로 미룸
            - 참고: 대시보드 링크는 리포트에 정리해 뒀어요
            - 모니터링은 오늘 오전까지 계속 볼게요
            """
        let messages = [
            message("y1", .userText, day: 1, hour: 18, minute: 40, "어제 배포 결과 요약해줘"),
            message("y2", .agentText, day: 1, hour: 18, minute: 41, olderReply),
            message("u1", .userText, minute: 14, "로그인 페이지 테스트가 깨져. 고쳐줘"),
            message("a1", .agentText, minute: 15, "원인 찾았어요. 세션 쿠키 이름이 바뀌었는데 테스트 픽스처가 옛 이름을 쓰고 있었어요."),
            message("a2", .agentText, minute: 15, "픽스처를 고치고 로그인 테스트를 다시 돌리고 있어요."),
            message("u2", .userText, minute: 16, "끝나면 CI도 확인해줘"),
        ]
        let presence = PickyConversationPresencePresentation.make(
            isRunning: true,
            isWaitingForInput: false,
            activeTool: tool("bash", args: #"{"command":"pnpm vitest run login","title":"로그인 테스트 실행"}"#),
            startedAt: Date().addingTimeInterval(-42)
        )
        func timestamp(_ message: PickySessionMessage) -> PickyBubbleTimestamp {
            let sent = PickyBubbleTimestamp.sent(at: message.createdAt)
            return message.id == hoveredID ? PickyBubbleTimestamp(content: sent.content, isPinned: true) : sent
        }
        let dayStarts = PickyConversationDateDividerPolicy.messageIDsStartingDay(messages.map { ($0.id, $0.createdAt) })
        return VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            ForEach(messages, id: \.id) { message in
                if dayStarts.contains(message.id) {
                    PickyConversationDateDivider(title: PickyConversationDateDividerPolicy.title(
                        for: message.createdAt,
                        now: Self.date(minute: 30)
                    ))
                }
                if message.kind == .userText {
                    PickyUserBubbleView(message: message, timestamp: timestamp(message))
                } else {
                    PickyAgentBubbleView(message: message, timestamp: timestamp(message))
                }
            }
            PickyUserBubbleView(message: message("u3", .userText, minute: 17, "PR 설명도 짧게 써줘"), timestamp: .sending)
            if let presence {
                PickyConversationPresenceRow(presentation: presence, onTap: {})
            }
        }
        .environment(\.pickyHUDDetailWidth, Self.chatWidth)
        .frame(width: Self.chatWidth, alignment: .leading)
        .padding(DS.Spacing.space3)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous))
    }

    private func presenceStates() -> some View {
        let started = Date().addingTimeInterval(-75)
        let rows: [PickyConversationPresencePresentation?] = [
            .make(isRunning: true, isWaitingForInput: false, activeTool: nil, startedAt: started),
            .make(isRunning: true, isWaitingForInput: false,
                  activeTool: tool("read", args: #"{"path":"/repo/Picky/HUD/PickyHUDView.swift"}"#),
                  startedAt: started),
            .make(isRunning: true, isWaitingForInput: false,
                  activeTool: tool("bash_async", args: #"{"command":"xcodebuild test","title":"Swift 테스트 실행"}"#),
                  startedAt: started),
            .make(isRunning: true, isWaitingForInput: false,
                  activeTool: tool("read", args: #"{"path":"/Users/me/.pi/agent/skills/picky-design-guide/SKILL.md"}"#),
                  startedAt: started),
            .make(isRunning: true, isWaitingForInput: false,
                  activeTool: tool("subagent", args: #"{"command":"subagent run worker"}"#,
                                   subagent: PickySubagentToolSummary(action: "run", agents: ["worker"])),
                  startedAt: started),
            .make(isRunning: true, isWaitingForInput: false,
                  activeTool: tool("grep", args: #"{"pattern":"PickyToolCallInlineRow","path":"Picky"}"#),
                  startedAt: started),
            .make(isRunning: true, isWaitingForInput: true, activeTool: nil, startedAt: started),
        ]
        return VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            ForEach(Array(rows.compactMap { $0 }.enumerated()), id: \.offset) { _, presentation in
                PickyConversationPresenceRow(presentation: presentation, onTap: {})
            }
        }
        .frame(width: Self.chatWidth, alignment: .leading)
        .padding(DS.Spacing.space3)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous))
    }

    // MARK: Main chips

    private func mainChips() -> some View {
        let scenarios: [[PickyMainActivity]] = [
            [mainTool("t1", "read", #"{"path":"/repo/agentd/src/domain/picky-runtime-contract.ts"}"#, status: "completed"),
             mainTool("t2", "bash", #"{"command":"rg -n \"label\" Picky/Overlay","title":"오버레이 라벨 코드 찾기"}"#)],
            [mainTool("t3", "read", #"{"path":"/repo/Picky/Overlay/PickyAgentAnnotationOverlayView.swift"}"#, status: "completed"),
             mainTool("t4", "grep", #"{"pattern":"RECT:","path":"agentd/src"}"#)],
            [mainTool("t5", "recall", #"{"query":"메신저 디자인 시스템"}"#)],
            [PickyMainActivity(kind: .thinking, thinkingPreview: "The user wants the Korean translation of the pricing header, so I should read the screenshot first.")],
            [mainTool("t6", "bash", #"{"command":"git log --oneline -5"}"#)],
            [mainTool("t7", "web_search", #"{"query":"SwiftUI TimelineView 성능"}"#)],
            [mainTool("t8", "codemode", #"{"code":"const r = await tools.mcp__creatrip__jira_search({ jql: \"project = PK\" })"}"#)],
        ]
        return VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            ForEach(Array(scenarios.enumerated()), id: \.offset) { _, activities in
                let presentation = PickyMainActivityChipPresentation(
                    models: PickyMainActivityConcisePolicy.models(for: activities),
                    isQuestionPending: false
                )
                PickyMainActivityChipStackView(presentation: presentation)
                    .frame(minHeight: 30, alignment: .topLeading)
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(DS.Spacing.space4)
        .background(Color(red: 0.36, green: 0.40, blue: 0.46))
    }

    // MARK: Translation overlay

    private func translateOverlay() -> some View {
        let items = TranslationBackdrop.blocks.map { block in
            PickyAnnotationTextItem(id: block.id, rect: block.rect, text: block.translation, visualStyle: .fallback)
        }
        return ZStack(alignment: .topLeading) {
            TranslationBackdrop()
            PickyAnnotationTextOverlayView(items: items, screenSize: Self.screenSize)
        }
        .frame(width: Self.screenSize.width, height: Self.screenSize.height, alignment: .topLeading)
    }

    // MARK: - Fixtures

    private static func date(day: Int = 2, hour: Int = 10, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func message(
        _ id: String, _ kind: PickySessionMessageKind, day: Int = 2, hour: Int = 10, minute: Int, _ text: String
    ) -> PickySessionMessage {
        PickySessionMessage(
            id: id, kind: kind, createdAt: Self.date(day: day, hour: hour, minute: minute), originatedBy: nil, text: text,
            question: nil, cancelledAt: nil, activitySnapshot: nil, errorContext: nil, errorMessage: nil
        )
    }

    private func tool(_ name: String, args: String, subagent: PickySubagentToolSummary? = nil) -> PickyToolActivity {
        PickyToolActivity(
            toolCallId: "call-\(name)", name: name, status: "running", argsPreview: args,
            subagentSummary: subagent, startedAt: Date().addingTimeInterval(-5)
        )
    }

    private func mainTool(_ id: String, _ name: String, _ args: String, status: String = "running") -> PickyMainActivity {
        PickyMainActivity(kind: .tool, toolCallId: id, toolName: name, status: status, argsPreview: args)
    }

    // MARK: - Render

    private func render(_ scene: Scene) throws -> (png: Data, bitmap: NSBitmapImageRep, logicalSize: CGSize) {
        let fontStore = PickyAppFontScaleStore()
        func root(padding: CGFloat, frame: CGSize?) -> AnyView {
            AnyView(PickyAppFontScaleRoot(store: fontStore) {
                scene.content()
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .fixedSize(horizontal: false, vertical: scene.fixedSize == nil)
                    .padding(padding)
                    .frame(width: frame?.width, height: frame?.height, alignment: .topLeading)
            })
        }
        let canvasInset: CGFloat = scene.fixedSize == nil ? DS.Spacing.space4 : 0
        let contentSize: CGSize
        if let fixed = scene.fixedSize {
            contentSize = fixed
        } else {
            let measuring = NSHostingView(rootView: root(padding: 0, frame: nil))
            measuring.appearance = NSAppearance(named: scene.appearance.nsAppearance)
            measuring.layoutSubtreeIfNeeded()
            contentSize = measuring.fittingSize
        }
        guard contentSize.width > 0, contentSize.height > 0 else { throw RenderError.empty(scene.name) }
        let logical = CGSize(width: contentSize.width + canvasInset * 2, height: contentSize.height + canvasInset * 2)
        let renderSize = CGSize(
            width: (logical.width * Self.renderScale).rounded(.up) / Self.renderScale,
            height: (logical.height * Self.renderScale).rounded(.up) / Self.renderScale
        )
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            root(padding: canvasInset, frame: renderSize),
            logicalSize: renderSize,
            scale: Self.renderScale,
            appearance: scene.appearance.nsAppearance
        ), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.bitmap(scene.name)
        }
        return (png, bitmap, logical)
    }

    private enum RenderError: Error {
        case empty(String)
        case bitmap(String)
    }
}

/// Fixture standing in for a third-party app window under the overlay. It is
/// not a Picky surface, so it uses plain colors rather than design tokens.
private struct TranslationBackdrop: View {
    struct Block: Identifiable {
        let id: String
        let rect: CGRect
        let source: String
        let translation: String
        let size: CGFloat
        let weight: Font.Weight
        let color: Color
    }

    private static let navy = Color(red: 0.07, green: 0.11, blue: 0.22)
    private static let ink = Color(red: 0.13, green: 0.15, blue: 0.19)
    private static let blue = Color(red: 0.15, green: 0.39, blue: 0.92)
    private static let card = Color(red: 0.95, green: 0.96, blue: 0.97)

    static let blocks: [Block] = [
        Block(id: "nav", rect: CGRect(x: 470, y: 18, width: 220, height: 18),
              source: "Pricing    Docs    Sign in", translation: "요금    문서    로그인",
              size: 13, weight: .medium, color: .white),
        Block(id: "title", rect: CGRect(x: 40, y: 92, width: 520, height: 36),
              source: "Ship faster with fewer meetings", translation: "회의는 줄이고 더 빨리 출시하세요",
              size: 30, weight: .bold, color: ink),
        Block(id: "body", rect: CGRect(x: 40, y: 142, width: 420, height: 40),
              source: "Async standups, decision logs, and review queues keep your team moving without another call.",
              translation: "비동기 스탠드업, 결정 기록, 리뷰 대기열로 회의 없이도 팀이 계속 움직여요.",
              size: 14, weight: .regular, color: ink.opacity(0.75)),
        Block(id: "cta", rect: CGRect(x: 56, y: 212, width: 128, height: 18),
              source: "Start free trial", translation: "무료 체험 시작",
              size: 14, weight: .semibold, color: .white),
        Block(id: "badge", rect: CGRect(x: 216, y: 214, width: 70, height: 14),
              source: "No card needed", translation: "결제 수단 등록 없이 바로 시작할 수 있어요",
              size: 11, weight: .regular, color: ink.opacity(0.6)),
        Block(id: "billing", rect: CGRect(x: 60, y: 288, width: 300, height: 18),
              source: "Billing cycle: annual, prorated on upgrade",
              translation: "결제 주기: 연간. 중간에 상위 요금제로 바꾸면 남은 기간만큼 일할 계산해서 차액만 청구해요. 하위 요금제로 내리면 다음 결제일부터 적용되고, 이미 낸 금액은 크레딧으로 남아 다음 청구에서 먼저 차감돼요. 연간 결제를 취소하면 남은 기간은 그대로 쓸 수 있지만 환불은 되지 않아요.",
              size: 13, weight: .medium, color: ink),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Self.navy.frame(height: 54)
            Text("acme")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.white)
                .position(x: 70, y: 27)
            RoundedRectangle(cornerRadius: 8)
                .fill(Self.blue)
                .frame(width: 160, height: 40)
                .position(x: 120, y: 221)
            RoundedRectangle(cornerRadius: 10)
                .fill(Self.card)
                .frame(width: 640, height: 110)
                .position(x: 360, y: 320)
            Text("Plan details")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.ink.opacity(0.5))
                .position(x: 96, y: 278 - 8)
            ForEach(Self.blocks) { block in
                Text(block.source)
                    .font(.system(size: block.size, weight: block.weight))
                    .foregroundStyle(block.color)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(width: block.rect.width, height: block.rect.height, alignment: .leading)
                    .position(x: block.rect.midX, y: block.rect.midY)
            }
        }
        .frame(width: 720, height: 400)
        .environment(\.colorScheme, .light)
    }
}
