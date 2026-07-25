import XCTest
@testable import SuperUsage

/// What gets written into the quota-history log — and, just as importantly, what doesn't. A metric that
/// slips in with a bogus limit, or an error snapshot that records a point, produces a chart that lies
/// about the user's burn rate, and neither is visible until someone reads the chart days later.
final class QuotaSampleExtractorTests: XCTestCase {
    private let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private var sessionDescriptor: WidgetDescriptor {
        .percent(id: "claude.session", provider: provider, title: "Session")
    }

    private var extraDescriptor: WidgetDescriptor {
        .boundedDollars(id: "claude.extra", provider: provider, title: "Extra Usage", limit: 50)
    }

    func testSamplesCappedMetricsWithStableDescriptorIDs() {
        let resetsAt = capturedAt.addingTimeInterval(3_600)
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent, resetsAt: resetsAt),
                .progress(label: "Extra Usage", used: 12.5, limit: 50, format: .dollars)
            ],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor, extraDescriptor],
            capturedAt: capturedAt
        )

        XCTAssertEqual(samples.count, 2)
        let session = samples[0]
        // The stable descriptor id, not the display label — a metric reworded in a later release must
        // stay the same series rather than starting a new one.
        XCTAssertEqual(session.metricID, "claude.session")
        XCTAssertEqual(session.scopeKey, "claude|claude.session")
        XCTAssertEqual(session.used, 40)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.resetsAt, resetsAt)
        XCTAssertEqual(session.remainingFraction, 0.6)

        XCTAssertEqual(samples[1].scopeKey, "claude|claude.extra")
        XCTAssertEqual(samples[1].remainingFraction, 0.75)
        XCTAssertNil(samples[1].resetsAt)
    }

    /// A failed refresh has to leave a gap. Recording the error snapshot would instead plant a point,
    /// making "we couldn't look" indistinguishable from "the quota stopped moving".
    func testErrorSnapshotProducesNoSamples() {
        let snapshot = ProviderSnapshot.error(provider: provider, message: "Not logged in")

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor],
            capturedAt: capturedAt
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// Unbounded rows, charts, and badges have no remaining-quota story; sampling them would chart a
    /// denominator that doesn't exist.
    func testSkipsUnboundedAndNonProgressLines() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [
                .values(label: "Today", values: [MetricValue(number: 4.08, kind: .dollars)]),
                .badge(label: "Plan", text: "Max"),
                .chart(label: "Usage Trend", points: [MetricChartPoint(value: 1, label: "Jul 1")])
            ],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [
                .values(id: "claude.today", provider: provider, title: "Today"),
                .badge(id: "claude.plan", provider: provider, title: "Plan"),
                .usageTrend(provider: provider)
            ],
            capturedAt: capturedAt
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// A zero or non-finite limit is not a usable denominator. Charting it would render as a hard 0% or
    /// 100% that the provider never actually reported.
    func testSkipsUnusableLimits() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [
                .progress(label: "Session", used: 10, limit: 0, format: .percent),
                .progress(label: "Extra Usage", used: 10, limit: .nan, format: .dollars)
            ],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor, extraDescriptor],
            capturedAt: capturedAt
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// The stored point has to match the meter the user saw. The dashboard clamps an out-of-range
    /// percent at its single construction choke point, so the extractor clamps identically — otherwise
    /// the chart and the bar would disagree about the same refresh.
    func testClampsOutOfRangePercentLikeTheDashboard() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 137, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor],
            capturedAt: capturedAt
        )

        XCTAssertEqual(samples.first?.used, 100)
        XCTAssertEqual(samples.first?.remainingFraction, 0)
    }

    /// A dollar overage is real information, so it survives where a percent overage is clamped.
    func testKeepsDollarOverage() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Extra Usage", used: 62, limit: 50, format: .dollars)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [extraDescriptor],
            capturedAt: capturedAt
        )

        XCTAssertEqual(samples.first?.used, 62)
        // Remaining still floors at zero: the window can't hold less than nothing.
        XCTAssertEqual(samples.first?.remainingFraction, 0)
    }

    /// Two accounts of the same provider carry different card ids, so their series can never merge.
    func testAccountCardsGetDistinctSeries() {
        let accountProvider = Provider(id: "claude@ab12cd34", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.percent(
            id: "claude@ab12cd34.session",
            provider: accountProvider,
            title: "Session"
        )
        let snapshot = ProviderSnapshot(
            providerID: "claude@ab12cd34",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [descriptor],
            capturedAt: capturedAt
        )

        XCTAssertEqual(samples.first?.scopeKey, "claude@ab12cd34|claude@ab12cd34.session")
        XCTAssertEqual(QuotaSeriesKey.split("claude@ab12cd34|claude@ab12cd34.session")?.providerID, "claude@ab12cd34")
    }
}
