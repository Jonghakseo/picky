import AppKit
import SwiftUI

// Design decision: show whether work needs attention without competing with the conversation.
// Default = one disclosure row. Expand for task names; select a task for progress and Stop.
// Failure/unknown state remains visible while collapsed. No work = no shelf or reserved space.
// Keep execution vs result delivery distinct; a stop request is not confirmed cancellation.
// This standalone proposal uses deterministic fixtures, never the daemon or user session state.
// Prototype-only token mirror of design/TOKENS.md: avoids importing app lifecycle dependencies.
// No material/motion is needed inside the card; native buttons supply focus/pressed behavior.
// Copy: Background tasks -> 작업 N개 실행 중 / N tasks running;
// Details -> 작업 상세 / Task details; Stop -> 중지 / Stop;
// Result processing -> 결과 정리 중 / Processing results; Unknown -> 상태 확인 필요 / Check status.

private enum Style {
    static let body = Font.system(size: 13)
    static let title = Font.system(size: 14, weight: .semibold)
    static let supporting = Font.system(size: 12)
    static let meta = Font.system(size: 11)
    static let radius: CGFloat = 14
    static let gap: CGFloat = 12
    static func color(_ light: UInt32, _ dark: UInt32, _ scheme: ColorScheme) -> Color {
        let value = scheme == .dark ? dark : light
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private enum Scenario: String, CaseIterable, Identifiable {
    case running = "실행 중", processing = "결과 정리", failed = "실패", unknown = "상태 미확인", empty = "작업 없음"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .processing: "tray"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        case .empty: "checkmark.circle"
        }
    }
    var summary: String {
        switch self {
        case .running: "작업 2개 실행 중"
        case .processing: "결과 정리 중"
        case .failed: "테스트 실행 실패"
        case .unknown: "작업 상태 확인 필요"
        case .empty: ""
        }
    }
    var note: String {
        switch self {
        case .running: "작업 수만 한 줄로 표시해요.\n작업명과 중지는 펼쳤을 때 보여요."
        case .processing: "실행 완료와 결과 정리를 구분해요.\n결과를 처리하는 동안에는 완료로 표시하지 않아요."
        case .failed: "접혀 있어도 실패한 작업이 보여요.\n원인과 자세한 내용은 작업 아래에 모아요."
        case .unknown: "확인되지 않은 실행 상태는 그대로 알려요.\n실행 중이나 완료로 추측하지 않아요."
        case .empty: "작업이 없으면 작업 영역도 사라져요.\n재진입할 때 빈 영역을 남기지 않아요."
        }
    }
}

private struct StudyView: View {
    @State private var scenario: Scenario = .running
    @State private var dark = false
    var forcedScheme: ColorScheme?
    var textScale: CGFloat = 1

    init(forcedScheme: ColorScheme? = nil, initialScenario: Scenario = .running, textScale: CGFloat = 1) {
        self.forcedScheme = forcedScheme
        self.textScale = textScale
        _scenario = State(initialValue: initialScenario)
    }

    private var scheme: ColorScheme { forcedScheme ?? (dark ? .dark : .light) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("대화는 넓게, 작업은 한 줄로")
                        .font(.system(size: 22, weight: .semibold))
                    Text("백그라운드 작업 · SwiftUI 목업 · 예시 데이터")
                        .font(Style.supporting).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("다크 모드", isOn: $dark).toggleStyle(.switch).controlSize(.small)
                    .disabled(forcedScheme != nil)
            }
            HStack(spacing: 16) {
                Picker("예시 상태", selection: $scenario) {
                    ForEach(Scenario.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 590)
                Spacer()
                Text("실제 작업에는 영향을 주지 않아요")
                    .font(Style.meta).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 32) {
                example(title: "기본", description: "읽고 쓰는 대화에 집중", expanded: false)
                example(title: "펼침", description: "필요할 때 작업명과 상세 확인", expanded: true)
            }
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "cursorarrow.and.square.on.square.dashed").foregroundStyle(.secondary)
                Text("작업 줄을 눌러 접거나 펼쳐보세요. 목록에서 작업을 선택하면 상세와 중지가 나타나요.")
                    .font(Style.supporting).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 1040, height: 810, alignment: .topLeading)
        .foregroundStyle(Style.color(0x1A1C1B, 0xECEEED, scheme))
        .background(Style.color(0xF7F8F8, 0x101211, scheme))
        .environment(\.colorScheme, scheme)
    }

    private func example(title: String, description: String, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(Style.title)
                Text(description).font(Style.supporting).foregroundStyle(.secondary)
            }
            ConversationStudy(scenario: scenario, startsExpanded: expanded, textScale: textScale)
                .id("\(scenario.rawValue)-\(expanded)")
            Text(scenario.note).font(Style.supporting).foregroundStyle(.secondary)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConversationStudy: View {
    let scenario: Scenario
    let startsExpanded: Bool
    var textScale: CGFloat = 1
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var sent: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("로그인 오류 수정").font(Style.title)
                Spacer()
                Text("picky").font(Style.supporting).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Spacer(minLength: 36)
                        Text("로그인 오류를 고치고 테스트도 확인해줘.")
                            .padding(12)
                            .background(Style.color(0xF0F1F1, 0x202221, scheme),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Picky").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(message)
                            .lineSpacing(5)
                    }
                    if let sent {
                        HStack {
                            Spacer(minLength: 36)
                            Text(sent).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if scenario != .empty {
                WorkShelf(scenario: scenario, initiallyExpanded: startsExpanded)
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom) {
                    TextField("추가로 요청하기", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...3)
                        .onSubmit { send() }
                    Button(action: send) { Image(systemName: "arrow.up").frame(width: 24, height: 24) }
                        .buttonStyle(.borderedProminent).tint(.blue).disabled(draft.isEmpty)
                        .help("목업에 메시지 추가").accessibilityLabel("목업에 메시지 추가")
                }.padding(12)
                    .background(Style.color(0xF0F1F1, 0x202221, scheme), in: RoundedRectangle(cornerRadius: 8))
            }.padding(12)
        }
        .font(.system(size: 13 * textScale))
        .frame(height: 520)
        .background(Style.color(0xFFFFFF, 0x171918, scheme))
        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        .overlay(RoundedRectangle(cornerRadius: Style.radius)
            .strokeBorder(Style.color(0xE1E3E2, 0x373B39, scheme), lineWidth: 1))
    }

    private var message: String {
        switch scenario {
        case .running: "인증 토큰을 갱신하는 부분을 수정했어요.\n테스트와 변경사항 리뷰를 함께 실행하고 있어요."
        case .processing: "테스트 실행이 끝났어요.\n결과를 확인하고 정리하고 있어요."
        case .failed: "토큰 갱신 테스트가 실패했어요.\n실패 내용을 확인해야 해요."
        case .unknown: "작업 상태를 확인할 수 없어요.\n완료 여부는 아직 알 수 없어요."
        case .empty: "인증 토큰 갱신을 수정했고 테스트도 통과했어요.\n변경사항 리뷰도 마쳤어요."
        }
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sent = draft
        draft = ""
    }
}

private struct WorkShelf: View {
    let scenario: Scenario
    @State private var expanded: Bool
    @State private var selected: Int?
    @State private var stopping: Set<Int> = []
    @State private var confirmStop = false
    @Environment(\.colorScheme) private var scheme

    init(scenario: Scenario, initiallyExpanded: Bool) {
        self.scenario = scenario
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var tone: Color {
        switch scenario {
        case .failed: Style.color(0xC42B32, 0xFF8A8E, scheme)
        case .unknown: Style.color(0x855700, 0xFFD080, scheme)
        default: Style.color(0x525956, 0xADB5B2, scheme)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: scenario.symbol).foregroundStyle(tone).frame(width: 16)
                    Text(stopping.isEmpty ? scenario.summary : stopping.count == 2 ? "작업 2개 중지 요청 중" : "중지 요청 중 · 나머지 작업 실행 중")
                        .foregroundStyle(tone)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: 36).contentShape(Rectangle())
            }.buttonStyle(QuietButtonStyle())
                .accessibilityLabel("\(scenario.summary), 작업 목록")
                .accessibilityValue(expanded ? "펼쳐짐" : "접힘")
                .help(expanded ? "작업 목록 접기" : "작업 목록 펼치기")
            if expanded {
                VStack(spacing: 0) {
                    taskRow(0, title: "테스트 실행", status: firstStatus, time: "1:42")
                    if scenario == .running { taskRow(1, title: "변경사항 리뷰", status: "실행 중", time: "0:38") }
                    if let selected { detail(for: selected) }
                }.padding(.bottom, 8)
            }
        }.padding(.horizontal, 16)
    }

    private var firstStatus: String {
        if stopping.contains(0) { return "중지 요청 중" }
        switch scenario {
        case .running: return "실행 중"
        case .processing: return "결과 정리 중"
        case .failed: return "실패"
        case .unknown: return "상태 미확인"
        case .empty: return "완료"
        }
    }

    private func taskRow(_ index: Int, title: String, status: String, time: String) -> some View {
        Button { selected = selected == index ? nil : index } label: {
            HStack(spacing: 8) {
                Text(title).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                Text(stopping.contains(index) ? "중지 요청 중" : status)
                    .font(Style.supporting).foregroundStyle(index == 0 ? tone : .secondary)
                if scenario == .running {
                    Text(time).monospacedDigit().font(Style.meta).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                Image(systemName: selected == index ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle(selected: selected == index))
            .accessibilityLabel("\(title), \(status), 작업 상세")
            .accessibilityValue(selected == index ? "선택됨" : "")
    }

    private func detail(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(index == 0 ? "테스트 실행" : "변경사항 리뷰").font(.system(size: 12, weight: .semibold))
            Text(detailText(index)).font(Style.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if scenario == .running {
                HStack {
                    Text(index == 0 ? "pnpm test" : "reviewer · 변경 파일 3개")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button(stopping.contains(index) ? "중지 요청 중" : "중지", role: .destructive) {
                        confirmStop = true
                    }.controlSize(.small).disabled(stopping.contains(index))
                }
            }
        }.padding(8)
            .confirmationDialog("이 예시 작업을 중지할까요?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("예시 작업 중지", role: .destructive) { stopping.insert(index) }
                Button("취소", role: .cancel) {}
            } message: {
                Text("목업 화면만 바뀌며 실제 작업에는 영향을 주지 않아요.")
            }
    }

    private func detailText(_ index: Int) -> String {
        switch scenario {
        case .running: index == 0 ? "인증 관련 테스트를 실행하고 있어요." : "토큰 갱신과 오류 처리 부분을 검토하고 있어요."
        case .processing: "테스트 실행은 끝났어요. 결과를 대화에 반영하고 있어요."
        case .failed: "토큰 갱신 테스트가 실패했어요.\n예상 응답 200 · 실제 응답 401"
        case .unknown: "실행 상태를 확인할 수 없어요. 완료 여부를 확인하기 전에는 다시 실행하지 마세요."
        case .empty: ""
        }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, selected: selected)
    }
    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering || selected ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

@main
private enum AsyncWorkStudyApp {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        if let flag = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > flag + 1 {
            app.setActivationPolicy(.prohibited)
            let output = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                for scenario in Scenario.allCases {
                    let view = StudyView(forcedScheme: dark ? .dark : .light, initialScenario: scenario)
                    // Fixture state is initialized before drawing; no app/session is opened.
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 1040, height: 810)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw NSError(domain: "MockRender", code: 1)
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "MockRender", code: 2)
                    }
                    let name = "\(scenario.id)-\(dark ? "dark" : "light").png"
                    try data.write(to: output.appendingPathComponent(name))
                    print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
                }
            }
            return
        }
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 810),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Picky · 백그라운드 작업 간소화 목업"
        window.contentView = NSHostingView(rootView: StudyView())
        window.isReleasedWhenClosed = false
        let delegate = StudyDelegate()
        app.delegate = delegate
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "목업 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        menu.addItem(item)
        app.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class StudyDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
