import AppKit
import SwiftUI

struct PickyDiffReviewViewer: View {
    @StateObject private var store: DiffReviewStore

    init(source: DiffReviewSource) {
        _store = StateObject(wrappedValue: DiffReviewStore(source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DiffReviewTheme.borderDefault)
            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    sidebar
                        .frame(width: 330)
                    Divider().overlay(DiffReviewTheme.borderDefault)
                }
                AppKitDiffFilesChangedView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .background(DiffReviewTheme.canvasDefault)
        .foregroundStyle(DiffReviewTheme.fgDefault)
        .sheet(isPresented: $store.isSubmitReviewPresented) {
            SubmitDiffReviewSheet(store: store)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: { store.isSidebarVisible.toggle() }) {
                Image(systemName: store.isSidebarVisible ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(DiffReviewIconButtonStyle())
            .help(store.isSidebarVisible ? "Hide file tree" : "Show file tree")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Changed files")
                        .font(.system(size: 17, weight: .semibold))
                    Text(store.snapshot.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DiffReviewTheme.fgMuted)
                        .lineLimit(1)
                    if !store.snapshot.files.isEmpty {
                        Text("#PICKY")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DiffReviewTheme.fgSubtle)
                    }
                }
                HStack(spacing: 8) {
                    Text("All changes")
                        .font(.system(size: 13, weight: .semibold))
                    Text("·")
                        .foregroundStyle(DiffReviewTheme.fgSubtle)
                    Text(store.snapshot.subtitle)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DiffReviewTheme.fgMuted)
                    if !store.snapshot.repoRoot.isEmpty {
                        Text(store.snapshot.repoRoot)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(DiffReviewTheme.accentFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 14)

            Picker("Diff view", selection: $store.viewMode) {
                ForEach(DiffViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 168)

            HStack(spacing: 8) {
                DiffReviewProgressRing(progress: viewedProgress)
                    .frame(width: 16, height: 16)
                Text("\(store.viewedFileIDs.count) / \(store.snapshot.files.count) viewed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DiffReviewTheme.fgMuted)
            }

            Button {
                store.isSubmitReviewPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text("Submit review")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .buttonStyle(DiffReviewButtonStyle(kind: .primary))

            Button(action: { store.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(DiffReviewIconButtonStyle())
            .help("Refresh")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(DiffReviewTheme.canvasDefault)
    }

    private var viewedProgress: Double {
        guard !store.snapshot.files.isEmpty else { return 0 }
        return Double(store.viewedFileIDs.count) / Double(store.snapshot.files.count)
    }

    private var sidebar: some View {
        DiffReviewSidebar(store: store)
            .background(DiffReviewTheme.canvasDefault)
    }
}

@MainActor
final class PickyDiffReviewWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = PickyDiffReviewWindowPresenter()

    private var windows: [String: NSWindow] = [:]

    func open(cwd: String?) {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        let path = NSString(string: trimmed).standardizingPath
        let key = path

        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(CGFloat(1500), visibleFrame.width - 80)
        let height = min(CGFloat(980), visibleFrame.height - 80)
        let frame = NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2, width: width, height: height)

        let rootView = PickyDiffReviewViewer(source: DiffReviewSource(kind: .repository(URL(fileURLWithPath: path))))
            .preferredColorScheme(.dark)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Picky Diff Review"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1)
        window.level = .normal
        window.minSize = NSSize(width: 1180, height: 760)
        window.contentView = NSHostingView(rootView: rootView)
        window.delegate = self
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { _, window in window !== closing }
    }
}

private struct DiffReviewSidebar: View {
    @ObservedObject var store: DiffReviewStore
    @State private var collapsedDirectoryIDs: Set<String> = []

    private var nodes: [DiffReviewFileTreeNode] {
        DiffReviewFileTreeBuilder().build(files: store.filteredFiles)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DiffReviewTheme.fgSubtle)
                TextField("Filter files…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(DiffReviewTheme.canvasInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DiffReviewTheme.borderDefault, lineWidth: 1))
            .padding(.horizontal, 22)
            .padding(.top, 18)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        DiffReviewFileTreeRow(
                            store: store,
                            node: node,
                            depth: 0,
                            collapsedDirectoryIDs: $collapsedDirectoryIDs
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct DiffReviewFileTreeRow: View {
    @ObservedObject var store: DiffReviewStore
    let node: DiffReviewFileTreeNode
    let depth: Int
    @Binding var collapsedDirectoryIDs: Set<String>

    private var isCollapsed: Bool {
        store.searchText.isEmpty && collapsedDirectoryIDs.contains(node.id)
    }

    private var isSelected: Bool {
        node.file?.id == store.selectedFileID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if let file = node.file {
                    store.select(file)
                } else {
                    toggleDirectory()
                }
            } label: {
                HStack(spacing: 7) {
                    Spacer().frame(width: CGFloat(depth) * 16)
                    if node.file == nil {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DiffReviewTheme.fgMuted)
                            .frame(width: 12)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DiffReviewTheme.fgMuted)
                    } else if let file = node.file {
                        Spacer().frame(width: 12)
                        Image(systemName: file.status == .deleted ? "doc" : "doc.badge.plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(statusColor(file.status))
                            .frame(width: 16)
                    }
                    Text(node.name)
                        .font(.system(size: 14, weight: node.file == nil ? .medium : .regular))
                        .foregroundStyle(isSelected ? DiffReviewTheme.fgDefault : DiffReviewTheme.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .frame(height: 30)
                .padding(.horizontal, 8)
                .background(isSelected ? DiffReviewTheme.neutralMuted.opacity(0.34) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(node.children) { child in
                    DiffReviewFileTreeRow(store: store, node: child, depth: depth + 1, collapsedDirectoryIDs: $collapsedDirectoryIDs)
                }
            }
        }
    }

    private func toggleDirectory() {
        if collapsedDirectoryIDs.contains(node.id) {
            collapsedDirectoryIDs.remove(node.id)
        } else {
            collapsedDirectoryIDs.insert(node.id)
        }
    }

    private func statusColor(_ status: DiffFileStatus) -> Color {
        switch status {
        case .added: return DiffReviewTheme.successFg
        case .deleted: return DiffReviewTheme.dangerFg
        case .renamed, .copied: return DiffReviewTheme.accentFg
        case .modified: return DiffReviewTheme.attentionFg
        case .unknown: return DiffReviewTheme.fgSubtle
        }
    }
}

private struct DiffReviewFileTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    var file: DiffFile?
    var children: [DiffReviewFileTreeNode] = []
}

private struct DiffReviewFileTreeBuilder {
    func build(files: [DiffFile]) -> [DiffReviewFileTreeNode] {
        var root: [DiffReviewFileTreeNode] = []
        for file in files {
            insert(file: file, components: file.displayPath.split(separator: "/").map(String.init), into: &root, parentPath: "")
        }
        return root.sorted(by: sortNodes)
    }

    private func insert(file: DiffFile, components: [String], into nodes: inout [DiffReviewFileTreeNode], parentPath: String) {
        guard let first = components.first else { return }
        let id = parentPath.isEmpty ? first : "\(parentPath)/\(first)"
        if components.count == 1 {
            nodes.append(DiffReviewFileTreeNode(id: file.id, name: first, file: file))
            return
        }
        if let index = nodes.firstIndex(where: { $0.id == id && $0.file == nil }) {
            insert(file: file, components: Array(components.dropFirst()), into: &nodes[index].children, parentPath: id)
        } else {
            var child = DiffReviewFileTreeNode(id: id, name: first, file: nil, children: [])
            insert(file: file, components: Array(components.dropFirst()), into: &child.children, parentPath: id)
            nodes.append(child)
        }
    }

    private func sortNodes(_ lhs: DiffReviewFileTreeNode, _ rhs: DiffReviewFileTreeNode) -> Bool {
        if (lhs.file == nil) != (rhs.file == nil) { return lhs.file == nil }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct SubmitDiffReviewSheet: View {
    @ObservedObject var store: DiffReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Submit review")
                .font(.system(size: 18, weight: .semibold))
            TextEditor(text: $store.overallComment)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(height: 180)
                .background(DiffReviewTheme.canvasInset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DiffReviewTheme.borderDefault, lineWidth: 1))
            HStack {
                Spacer()
                Button("Copy prompt") { store.copyFeedbackPrompt() }
                    .buttonStyle(DiffReviewButtonStyle(kind: .secondary))
                Button("Done") { store.isSubmitReviewPresented = false }
                    .buttonStyle(DiffReviewButtonStyle(kind: .primary))
            }
        }
        .padding(18)
        .frame(width: 620, height: 320)
        .background(DiffReviewTheme.canvasDefault)
        .foregroundStyle(DiffReviewTheme.fgDefault)
    }
}

private struct DiffReviewProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(DiffReviewTheme.borderDefault, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(DiffReviewTheme.accentFg, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct DiffReviewButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(kind == .primary ? .white : DiffReviewTheme.fgDefault)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(kind == .primary ? Color.clear : DiffReviewTheme.borderDefault, lineWidth: 1))
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Color(hex: "#2c974b") : Color(hex: "#2ea043")
        case .secondary: return pressed ? DiffReviewTheme.neutralMuted.opacity(0.65) : DiffReviewTheme.btnBg
        }
    }
}

private struct DiffReviewIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DiffReviewTheme.fgMuted)
            .frame(width: 34, height: 34)
            .background(configuration.isPressed ? DiffReviewTheme.neutralMuted.opacity(0.65) : DiffReviewTheme.btnBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DiffReviewTheme.borderDefault, lineWidth: 1))
    }
}

private enum DiffReviewTheme {
    static let canvasDefault = Color(hex: "#0d1117")
    static let canvasSubtle = Color(hex: "#161b22")
    static let canvasInset = Color(hex: "#010409")
    static let borderDefault = Color(hex: "#30363d")
    static let fgDefault = Color(hex: "#e6edf3")
    static let fgMuted = Color(hex: "#8b949e")
    static let fgSubtle = Color(hex: "#6e7681")
    static let accentFg = Color(hex: "#58a6ff")
    static let successFg = Color(hex: "#3fb950")
    static let dangerFg = Color(hex: "#f85149")
    static let attentionFg = Color(hex: "#d29922")
    static let neutralMuted = Color(hex: "#6e7681").opacity(0.28)
    static let btnBg = Color(hex: "#21262d")
}
