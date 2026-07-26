import Foundation

/// Resolved, ordered data for the Top Peek panel: the same starred metrics the menu-bar strip shows,
/// but carrying each metric's full `WidgetData` rather than a baked display string.
///
/// The strip only ever needs a value to draw beside the icon, so `MenuBarContent` flattens to strings.
/// The peek panel draws meters, pace colors, and reset times too, so it keeps the whole row and lets the
/// view ask for what it needs. The *selection* rule is deliberately identical to the strip's, so the two
/// surfaces can never disagree about which metrics are worth showing: a metric with no data yet is
/// dropped, and a provider whose starred metrics all lack data drops out entirely rather than leaving an
/// orphan icon behind.
struct DynamicIslandContent: Equatable {
    struct Metric: Equatable, Identifiable {
        /// Descriptor id.
        let id: String
        /// Metric label, e.g. "Session".
        let label: String
        let data: WidgetData
    }

    struct Group: Equatable, Identifiable {
        /// Provider id.
        let id: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
    }

    let groups: [Group]

    /// How many metrics were starred before the has-data filter ran. Kept because `groups.isEmpty` alone
    /// cannot tell "you haven't starred anything" from "your stars haven't loaded yet" — two states that
    /// need opposite things said about them, and only one of which is fixed in Customize.
    let starredCount: Int

    /// Nothing is starred, every starred provider is turned off, or no starred metric has data yet.
    var isEmpty: Bool { groups.isEmpty }

    /// True when something is starred but nothing survived the has-data filter — loading, or every
    /// starred provider failing at once.
    var isAwaitingData: Bool { groups.isEmpty && starredCount > 0 }

    /// Every metric across all groups, flattened in display order.
    var metrics: [Metric] { groups.flatMap(\.metrics) }

    /// VoiceOver summary for the compact pill, e.g. "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    /// Mirrors `MenuBarContent.accessibilityText` so the two surfaces read the same aloud.
    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.data.menuBarValue)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum DynamicIslandContentBuilder {
    /// Resolve starred provider groups into peek-panel content. `groups` is `LayoutStore.pinnedGroups`
    /// (already ordered, disabled providers excluded) and `data` resolves each descriptor to its live
    /// `WidgetData` — the same two inputs `MenuBarContentBuilder` takes, for the same reason: the peek
    /// panel is a second view of the starred set, not a second definition of it.
    static func build(
        groups: [ProviderMetrics],
        data: (WidgetDescriptor) -> WidgetData,
        title: (Provider) -> String = { $0.displayName }
    ) -> DynamicIslandContent {
        let resolved = groups.compactMap { group -> DynamicIslandContent.Group? in
            let metrics = group.metrics
                .map { DynamicIslandContent.Metric(id: $0.id, label: $0.metricLabel, data: data($0)) }
                .filter(\.data.hasData)
            guard !metrics.isEmpty else { return nil }
            return DynamicIslandContent.Group(
                id: group.provider.id,
                displayName: title(group.provider),
                icon: group.provider.icon,
                metrics: metrics
            )
        }
        return DynamicIslandContent(
            groups: resolved,
            starredCount: groups.reduce(0) { $0 + $1.metrics.count }
        )
    }
}
