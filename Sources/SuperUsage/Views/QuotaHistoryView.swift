import SwiftUI

/// The Usage History window: pick a provider and one of its capped metrics, pick a range, and see how
/// the remaining quota moved.
///
/// This lives in its own window rather than in the menu-bar panel because the panel is a narrow glance
/// surface — the dashboard answers "how much is left now", and a trend needs room for an axis, a range
/// switcher, and a readout without crowding any of them.
struct QuotaHistoryView: View {
    @Environment(AppContainer.self) private var container

    @State private var scopes: [QuotaHistoryDisplayScope] = []
    @State private var selectedScopeKey: String?
    @State private var range: QuotaHistoryRange = .day
    @State private var series: QuotaHistorySeries = .empty
    @State private var hasLoadedScopes = false

    /// The window re-reads on this beat so a chart left open keeps growing with each refresh pass,
    /// instead of freezing at whatever was on record when it opened.
    private static let reloadInterval: TimeInterval = RefreshSetting.interval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 400)
        .task {
            await loadScopes()
            await reloadLoop()
        }
        .task(id: reloadKey) { await loadSeries() }
    }

    /// Changing either of these means the chart is showing the wrong thing until it reloads.
    private var reloadKey: String { "\(selectedScopeKey ?? "")|\(range.rawValue)" }

    private var selectedScope: QuotaHistoryDisplayScope? {
        scopes.first { $0.scopeKey == selectedScopeKey }
    }

    private var providers: [Provider] {
        var seen: Set<String> = []
        return scopes.compactMap { seen.insert($0.providerID).inserted ? $0.provider : nil }
    }

    private var metricsForSelectedProvider: [QuotaHistoryDisplayScope] {
        guard let providerID = selectedScope?.providerID else { return [] }
        return scopes.filter { $0.providerID == providerID }
    }

    // MARK: - Chrome

    private var controls: some View {
        HStack(spacing: 10) {
            providerPicker
            metricPicker
            Spacer(minLength: 12)
            rangePicker
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(scopes.isEmpty)
    }

    private var providerPicker: some View {
        Picker("Provider", selection: providerSelection) {
            ForEach(providers) { provider in
                Text(container.displayName(for: provider)).tag(provider.id)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Switching provider has to move the metric selection too — the previous metric belongs to the old
    /// provider and would leave the chart showing a series the pickers no longer describe.
    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedScope?.providerID ?? providers.first?.id ?? "" },
            set: { providerID in
                selectedScopeKey = scopes.first { $0.providerID == providerID }?.scopeKey
            }
        )
    }

    private var metricPicker: some View {
        Picker("Metric", selection: Binding(
            get: { selectedScopeKey ?? "" },
            set: { selectedScopeKey = $0 }
        )) {
            ForEach(metricsForSelectedProvider) { scope in
                Text(scope.metricTitle).tag(scope.scopeKey)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(QuotaHistoryRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let failure = container.quotaHistory.openFailure {
            message(
                icon: "exclamationmark.triangle",
                title: "History Unavailable",
                detail: failure
            )
        } else if !hasLoadedScopes {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scopes.isEmpty {
            message(
                icon: "chart.xyaxis.line",
                title: "No History Yet",
                detail: """
                superUsage records a point for every metric with a limit each time it refreshes, \
                about every \(RefreshSetting.defaultMinutes) minutes. Leave it running and the trend \
                fills in.
                """
            )
        } else if series.isEmpty {
            message(
                icon: "clock.badge.questionmark",
                title: "Nothing in This Range",
                detail: "No successful refresh landed in the last \(range.title) for this metric."
            )
        } else {
            chart
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuotaHistoryChart(
                series: series,
                kind: series.format.metricKind,
                countSuffix: series.format.countSuffix
            )
            footnote
        }
        .padding(16)
    }

    /// Names the things the chart draws differently from consumption, so a dashed rule or a break in the
    /// line reads as deliberate rather than as a rendering glitch.
    private var footnote: some View {
        HStack(spacing: 14) {
            if !series.resets.isEmpty {
                Label("\(series.resets.count) reset\(series.resets.count == 1 ? "" : "s")", systemImage: "arrow.counterclockwise")
            }
            if !series.gaps.isEmpty {
                Label(
                    "\(series.gaps.count) gap\(series.gaps.count == 1 ? "" : "s") with no successful refresh",
                    systemImage: "wave.3.right"
                )
            }
            Spacer(minLength: 0)
            Text("\(series.points.count) point\(series.points.count == 1 ? "" : "s")")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Loading

    private func loadScopes() async {
        let loaded = await container.quotaHistory.scopes()
        scopes = loaded
        hasLoadedScopes = true
        // Keep the current selection when it survived the reload; otherwise fall back to the series with
        // the most recent activity, which is what the user most likely came to look at.
        if selectedScopeKey == nil || !loaded.contains(where: { $0.scopeKey == selectedScopeKey }) {
            selectedScopeKey = loaded.first?.scopeKey
        }
    }

    private func loadSeries() async {
        guard let selectedScopeKey else {
            series = .empty
            return
        }
        series = await container.quotaHistory.series(scopeKey: selectedScopeKey, range: range)
    }

    /// Re-reads on the refresh cadence for as long as the window is open. `task` cancels this when the
    /// view goes away, so a closed window stops touching the database.
    private func reloadLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.reloadInterval))
            guard !Task.isCancelled else { return }
            await loadScopes()
            await loadSeries()
        }
    }
}
