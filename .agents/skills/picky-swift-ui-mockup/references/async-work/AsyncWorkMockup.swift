import AppKit
import SwiftUI
import Vision
@testable import Picky

// Proposal only. Production code is unchanged. Width, typography, colors,
// row heights and composer come from the actual HUD, not an HTML approximation.
enum WorkState: String, CaseIterable {
    case running, queued, stopping, completed, failed, cancelled, interrupted, unknown
    var title: String {
        switch self {
        case .running: "실행 중"
        case .queued: "실행 대기"
        case .stopping: "중지 중"
        case .completed: "완료"
        case .failed: "실패"
        case .cancelled: "취소됨"
        case .interrupted: "중단됨"
        case .unknown: "상태 확인 불가"
        }
    }
    var color: Color {
        switch self {
        case .running: DS.Colors.info
        case .completed: DS.Colors.success
        case .failed: DS.Colors.destructiveText
        case .unknown, .interrupted: DS.Colors.warningText
        default: DS.Colors.textSecondary
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .queued: "clock"
        case .stopping: "stop.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .interrupted, .unknown: "exclamationmark.triangle"
        }
    }
}
struct WorkRow: Identifiable {
    var id: String { title }
    let title: String
    let state: WorkState
    let time: String
    init(_ title: String, _ state: WorkState, _ time: String = "") {
        self.title = title; self.state = state; self.time = time
    }
}
struct WorkGroup: Identifiable {
    var id: String { title + children.map(\.title).joined(separator: "/") }
    let title: String
    let children: [WorkRow]
    var result: String? = nil
    var summary: String {
        WorkState.allCases.compactMap { state in
            let count = children.filter { $0.state == state }.count
            return count == 0 ? nil : "\(state.title) \(count)개"
        }.joined(separator: " · ")
    }
}
struct Scene {
    let id: String
    let title: String
    let note: String
    var groups: [WorkGroup] = []
    var tasks: [WorkRow] = []
    var expanded = true
    var status = "실행 중"
    var statusState: WorkState = .running
    var result: String? = nil
    var hidden = false
    var fullDocument = false
}

struct ProposalFooter: View {
    let scene: Scene
    @State private var expanded: Bool
    init(scene: Scene) { self.scene = scene; _expanded = State(initialValue: scene.expanded) }
    var body: some View {
        if !scene.hidden {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: DS.Spacing.space2) {
                        Text(Image(systemName: scene.statusState.symbol))
                            .foregroundStyle(scene.statusState.color).accessibilityHidden(true)
                        Text("백그라운드 작업")
                        Text("· \(scene.status)")
                        Spacer(minLength: DS.Spacing.space2)
                        Text(Image(systemName: expanded ? "chevron.up" : "chevron.down"))
                            .foregroundStyle(DS.Colors.textTertiary).accessibilityHidden(true)
                    }
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Spacing.space2)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("백그라운드 작업, \(scene.status)")
                .accessibilityValue(expanded ? "펼쳐짐" : "접힘")
                if expanded {
                    if scene.fullDocument { rows }
                    else {
                        // Same intrinsic-height bounded document layout as the real footer.
                        ProposalListLayout(maxHeight: 180) {
                            rows.hidden().accessibilityHidden(true)
                            ScrollView { rows.frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                }
            }
            .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
            .padding(.bottom, DS.Spacing.space2)
        }
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(scene.groups) { group in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
                    Text(group.title).foregroundStyle(DS.Colors.textPrimary).lineLimit(1)
                    Text(group.summary).foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.space2)
                .frame(minHeight: 28)
                ForEach(group.children) { row in workRow(row, child: true) }
                if let result = group.result { resultRow(result, child: true) }
            }
            ForEach(scene.tasks) { row in workRow(row, child: false) }
            if let result = scene.result { resultRow(result, child: false) }
        }
    }
    private func workRow(_ row: WorkRow, child: Bool) -> some View {
        HStack(spacing: DS.Spacing.space2) {
            Text(row.title).foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .help(row.title)
            Text(Image(systemName: row.state.symbol))
                .foregroundStyle(row.state.color).accessibilityHidden(true)
            Text(row.state.title).foregroundStyle(row.state.color).fixedSize()
            Text(row.time).monospacedDigit().foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.leading, child ? DS.Spacing.space6 : DS.Spacing.space2)
        .padding(.trailing, DS.Spacing.space2)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }
    private func resultRow(_ text: String, child: Bool) -> some View {
        Text(text).foregroundStyle(text.contains("실패") ? DS.Colors.destructiveText : DS.Colors.textSecondary)
            .padding(.leading, child ? DS.Spacing.space6 : DS.Spacing.space2)
            .frame(minHeight: 28, alignment: .leading)
    }
}
struct ProposalListLayout: Layout {
    let maxHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(height, maxHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

@MainActor final class Fixture {
    let store: PickySessionStore
    let commands: PickySessionListViewModel
    let client: FakePickyAgentClient
    init() {
        client = FakePickyAgentClient()
        commands = PickySessionListViewModel(client: client)
        var card = PickySessionCard.fromAgentSession(PickyAgentSession(
            id: "proposal", title: "코드 유지보수성 검토", status: .waiting_for_input,
            cwd: "/tmp/picky-mockup", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), logs: [], tools: [], artifacts: [], changedFiles: [], messages: []))
        card.agentCycle = .init(cycleId: "mock", runtimeInstanceId: "mock", phase: .idle, outcome: nil, controlGeneration: 1)
        card.asyncWorkSummary = .init(tracking: .ready, activeRootCount: 0, pendingCompletionCount: 0,
            uncertainExecutionCount: 0, attentionCount: 0, workRevision: 1, canReleaseRuntime: true)
        card.asyncTasks = []; card.completionTickets = []
        store = PickySessionStore(sessionID: card.id)
        store.replace(card: card)
    }
}
struct MockupStrip: View {
    let scene: Scene
    let fixture: Fixture
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Existing tool history strip and TextKit composer are actual production views.
            PickyActivitySummaryView(summary: PickyActivitySummary(subagent: 2))
                .padding(.bottom, DS.Spacing.space3)
            ProposalFooter(scene: scene)
            PickyConversationComposerView(metaStore: fixture.store.metaStore,
                conversationStore: fixture.store.conversationStore, queueStore: fixture.store.queueStore,
                viewModel: fixture.commands)
        }
        .frame(width: width - PickyHUDDockLayout.detailHorizontalPadding * 2)
        .padding(.horizontal, PickyHUDDockLayout.detailHorizontalPadding)
        .padding(.vertical, DS.Spacing.space3)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous))
    }
}

@main struct Render {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared // Never activate, show a window, or launch Picky.
        NSApp.setActivationPolicy(.prohibited)
        let live = [WorkRow("verifier", .running, "14:26"), WorkRow("reviewer", .completed, "9:48"), WorkRow("challenger", .completed, "7:17")]
        let allRunning = [WorkRow("verifier", .running, "0:42"), WorkRow("reviewer", .running, "0:41"), WorkRow("challenger", .running, "0:40")]
        let done = [WorkRow("verifier", .completed, "18:42"), WorkRow("reviewer", .completed, "9:48"), WorkRow("challenger", .completed, "7:17")]
        let mixedTasks = [WorkRow("테스트 실행", .running, "3:12"), WorkRow("로그 수집", .running, "0:45")]
        var scenes: [Scene] = [
            .init(id: "01-parallel", title: "3개 병렬 실행", note: "같은 batch의 에이전트 전체와 실제 상태를 표시합니다.", groups: [.init(title: "서브에이전트", children: allRunning)]),
            .init(id: "02-one-remaining", title: "1개 실행 중, 2개 완료", note: "보고된 상황. 먼저 끝난 둘도 같은 묶음에 남습니다.", groups: [.init(title: "서브에이전트", children: live)]),
            .init(id: "03-mixed", title: "서브에이전트 + 다른 비동기 작업", note: "에이전트 개수와 명령 개수를 합산하지 않습니다. 작업 목록 높이는 실제 막대 예산과 같은 180pt로 제한합니다.", groups: [.init(title: "서브에이전트", children: live)], tasks: mixedTasks),
            .init(id: "04-collapsed", title: "혼합 작업, 접힌 상태", note: "현재 상태만 요약하며 내부 작업 묶음 수를 총개수로 노출하지 않습니다.", groups: [.init(title: "서브에이전트", children: live)], tasks: mixedTasks, expanded: false),
            .init(id: "05-queued", title: "실행 대기", note: "실행 전 대기와 실행 중을 구분합니다.", groups: [.init(title: "서브에이전트", children: [.init("worker", .queued), .init("reviewer", .queued)])], status: "실행 대기", statusState: .queued),
            .init(id: "06-stopping", title: "중지 확인 중", note: "중지 요청만으로 취소 완료라고 표시하지 않습니다.", groups: [.init(title: "서브에이전트", children: [.init("verifier", .stopping, "14:26"), .init("reviewer", .completed, "9:48"), .init("challenger", .completed, "7:17")])], tasks: [.init("로그 수집", .stopping, "0:45")], status: "중지 중", statusState: .stopping),
            .init(id: "07-result-pending", title: "실행 완료, 결과 처리 대기", note: "실행 성공과 결과 처리는 별개입니다. 결과를 처리하기 전에는 막대를 숨기지 않습니다.", groups: [.init(title: "서브에이전트", children: done, result: "결과 처리 대기")], status: "결과 처리 대기", statusState: .queued),
            .init(id: "08-result-processing", title: "결과 처리 중", note: "실행이 끝났으므로 경과 시간은 늘어나지 않고 확정 소요 시간을 표시합니다.", groups: [.init(title: "서브에이전트", children: done, result: "결과 처리 중")], status: "결과 처리 중"),
            .init(id: "09-failure-mixed", title: "실패 + 다른 작업 실행", note: "실패를 완료에 합치지 않으며, 실행 중인 다른 작업이 있어도 확인 필요 상태를 우선 알립니다.", groups: [.init(title: "서브에이전트", children: [.init("verifier", .failed, "14:26"), .init("reviewer", .completed, "9:48"), .init("challenger", .completed, "7:17")])], tasks: [.init("로그 수집", .running, "0:45")], status: "확인 필요 · 실행 중", statusState: .failed),
            .init(id: "10-unknown", title: "상태 확인 불가", note: "알 수 없는 상태를 실행 또는 완료로 추정하지 않습니다. 알 수 없는 경과 시간도 표시하지 않습니다.", tasks: [.init("테스트 실행", .unknown)], status: "상태 확인 필요", statusState: .unknown),
            .init(id: "11-interrupted", title: "취소와 중단 구분", note: "사용자 취소와 실행 중단은 서로 다른 상태입니다.", groups: [.init(title: "서브에이전트", children: [.init("verifier", .interrupted, "14:26"), .init("reviewer", .cancelled, "3:12"), .init("challenger", .completed, "7:17")])], status: "확인 필요", statusState: .interrupted),
            .init(id: "12-delivery-failed", title: "실행 성공, 결과 전달 실패", note: "에이전트 실행 결과는 완료로 유지하고, 묶음에 결과 전달 실패를 따로 표시합니다.", groups: [.init(title: "서브에이전트", children: done, result: "결과 전달 실패")], status: "결과 전달 실패", statusState: .failed),
            .init(id: "13-settled", title: "모든 작업·결과 처리 완료", note: "막대와 여백을 없애고 입력창만 남깁니다. 완료 기록은 대화에 유지합니다.", hidden: true),
            .init(id: "14-two-batches", title: "서로 다른 batch", note: "각 batch를 독립 묶음으로 표시합니다. 두 번째 묶음 아래 행은 목록을 스크롤해 확인합니다.", groups: [.init(title: "서브에이전트", children: live), .init(title: "서브에이전트", children: [.init("worker", .running, "2:05"), .init("searcher", .queued)])]),
            .init(id: "15-long-title", title: "긴 작업 제목", note: "상태와 시간 폭을 유지하고 제목만 생략합니다. 실제 UI에서는 제목 도움말로 전체 문자열을 확인할 수 있습니다.", tasks: [.init("agentd 프로토콜 호환성 및 저장 상태 회귀 테스트 실행", .running, "3:12"), .init("격리 환경의 데몬 로그와 진단 자료 수집", .queued)])
        ]
        scenes.append(.init(id: "16-two-batches-document", title: "두 batch, 전체 목록", note: "180pt 뷰포트 제한을 풀어 스크롤 문서의 전체 내용을 검수하는 장면입니다. 실제 막대 높이와 다릅니다.", groups: scenes[13].groups, fullDocument: true))
        var manifest: [[String: Any]] = []
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            for scene in scenes {
                for light in [false, true] {
                    try render(scene, light: light, width: 446, fontScale: 1, output: output, manifest: &manifest)
                }
            }
            try render(scenes[2], light: false, width: 380, fontScale: 1.3, output: output, manifest: &manifest)
            try render(scenes[8], light: false, width: 380, fontScale: 1.3, output: output, manifest: &manifest)
        }
        try JSONSerialization.data(withJSONObject: ["renderer": "SwiftUI / NSHostingView; production DS, activity and composer; proposed footer", "scenes": manifest], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        print("Rendered \(manifest.count) SwiftUI scenes. No Picky app launch or daemon connection.")
    }
    @MainActor static func render(_ scene: Scene, light: Bool, width: CGFloat, fontScale: CGFloat, output: URL, manifest: inout [[String: Any]]) throws {
        let fixture = Fixture()
        let view = MockupStrip(scene: scene, fixture: fixture, width: width)
            .environment(\.pickyAppFontScale, fontScale)
            .environment(\.locale, Locale(identifier: "ko"))
            .environment(\.colorScheme, light ? .light : .dark)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard abs(size.width - width) < 1, size.height > 0 else { throw NSError(domain: "Invalid geometry", code: 1) }
        let bitmap = PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size, scale: 2, appearance: light ? .aqua : .darkAqua)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = width == 446 ? "" : "-narrow-130"
        let name = "\(scene.id)-\(light ? "light" : "dark")\(suffix).png"
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.contains("hud.composer."), !text.contains("hud.activity.") else { throw NSError(domain: "Missing localized resources", code: 2) }
        guard !text.contains("1명"), !text.contains("2명"), !text.contains("3명") else { throw NSError(domain: "Personified count", code: 3) }
        guard fixture.client.sentCommands.isEmpty, fixture.client.submitted.isEmpty else { throw NSError(domain: "Unexpected runtime command", code: 4) }
        manifest.append(["id": scene.id, "title": scene.title, "note": scene.note, "file": name,
            "appearance": light ? "light" : "dark", "width": size.width, "height": size.height,
            "scale": fontScale, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "ocr": text])
        print("\(name): \(Int(size.width))×\(Int(size.height))pt")
    }
}
