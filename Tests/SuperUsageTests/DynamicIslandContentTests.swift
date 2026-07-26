import XCTest
@testable import SuperUsage

/// Covers `DynamicIslandContentBuilder`: the Top Peek panel resolves the same starred set the menu-bar
/// strip does — same order, same drop rules — while keeping each metric's full `WidgetData` so the panel
/// can draw meters and reset times the strip has no room for.
@MainActor
final class DynamicIslandContentTests: XCTestCase {
    func testEmptyWhenNothingIsStarred() {
        let content = DynamicIslandContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.metrics.isEmpty)
    }

    func testGroupsPreserveOrderAndLabels() {
        let content = DynamicIslandContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12)),
                group("b", percent("b.m1", "Total", 50))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.id), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(content.metrics.map(\.id), ["a.m1", "a.m2", "b.m1"])
    }

    func testMetricsKeepTheirFullDataRatherThanABakedString() {
        // The whole reason this doesn't reuse `MenuBarContent`: the panel draws a meter, so it needs the
        // limit and the fraction, not just a value to print.
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41))],
            data: { $0.sample }
        )
        let data = content.groups[0].metrics[0].data
        XCTAssertTrue(data.isBounded)
        XCTAssertEqual(data.limit, 100)
        XCTAssertEqual(data.fraction, 0.41, accuracy: 0.001)
    }

    func testMetricsWithoutDataAreDropped() {
        // Same rule as the strip: a starred metric with nothing fetched yet is skipped rather than
        // shown as an em dash.
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly"))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
    }

    func testProvidersWithNoLiveMetricsDropEntirely() {
        // No orphan icons: a provider whose starred metrics all lack data contributes nothing.
        let content = DynamicIslandContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41)),
                group("b", noDataPercent("b.nd", "Weekly"))
            ],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups.map(\.id), ["a"])
    }

    func testEmptyWhenEveryStarredMetricLacksData() {
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "Session"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAwaitingDataIsDistinctFromNothingStarred() {
        // Both render as an empty panel, but they need opposite things said about them: one is fixed in
        // Customize, the other is fixed by waiting. Telling a user with stars to go star something is
        // both wrong and unactionable.
        let unstarred = DynamicIslandContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(unstarred.isEmpty)
        XCTAssertFalse(unstarred.isAwaitingData)
        XCTAssertEqual(unstarred.starredCount, 0)

        let loading = DynamicIslandContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "Session"), noDataPercent("a.nd2", "Weekly"))],
            data: { $0.sample }
        )
        XCTAssertTrue(loading.isEmpty)
        XCTAssertTrue(loading.isAwaitingData)
        XCTAssertEqual(loading.starredCount, 2)
    }

    func testAwaitingDataIsFalseOnceAnythingHasData() {
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly"))],
            data: { $0.sample }
        )
        XCTAssertFalse(content.isAwaitingData)
        // Counts what was starred, not what survived — that is the whole point of keeping it.
        XCTAssertEqual(content.starredCount, 2)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testAccessibilityTextUsesTheResolvedTitle() {
        // A renamed account card must read aloud under its new name, like every other surface.
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41))],
            data: { $0.sample },
            title: { _ in "Claude Team" }
        )
        XCTAssertEqual(content.accessibilityText, "Claude Team Session 41%")
    }

    func testLabelsAreNotShortenedLikeTheTray() {
        // The strip abbreviates "Last 30 Days" to "M" to stay narrow. The panel has room for the real
        // name, so it must not inherit the tray's shortening.
        let content = DynamicIslandContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Today", "Last 30 Days"])
    }

    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(
            id: providerID,
            displayName: providerID.uppercased(),
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
