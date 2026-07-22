import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PickyRecentPickleFolderPolicy {
    static func visibleCwds(_ cwds: [String], exists: (String) -> Bool) -> [String] {
        visibleRecentCwds(cwds, pinned: [], exists: exists)
    }

    static func visiblePinnedCwds(_ pinnedCwds: [String], exists: (String) -> Bool) -> [String] {
        pinnedCwds.filter(exists)
    }

    static func visibleRecentCwds(_ recentCwds: [String], pinned pinnedCwds: [String], exists: (String) -> Bool) -> [String] {
        let visiblePinned = visiblePinnedCwds(pinnedCwds, exists: exists)
        let pinned = Set(pinnedCwds)
        let limit = visiblePinned.isEmpty
            ? PickySettings.maxVisibleRecentPickleCwds
            : PickySettings.maxVisibleRecentPickleCwdsWhenPinned
        return Array(recentCwds.filter { exists($0) && !pinned.contains($0) }.prefix(limit))
    }
}

extension View {
    func recentPickleFolderPicker(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        pinnedPickleCwds: [String],
        recentPickleCwds: [String],
        onCreatePickleInRecentFolder: @escaping (String) -> Void,
        onChooseFolder: @escaping () -> Void,
        onRemoveRecentPickleFolder: @escaping (String) -> Void,
        onPinPickleFolder: @escaping (String) -> Void,
        onUnpinPickleFolder: @escaping (String) -> Void,
        onReorderPinnedPickleFolders: @escaping ([String]) -> Void = { _ in },
        availableSessionsForGroupCreation: [PickySessionListViewModel.SessionCard] = [],
        suggestedGroupColor: PickyDockGroupColor = .teal,
        onCreateGroup: ((_ name: String, _ memberIDs: [String]) -> Void)? = nil
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            PickyRecentPickleFolderPickerView(
                isPresented: isPresented,
                pinnedPickleCwds: pinnedPickleCwds,
                recentPickleCwds: recentPickleCwds,
                onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
                onChooseFolder: onChooseFolder,
                onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
                onPinPickleFolder: onPinPickleFolder,
                onUnpinPickleFolder: onUnpinPickleFolder,
                onReorderPinnedPickleFolders: onReorderPinnedPickleFolders,
                availableSessionsForGroupCreation: availableSessionsForGroupCreation,
                suggestedGroupColor: suggestedGroupColor,
                onCreateGroup: onCreateGroup
            )
        }
    }
}

struct PickyRecentPickleFolderPickerView: View {
    @Binding var isPresented: Bool
    let pinnedPickleCwds: [String]
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (String) -> Void
    let onChooseFolder: () -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    let onPinPickleFolder: (String) -> Void
    let onUnpinPickleFolder: (String) -> Void
    let onReorderPinnedPickleFolders: ([String]) -> Void
    let availableSessionsForGroupCreation: [PickySessionListViewModel.SessionCard]
    let suggestedGroupColor: PickyDockGroupColor
    let onCreateGroup: ((_ name: String, _ memberIDs: [String]) -> Void)?

    /// Popover mode. Default flow shows the folder picker; tapping
    /// "New Group" swaps the same popover to the creator dialog so the
    /// user picks a name and initial members in one step instead of
    /// being kicked into an inline rename of an empty group.
    @State private var isShowingGroupCreator = false

    /// Local, mutable copy of the pinned order so drag reordering animates
    /// smoothly while the popover is open. The persisted order is committed via
    /// `onReorderPinnedPickleFolders` when a drag finishes; `pinnedPickleCwds`
    /// stays the source of truth and re-syncs this copy on change.
    @State private var pinnedOrder: [String] = []
    @State private var draggingPinnedCwd: String?

    var body: some View {
        if isShowingGroupCreator, let onCreateGroup {
            PickyDockGroupCreatorView(
                availableSessions: availableSessionsForGroupCreation,
                suggestedColor: suggestedGroupColor,
                onCreate: { name, memberIDs in
                    isShowingGroupCreator = false
                    isPresented = false
                    onCreateGroup(name, memberIDs)
                },
                onCancel: {
                    isShowingGroupCreator = false
                }
            )
        } else {
            folderPickerContent
        }
    }

    private var folderPickerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if pinnedPickleCwds.isEmpty, recentPickleCwds.isEmpty {
                emptyState
            } else {
                folderList
            }
            Divider()
            Button {
                isPresented = false
                onChooseFolder()
            } label: {
                Label(L10n.t("dock.recentFolders.chooseFolder"), systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)
            .accessibilityHint(L10n.t("dock.recentFolders.chooseFolder.hint"))
            if onCreateGroup != nil {
                Button {
                    isShowingGroupCreator = true
                } label: {
                    Label(L10n.t("dock.recentFolders.newGroup"), systemImage: "folder.badge.gearshape")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 2)
                .accessibilityHint(L10n.t("dock.recentFolders.newGroup.hint"))
            }
        }
        .padding(14)
        .frame(width: 286)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("dock.recentFolders.title"))
                .pickyFont(size: 14, weight: .medium)
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Text(L10n.t("dock.startPickle"))
                .pickyFont(size: 11, weight: .medium)
                .foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private var folderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !pinnedPickleCwds.isEmpty {
                    sectionTitle(L10n.t("dock.recentFolders.pinned.title"), systemImage: "pin.fill")
                    VStack(spacing: 2) {
                        ForEach(pinnedOrder, id: \.self) { cwd in
                            PickyRecentPickleFolderRow(
                                cwd: cwd,
                                isPinned: true,
                                isReorderable: pinnedOrder.count > 1,
                                isDragging: draggingPinnedCwd == cwd,
                                onCreate: {
                                    isPresented = false
                                    onCreatePickleInRecentFolder(cwd)
                                },
                                onPin: {},
                                onUnpin: {
                                    onUnpinPickleFolder(cwd)
                                },
                                onRemove: {}
                            )
                            .onDrag {
                                draggingPinnedCwd = cwd
                                return NSItemProvider(object: cwd as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: PickyPinnedFolderReorderDropDelegate(
                                    item: cwd,
                                    order: $pinnedOrder,
                                    dragging: $draggingPinnedCwd,
                                    onCommit: { onReorderPinnedPickleFolders(pinnedOrder) }
                                )
                            )
                        }
                    }
                }

                if !pinnedPickleCwds.isEmpty, !recentPickleCwds.isEmpty {
                    Divider()
                        .padding(.vertical, 2)
                }

                if !recentPickleCwds.isEmpty {
                    if !pinnedPickleCwds.isEmpty {
                        sectionTitle(L10n.t("dock.recentFolders.recent.title"), systemImage: "clock")
                    }
                    VStack(spacing: 2) {
                        ForEach(recentPickleCwds, id: \.self) { cwd in
                            PickyRecentPickleFolderRow(
                                cwd: cwd,
                                isPinned: false,
                                onCreate: {
                                    isPresented = false
                                    onCreatePickleInRecentFolder(cwd)
                                },
                                onPin: {
                                    onPinPickleFolder(cwd)
                                },
                                onUnpin: {},
                                onRemove: {
                                    onRemoveRecentPickleFolder(cwd)
                                }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 320)
        .onAppear { pinnedOrder = pinnedPickleCwds }
        .onChange(of: pinnedPickleCwds) { _, newValue in
            if draggingPinnedCwd == nil { pinnedOrder = newValue }
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .pickyFont(size: 11, weight: .semibold)
            .foregroundStyle(DS.Colors.textTertiary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        Text(L10n.t("dock.recentFolders.empty"))
            .pickyFont(size: 12)
            .foregroundStyle(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}

private struct PickyRecentPickleFolderRow: View {
    let cwd: String
    let isPinned: Bool
    var isReorderable: Bool = false
    var isDragging: Bool = false
    let onCreate: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCreate) {
                HStack(spacing: 9) {
                    Image(systemName: isPinned ? "folder.fill" : "folder")
                        .pickyFont(size: 14, weight: .medium)
                        .foregroundStyle(DS.Colors.accentText)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .pickyFont(size: 13, weight: .medium)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(compactPath)
                            .pickyFont(size: 11)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("dock.startPickleIn", displayName))
            .accessibilityHint(compactPath)

            if isPinned {
                if isReorderable {
                    reorderHandle
                }
                rowActionButton(
                    systemImage: "pin.slash",
                    accessibilityLabel: L10n.t("dock.recentFolders.unpin"),
                    accessibilityHint: L10n.t("dock.recentFolders.unpin.hint"),
                    action: onUnpin
                )
            } else {
                rowActionButton(
                    systemImage: "pin",
                    accessibilityLabel: L10n.t("dock.recentFolders.pin"),
                    accessibilityHint: L10n.t("dock.recentFolders.pin.hint"),
                    action: onPin
                )
                rowActionButton(
                    systemImage: "xmark",
                    accessibilityLabel: L10n.t("dock.recentFolders.remove"),
                    accessibilityHint: L10n.t("dock.recentFolders.remove.hint"),
                    action: onRemove
                )
            }
        }
        .background(isHovered ? DS.Colors.surface2 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .opacity(isDragging ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .pickyFont(size: 10, weight: .medium)
            .foregroundStyle(DS.Colors.textTertiary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .opacity(isHovered ? 0.9 : 0.35)
            .help(L10n.t("dock.recentFolders.reorder.hint"))
            .accessibilityLabel(L10n.t("dock.recentFolders.reorder"))
            .accessibilityHint(L10n.t("dock.recentFolders.reorder.hint"))
    }

    private func rowActionButton(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .pickyFont(size: 10, weight: .medium)
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var displayName: String {
        let last = URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    private var compactPath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardizedPath = NSString(string: cwd).standardizingPath
        if standardizedPath == homePath { return "~" }
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return cwd
    }
}

/// Reorders the pinned-folder list as a dragged row hovers over its peers.
/// The visual order is mutated locally on `dropEntered`; the final order is
/// persisted once, on `performDrop`, so a single reorder produces a single
/// settings write.
private struct PickyPinnedFolderReorderDropDelegate: DropDelegate {
    let item: String
    @Binding var order: [String]
    @Binding var dragging: String?
    let onCommit: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onCommit()
        return true
    }
}
