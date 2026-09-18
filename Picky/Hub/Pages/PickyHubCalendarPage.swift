import SwiftUI

/// The catalog owns installation. A missing job index is an empty calendar, not
/// evidence that the plugin is missing; never infer installation from jobs.json.
struct PickyHubCalendarPage: View {
    let dependencies: PickyHubDependencies
    @ObservedObject private var catalog: PickyHubPluginCatalogViewModel
    @ObservedObject private var navigator: PickyHubNavigator
    @ObservedObject private var reloadController: PickyPluginReloadController
    @State private var result: PickyCronJobReadResult?
    @State private var loadedHistoryInterval: DateInterval?
    @State private var visibleInterval = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _catalog = ObservedObject(wrappedValue: dependencies.pluginCatalog)
        _navigator = ObservedObject(wrappedValue: dependencies.navigator)
        _reloadController = ObservedObject(wrappedValue: dependencies.pluginReloadController)
    }

    private var plugin: PickyHubPluginItem? { catalog.item(id: "cron") }
    private var isActive: Bool { navigator.isWindowVisible && navigator.selectedPage == .calendar }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                HStack(alignment: .top) {
                    PickyHubPageHeader(title: "hub.nav.calendar", subtitle: "hub.calendar.subtitle")
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("extensions.cron.jobs.refresh"))
                    .accessibilityLabel(Text("extensions.cron.jobs.refresh"))
                }
                if let plugin {
                    if let error = plugin.errorMessage {
                        PickyHubInlineStatus(tone: .error, message: error)
                    }
                    if plugin.isInstalled {
                        if reloadController.hasPendingChanges {
                            PickyHubInlineStatus(
                                tone: .warning, message: L10n.t("hub.plugins.reload.message"),
                                actionTitle: "hub.calendar.apply", action: { navigator.select(.plugins) }
                            )
                        }
                        installedContent
                    } else {
                        installation(plugin)
                    }
                } else {
                    PickyHubEmptyState(
                        systemImage: "exclamationmark.triangle", title: "hub.calendar.unavailable",
                        message: "hub.calendar.unavailable.message", actionTitle: "extensions.cron.jobs.refresh",
                        action: refresh
                    )
                }
            }
            .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
            .padding(.top, PickyHubTheme.Layout.contentTopPadding)
            .padding(.bottom, PickyHubTheme.Spacing.group)
        }
        .task(id: isActive) {
            guard isActive else { return }
            catalog.refresh()
            while !Task.isCancelled {
                refreshJobs()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .onChange(of: plugin?.isInstalled) { _, _ in refreshJobs() }
    }

    private func installation(_ plugin: PickyHubPluginItem) -> some View {
        VStack(spacing: PickyHubTheme.Spacing.group) {
            PickyHubEmptyState(
                systemImage: "calendar.badge.plus", title: "hub.calendar.install.title",
                message: "hub.calendar.install.message"
            )
            VStack(spacing: PickyHubTheme.Spacing.related) {
                Text(plugin.title)
                    .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                Text(plugin.plugin.source)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .textSelection(.enabled)
                PickyHubButton(
                    title: plugin.errorMessage == nil ? "hub.calendar.install.action" : "hub.calendar.install.retry",
                    isBusy: plugin.isBusy, isEnabled: plugin.canInstall && !plugin.isBusy
                ) { catalog.install(plugin) }
                if let progress = plugin.progressMessage {
                    Text(progress).foregroundColor(PickyHubTheme.Colors.textSecondary)
                }
                Text("hub.calendar.install.note")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var installedContent: some View {
        switch result {
        case nil:
            ProgressView().frame(maxWidth: .infinity)
        case .missing, .empty:
            PickyHubEmptyState(
                systemImage: "calendar", title: "hub.calendar.empty.title",
                message: "hub.calendar.empty.message", actionTitle: "hub.calendar.conversation",
                action: { navigator.select(.conversation) }
            )
        case .jobs(let jobs):
            PickyHubCronCalendarView(
                jobs: jobs,
                readPrompt: { occurrence in
                    PickyCronJobContentReader(cronDirectory: reader.jobsURL.deletingLastPathComponent())
                        .readInstructions(for: occurrence.job, executionDate: occurrence.kind == .actual ? occurrence.date : nil)
                },
                loadedHistoryInterval: loadedHistoryInterval,
                onVisibleIntervalChange: { interval in
                    guard interval != visibleInterval else { return }
                    visibleInterval = interval
                    refreshJobs()
                }
            )
        case .malformed:
            readError("extensions.cron.jobs.malformed.title", "extensions.cron.jobs.malformed.description")
        case .unsupportedVersion:
            readError("hub.calendar.unsupported", "hub.calendar.unsupported.message")
        case .unreadable:
            readError("extensions.cron.jobs.unreadable.title", "extensions.cron.jobs.unreadable.description")
        }
    }

    private func readError(_ title: LocalizedStringKey, _ message: LocalizedStringKey) -> some View {
        PickyHubEmptyState(
            systemImage: "exclamationmark.triangle", title: title, message: message,
            actionTitle: "extensions.cron.jobs.refresh", action: refresh
        )
    }

    private func refresh() {
        catalog.refresh()
        refreshJobs()
    }

    private var reader: PickyCronJobReader {
        PickyCronJobReader(preferences: PickyPiInstallation.preferences(from: dependencies.settingsStore.load()))
    }

    private func refreshJobs() {
        guard plugin?.isInstalled == true else { result = nil; return }
        result = reader.readCalendar(interval: visibleInterval)
        loadedHistoryInterval = visibleInterval
    }
}
