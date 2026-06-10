import AppKit
import Combine
import SwiftUI

struct PickyRecentPickleFolderPolicy {
    static func visibleCwds(_ cwds: [String], exists: (String) -> Bool) -> [String] {
        Array(cwds.filter(exists).prefix(PickySettings.maxVisibleRecentPickleCwds))
    }
}

extension View {
    func recentPickleFolderPicker(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        recentPickleCwds: [String],
        onCreatePickleInRecentFolder: @escaping (String) -> Void,
        onChooseFolder: @escaping () -> Void,
        onRemoveRecentPickleFolder: @escaping (String) -> Void,
        availableSessionsForGroupCreation: [PickySessionListViewModel.SessionCard] = [],
        suggestedGroupColor: PickyDockGroupColor = .teal,
        onCreateGroup: ((_ name: String, _ memberIDs: [String]) -> Void)? = nil
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            PickyRecentPickleFolderPickerView(
                isPresented: isPresented,
                recentPickleCwds: recentPickleCwds,
                onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
                onChooseFolder: onChooseFolder,
                onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
                availableSessionsForGroupCreation: availableSessionsForGroupCreation,
                suggestedGroupColor: suggestedGroupColor,
                onCreateGroup: onCreateGroup
            )
        }
    }
}

struct PickyRecentPickleFolderPickerView: View {
    @Binding var isPresented: Bool
    let recentPickleCwds: [String]
    let onCreatePickleInRecentFolder: (String) -> Void
    let onChooseFolder: () -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    let availableSessionsForGroupCreation: [PickySessionListViewModel.SessionCard]
    let suggestedGroupColor: PickyDockGroupColor
    let onCreateGroup: ((_ name: String, _ memberIDs: [String]) -> Void)?

    /// Popover mode. Default flow shows the folder picker; tapping
    /// "New Group" swaps the same popover to the creator dialog so the
    /// user picks a name and initial members in one step instead of
    /// being kicked into an inline rename of an empty group.
    @State private var isShowingGroupCreator = false

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
            if recentPickleCwds.isEmpty {
                emptyState
            } else {
                VStack(spacing: 2) {
                    ForEach(recentPickleCwds, id: \.self) { cwd in
                        PickyRecentPickleFolderRow(
                            cwd: cwd,
                            onCreate: {
                                isPresented = false
                                onCreatePickleInRecentFolder(cwd)
                            },
                            onRemove: {
                                onRemoveRecentPickleFolder(cwd)
                            }
                        )
                    }
                }
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
    let onCreate: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCreate) {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
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

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .pickyFont(size: 10, weight: .medium)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.35)
            .accessibilityLabel("Remove from recent folders")
            .accessibilityHint("This does not delete the folder")
        }
        .background(isHovered ? DS.Colors.surface2 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
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
