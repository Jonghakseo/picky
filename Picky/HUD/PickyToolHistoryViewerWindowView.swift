import SwiftUI

struct PickyToolHistoryViewerWindowView: View {
    @ObservedObject var model: PickyToolHistoryViewerModel
    @State private var selectedCategories: Set<PickyToolHistoryCategory> = []
    @State private var failuresOnly = false
    @State private var query = ""
    @State private var showsSearch = false
    @State private var collapseGeneration = 0
    @FocusState private var isSearchFieldFocused: Bool

    private var filterResult: PickyToolHistoryFilterResult {
        PickyToolHistoryFilterPolicy.result(entries: model.entries, selectedCategories: selectedCategories,
                                            failuresOnly: failuresOnly, query: query)
    }

    private var hasActiveFilters: Bool {
        !selectedCategories.isEmpty || failuresOnly || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            header
            if showsSearch {
                TextField(L10n.t("hud.toolHistory.search.placeholder"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(PickyHUDTypography.bodyCompact)
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel(L10n.t("hud.toolHistory.search.accessibilityLabel"))
                    .padding(.horizontal, DS.Spacing.space4)
                    .onExitCommand { showsSearch = false; query = "" }
            }
            if hasActiveFilters {
                HStack {
                    Text(L10n.t("hud.toolHistory.filter.resultCount", Int64(filterResult.visibleCount), Int64(filterResult.totalCount)))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button(L10n.t("hud.toolHistory.filter.clear"), action: clearFilters)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Colors.accentText)
                }
                .font(PickyHUDTypography.status)
                .padding(.horizontal, DS.Spacing.space4)
            }
            ScrollView {
                if filterResult.entries.isEmpty {
                    Text(L10n.t(model.entries.isEmpty ? "hud.toolHistory.empty" : "hud.toolHistory.filter.empty"))
                        .font(PickyHUDTypography.body)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.space1) {
                        ForEach(filterResult.entries) { entry in
                            PickyToolHistoryEntryView(
                                entry: entry, workingDirectory: model.workingDirectory,
                                collapseGeneration: collapseGeneration,
                                loadDetail: { model.inlineDetail(toolCallID: entry.id) },
                                loadArguments: { model.inlineArguments(toolCallID: entry.id) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Spacing.space3)
                    .padding(.bottom, DS.Spacing.space3)
                }
            }
        }
        .background(DS.Colors.surface1)
        .background {
            Button(L10n.t("hud.toolHistory.search.accessibilityLabel")) {
                showsSearch = true
                isSearchFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.space2) {
            Text(model.title)
                .font(PickyHUDTypography.title)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.space2)
            if !model.initialScope.isWholeSession {
                Menu {
                    Button(L10n.t("hud.toolHistory.scope.turn")) { model.setScope(model.initialScope) }
                    Button(L10n.t("hud.toolHistory.scope.session")) { model.setScope(.session) }
                } label: {
                    Text(L10n.t(model.scope.isWholeSession ? "hud.toolHistory.scope.session" : "hud.toolHistory.scope.turn"))
                        .font(PickyHUDTypography.status)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button {
                showsSearch.toggle()
                if showsSearch { isSearchFieldFocused = true } else { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PickyToolHistoryQuietButtonStyle())
            .help(L10n.t("hud.toolHistory.search.accessibilityLabel"))
            .accessibilityLabel(L10n.t("hud.toolHistory.search.accessibilityLabel"))
            Menu {
                ForEach(PickyToolHistoryCategory.allHistoryCategories, id: \.self) { category in
                    Toggle(category.rawValue, isOn: Binding(
                        get: { selectedCategories.contains(category) },
                        set: { if $0 { selectedCategories.insert(category) } else { selectedCategories.remove(category) } }
                    ))
                }
                Divider()
                Toggle(L10n.t("hud.toolHistory.failuresOnly"), isOn: $failuresOnly)
                Button(L10n.t("hud.toolHistory.filter.clear"), action: clearFilters).disabled(!hasActiveFilters)
                Divider()
                Button(L10n.t("hud.toolHistory.collapseAll")) { collapseGeneration += 1 }
                Button(L10n.t("hud.toolHistory.refresh")) { model.reload() }
            } label: {
                Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(hasActiveFilters ? DS.Colors.accentText : DS.Colors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.t("hud.toolHistory.viewOptions"))
            .accessibilityLabel(L10n.t("hud.toolHistory.viewOptions"))
        }
        .padding(.horizontal, DS.Spacing.space4)
        .padding(.vertical, DS.Spacing.space2)
    }

    private func clearFilters() {
        selectedCategories.removeAll()
        failuresOnly = false
        query = ""
    }
}

private extension PickyToolHistoryCategory {
    static let allHistoryCategories: [Self] = [.read, .bash, .edit, .write, .other]
}
