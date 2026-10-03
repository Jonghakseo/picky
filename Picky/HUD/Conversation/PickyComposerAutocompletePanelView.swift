//
//  PickyComposerAutocompletePanelView.swift
//  Picky
//
//  Floating suggestion list above the composer. Pi's composed provider is the
//  single source for slash, path, and extension completions, so this view only
//  renders one already-resolved snapshot and reports the accepted item.
//

import SwiftUI

struct PickyComposerAutocompletePanelView: View {
    let snapshot: PickyAutocompleteSuggestionsSnapshot
    let selectedIndex: Int
    /// Resolved slash commands used to label and badge `/`-prefixed rows.
    let slashCommands: [PickySlashCommand]
    let onAccept: (PickyAutocompleteItem) -> Void

    var body: some View {
        suggestionList(selectedID: selectedIndex, suggestionCount: snapshot.items.count) {
            ForEach(Array(snapshot.items.enumerated()), id: \.offset) { index, item in
                Button { onAccept(item) } label: {
                    row(item, prefix: snapshot.prefix, isSelected: index == selectedIndex)
                }
                .buttonStyle(.plain)
                .id(index)
            }
        }
    }

    /// Keeps the full result set available to keyboard and pointer navigation
    /// while constraining the floating panel to four dense rows. ScrollViewReader
    /// reveals the keyboard-selected item without resizing the composer.
    private func suggestionList<SelectionID: Hashable, Content: View>(
        selectedID: SelectionID,
        suggestionCount: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: suggestionCount > PickySlashCommandAutocompletePolicy.maxVisibleRows) {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing, content: content)
            }
            .scrollDisabled(suggestionCount <= PickySlashCommandAutocompletePolicy.maxVisibleRows)
            .frame(maxHeight: .infinity)
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selectedID) { _, newSelectedID in
                proxy.scrollTo(newSelectedID, anchor: .center)
            }
        }
        .padding(DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.panelHeight(forSuggestionCount: suggestionCount), alignment: .top)
        .background(panelBackground)
    }

    private func row(_ item: PickyAutocompleteItem, prefix: String?, isSelected: Bool) -> some View {
        let command = matchingSlashCommand(for: item, prefix: prefix)
        let isFile = prefix?.hasPrefix("@") == true
        let isDirectory = isFile && item.label.hasSuffix("/")
        return HStack(alignment: .firstTextBaseline, spacing: Self.rowContentSpacing) {
            if isFile {
                Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                    .pickyFont(size: 10, weight: .semibold)
                    .foregroundColor(isDirectory ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: Self.fileIconWidth)
            }
            Text(command.map { "/\($0.name)" } ?? item.label)
                .font(PickyHUDTypography.labelMonospacedSemibold)
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            if let command {
                Text(command.source.displayName)
                    .font(PickyHUDTypography.minimumSemibold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, Self.badgeHorizontalPadding)
                    .padding(.vertical, Self.badgeVerticalPadding)
                    .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.rowContentSpacing)
        .padding(.vertical, Self.rowVerticalPadding)
        .frame(minHeight: Self.rowMinimumHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func matchingSlashCommand(for item: PickyAutocompleteItem, prefix: String?) -> PickySlashCommand? {
        guard prefix?.hasPrefix("/") == true else { return nil }
        return slashCommands.first { $0.name == item.value }
    }

    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
        return PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1)
            .overlay(shape.stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8) // design-token-exception: floating autocomplete panel elevation preserved from the shipped composer
    }

    /// Each row has a 24pt minimum height, separated by 1pt. The panel adds a
    /// 4pt inset above and below the scrollable rows.
    static func panelHeight(forSuggestionCount suggestionCount: Int) -> CGFloat {
        let visibleRows = min(max(suggestionCount, 0), PickySlashCommandAutocompletePolicy.maxVisibleRows)
        guard visibleRows > 0 else { return 0 }
        return CGFloat(visibleRows) * rowMinimumHeight
            + CGFloat(visibleRows - 1) * rowSpacing
            + 2 * panelVerticalInset
    }

    static let rowMinimumHeight: CGFloat = DS.Spacing.xxl
    static let rowSpacing: CGFloat = 1
    static let panelVerticalInset: CGFloat = DS.Spacing.xs
    private static let rowContentSpacing: CGFloat = 6
    private static let rowVerticalPadding: CGFloat = 4
    private static let badgeHorizontalPadding: CGFloat = 4
    private static let badgeVerticalPadding: CGFloat = 1
    private static let fileIconWidth: CGFloat = 14
}
