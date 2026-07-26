import SwiftUI

/// The Top Peek panel's expanded readout: every starred metric with its meter, value, and reset time,
/// over a refresh-status header and the two ways out of the panel.
///
/// Deliberately not a second dashboard. It shows the starred set and nothing else; anything past a
/// glance is one click away in the popover, which is the surface that owns depth.
struct DynamicIslandExpandedView: View {
    @Environment(AppContainer.self) private var container
    let content: DynamicIslandContent
    let actions: DynamicIslandActions

    private static let meterHeight: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Reset times are relative ("Resets in 2h 14m"), so they need a clock. This ticks only while
            // the panel is expanded — the compact pill and the hidden panel mount no timeline at all,
            // which is what keeps an always-armed overlay off the CPU while nobody is looking at it.
            // The rows are the only part that gives: header and footer keep their size, so a starred list
            // taller than the screen scrolls instead of pushing "Open superUsage" and "Settings" out of
            // the panel — which on a surface that never takes keyboard focus would put them out of reach
            // entirely. It only scrolls when it has to; short lists still size the panel to their content.
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    rows(now: context.date)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("superUsage")
                .font(.caption.weight(.semibold))
            if errorCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.notice)
            }
            Spacer(minLength: 8)
            refreshStatus
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The refresh countdown doubles as the refresh button, the same idiom the popover footer uses — so
    /// the one piece of status worth acting on is the thing you click.
    private var refreshStatus: some View {
        Button { refreshNow() } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Text(statusText(now: context.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .disabled(isRefreshing)
    }

    private var isRefreshing: Bool {
        !container.dataStore.refreshingProviderIDs.isEmpty
    }

    /// Providers whose latest refresh failed. Surfaced as a count-free triangle beside the name: the
    /// panel's job is to say "something needs you", and the popover carries the reason.
    private var errorCount: Int {
        container.dataStore.providerErrors.count
    }

    private func statusText(now: Date) -> String {
        if isRefreshing { return "Updating…" }
        let base = container.dataStore.lastRefreshAt ?? now
        let remaining = max(0, base.addingTimeInterval(RefreshSetting.interval).timeIntervalSince(now))
        let seconds = Int(remaining.rounded(.up))
        if seconds >= 60 {
            return "Next update in \(Int((Double(seconds) / 60).rounded(.up)))m"
        }
        return "Next update in \(seconds)s"
    }

    private func refreshNow() {
        guard !isRefreshing else { return }
        Task { await container.dataStore.refreshAll(force: true) }
    }

    // MARK: - Rows

    private func rows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(content.groups) { group in
                ForEach(group.metrics) { metric in
                    row(group: group, metric: metric, now: now)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func row(
        group: DynamicIslandContent.Group,
        metric: DynamicIslandContent.Metric,
        now: Date
    ) -> some View {
        let data = metric.data
        let state = data.meterState(now: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderIcon(source: group.icon, inset: 0.05)
                    .frame(width: 12, height: 12)
                Text(group.displayName)
                    .font(.caption)
                Text(metric.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(data.headline)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .lineLimit(1)
            if data.isBounded {
                meter(fraction: data.fraction, severity: state.severity)
            }
            if let trailing = data.boundedTrailingText(now: now) {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The dashboard's capsule meter at peek scale: same shape, same system severity colors, minus the
    /// pace tick and its hover copy — detail that belongs on the row you opened deliberately, not on a
    /// panel you glanced at. `.quaternary` for the track, so it stays vibrant over a material surface.
    private func meter(fraction: Double, severity: WidgetData.MeterSeverity?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary))
                    .frame(width: fillWidth(track: proxy.size.width, fraction: fraction))
            }
        }
        .frame(height: Self.meterHeight)
        .animation(Motion.spring, value: fraction)
        .accessibilityHidden(true)
    }

    /// Any non-zero fraction draws at least a full circle, so 1–2% reads as "barely started" instead of
    /// vanishing into the track. Mirrors the dashboard meter's minimum-visible rule.
    private func fillWidth(track: CGFloat, fraction: Double) -> CGFloat {
        guard fraction > 0 else { return 0 }
        return max(Self.meterHeight, track * fraction)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open superUsage") { actions.openDashboard() }
                .frame(maxWidth: .infinity)
            Button("Settings") { actions.openSettings() }
        }
        .glassButtonStyle()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
