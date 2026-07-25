import XCTest
@testable import SuperUsage

/// The rules that decide what the chart claims happened. Every case here is a way the trend could
/// silently mislead: a reset drawn as consumption, a sleeping Mac drawn as a smooth burn, or a rolling
/// window's normal drift drawn as a reset that never occurred.
final class QuotaHistoryAggregatorTests: XCTestCase {
    /// Aligned to a whole hour on the aggregator's own time axis, so "minutes after start" maps onto
    /// bucket boundaries predictably. An arbitrary instant would land mid-bucket and make the bucketing
    /// assertions depend on where that instant happened to fall rather than on the rule under test.
    private let start = Date(timeIntervalSinceReferenceDate: 799_999_200)
    private let interval = RefreshSetting.interval

    private func sample(
        minutesAfterStart: Double,
        used: Double,
        limit: Double = 100,
        resetsAt: Date? = nil
    ) -> QuotaSample {
        QuotaSample(
            scopeKey: "claude|claude.session",
            providerID: "claude",
            accountDigest: "aaaaaaaa",
            metricID: "claude.session",
            capturedAt: start.addingTimeInterval(minutesAfterStart * 60),
            used: used,
            limit: limit,
            format: .percent,
            resetsAt: resetsAt
        )
    }

    private func now(minutesAfterStart: Double) -> Date {
        start.addingTimeInterval(minutesAfterStart * 60)
    }

    // MARK: - Continuity

    func testSteadyBurnIsOneSegmentWithNoResetsOrGaps() {
        let samples = (0..<12).map { sample(minutesAfterStart: Double($0) * 5, used: Double($0) * 5) }

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 60))

        XCTAssertEqual(series.segments.count, 1)
        XCTAssertTrue(series.resets.isEmpty)
        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertEqual(series.latest?.remainingFraction, 0.45)
    }

    /// The line must follow each bucket's *closing* value. Averaging would smear a steep burn and make
    /// the remaining quota look healthier than it was at the end of the hour.
    func testBucketPointTakesTheClosingValueAndKeepsTheSpread() {
        // Four samples inside one 15-minute bucket, dropping from 90% left to 60% left.
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 5, used: 20),
            sample(minutesAfterStart: 10, used: 30),
            sample(minutesAfterStart: 14, used: 40)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 20))

        XCTAssertEqual(series.points.count, 1)
        let point = try? XCTUnwrap(series.points.first)
        XCTAssertEqual(point?.remainingFraction, 0.6)
        XCTAssertEqual(point?.low, 0.6)
        XCTAssertEqual(point?.high, 0.9)
        XCTAssertEqual(point?.sampleCount, 4)
    }

    // MARK: - Resets

    /// Remaining quota climbing is the one thing consumption cannot do, so it always reads as a reset —
    /// and the two sides must not be joined, or the refill draws as a vertical spike.
    func testRefilledQuotaSplitsTheSegmentAndRecordsAReset() {
        let samples = [
            sample(minutesAfterStart: 0, used: 80),
            sample(minutesAfterStart: 5, used: 90),
            sample(minutesAfterStart: 10, used: 5),
            sample(minutesAfterStart: 15, used: 12)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 30))

        XCTAssertEqual(series.resets, [start.addingTimeInterval(10 * 60)])
        XCTAssertEqual(series.segments.count, 2)
        XCTAssertTrue(series.gaps.isEmpty)
    }

    /// A window can roll over without the used value showing it — most importantly when usage sat at
    /// zero across the boundary. The reported window end is the only witness.
    func testWindowEndJumpingForwardCountsAsAResetEvenWithFlatUsage() {
        let firstWindow = start.addingTimeInterval(600)
        let samples = [
            sample(minutesAfterStart: 0, used: 0, resetsAt: firstWindow),
            sample(minutesAfterStart: 5, used: 0, resetsAt: firstWindow),
            sample(minutesAfterStart: 10, used: 0, resetsAt: firstWindow.addingTimeInterval(5 * 3_600))
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 30))

        XCTAssertEqual(series.resets, [start.addingTimeInterval(10 * 60)])
        XCTAssertEqual(series.segments.count, 2)
    }

    /// Providers that report a rolling window recompute the end on every refresh, so it creeps forward
    /// by about one interval each time. Treating that as a rollover would litter the chart with resets
    /// that never happened.
    func testRollingWindowDriftIsNotAReset() {
        let samples = (0..<6).map { index -> QuotaSample in
            let minutes = Double(index) * 5
            return sample(
                minutesAfterStart: minutes,
                used: Double(index) * 3,
                // The window end creeps forward by exactly one refresh interval per sample.
                resetsAt: start.addingTimeInterval(minutes * 60 + 5 * 3_600)
            )
        }

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 60))

        XCTAssertTrue(series.resets.isEmpty)
        XCTAssertEqual(series.segments.count, 1)
    }

    /// Rounding noise from a provider must not register as a refill.
    func testTinyUpwardNoiseIsNotAReset() {
        let samples = [
            sample(minutesAfterStart: 0, used: 50),
            // 0.5% of the window back — under the 1% threshold.
            sample(minutesAfterStart: 5, used: 49.5)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 30))

        XCTAssertTrue(series.resets.isEmpty)
        XCTAssertEqual(series.segments.count, 1)
    }

    /// A reset inside a single bucket puts both sides in the same bucket. If points were stamped with
    /// the bucket's start instead of their closing sample's time, the post-reset point would be drawn
    /// *to the left of* the reset rule that caused it — the chart would show the refill happening before
    /// the boundary.
    func testResetInsideOneBucketKeepsBothSidesOnTheCorrectSideOfTheRule() {
        let samples = [
            sample(minutesAfterStart: 0, used: 80),
            sample(minutesAfterStart: 5, used: 95),
            sample(minutesAfterStart: 10, used: 5)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 12))

        // All three land in the same 15-minute bucket, but the reset splits them into two segments.
        let resetAt = start.addingTimeInterval(10 * 60)
        XCTAssertEqual(series.resets, [resetAt])
        XCTAssertEqual(series.segments.count, 2)
        XCTAssertEqual(series.segments.first?.points.map(\.time), [start.addingTimeInterval(5 * 60)])
        XCTAssertEqual(series.segments.last?.points.map(\.time), [resetAt])
        // The point that shows the refill is at or after the rule, never before it.
        for point in series.segments.last?.points ?? [] {
            XCTAssertGreaterThanOrEqual(point.time, resetAt)
        }
    }

    // MARK: - Gaps

    /// A sleeping Mac produces no observations. Drawing a line across the hole would invent a smooth
    /// burn through hours nobody measured.
    func testSilenceLongerThanTheThresholdBreaksTheLine() {
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 5, used: 15),
            // Two hours later — well past three refresh intervals.
            sample(minutesAfterStart: 125, used: 60),
            sample(minutesAfterStart: 130, used: 65)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 132))

        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.gaps.first?.start, start.addingTimeInterval(5 * 60))
        XCTAssertEqual(series.gaps.first?.end, start.addingTimeInterval(125 * 60))
        XCTAssertEqual(series.segments.count, 2)
        XCTAssertTrue(series.resets.isEmpty)
    }

    /// One missed pass is ordinary jitter (a slow provider, a forced refresh landing off-cadence) and
    /// must not fragment the line.
    func testASingleMissedRefreshIsNotAGap() {
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 10, used: 20)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 12))

        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertEqual(series.segments.count, 1)
    }

    /// The chart's x-axis runs to *now*, so a series whose last sample is hours old would otherwise
    /// trail off into blank plot area that reads as "nothing was consumed". Silence right up to the
    /// present is the same unmeasured hole as silence in the middle, and is banded the same way.
    func testSilenceSinceTheLastSampleIsBandedThroughToNow() {
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 5, used: 15)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 125))

        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.gaps.first?.start, start.addingTimeInterval(5 * 60))
        XCTAssertEqual(series.gaps.first?.end, now(minutesAfterStart: 125))
        // Still one continuous line — the hole is after the data, not inside it.
        XCTAssertEqual(series.segments.count, 1)
    }

    /// The window is pinned to the range even when the data covers a sliver of it, so a two-sample
    /// series doesn't stretch to fill 24 hours of chart and imply a burn rate 100× slower than reality.
    func testWindowSpansTheFullRangeRegardlessOfCoverage() {
        let samples = [sample(minutesAfterStart: 0, used: 10), sample(minutesAfterStart: 5, used: 15)]
        let end = now(minutesAfterStart: 5)

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: end)

        XCTAssertEqual(series.window.upperBound, end)
        XCTAssertEqual(series.window.lowerBound, end.addingTimeInterval(-QuotaHistoryRange.day.duration))
    }

    /// A sample newer than `now` (clock skew, or a provider stamping the future) must not stretch the
    /// window past the present — the chart would leave a permanent empty margin on the right.
    func testSamplesAheadOfNowAreIgnored() {
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 60, used: 90)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 2))

        XCTAssertEqual(series.window.upperBound, now(minutesAfterStart: 2))
        XCTAssertEqual(series.latest?.remainingFraction, 0.9)
    }

    /// Across a gap a rolling window's drift is indistinguishable from a rollover, so the window-end
    /// signal is suppressed — but a genuine refill still shows through the rise signal.
    func testWindowDriftAcrossAGapIsNotAReset() {
        let samples = [
            sample(minutesAfterStart: 0, used: 30, resetsAt: start.addingTimeInterval(3_600)),
            // Three hours later, with the window end dragged along and usage unchanged.
            sample(minutesAfterStart: 180, used: 30, resetsAt: start.addingTimeInterval(180 * 60 + 3_600))
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 182))

        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertTrue(series.resets.isEmpty)
    }

    func testRefillAcrossAGapIsStillAReset() {
        let samples = [
            sample(minutesAfterStart: 0, used: 95),
            sample(minutesAfterStart: 180, used: 5)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 182))

        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.resets, [start.addingTimeInterval(180 * 60)])
    }

    // MARK: - Range windowing

    func testSamplesOutsideTheRangeAreExcluded() {
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 60 * 40, used: 50)
        ]

        // A 24-hour window ending 40 hours in leaves only the later sample.
        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 60 * 40))

        XCTAssertEqual(series.points.count, 1)
        XCTAssertEqual(series.latest?.remainingFraction, 0.5)
    }

    /// The recorder deliberately reads one bucket earlier than the range so the aggregator has a
    /// neighbour just outside the window. Without it a rollover that happened at the window's left edge
    /// is invisible — the series simply appears to begin there, and the pre-reset burn looks like it
    /// continued into the new window.
    func testResetStraddlingTheLeftEdgeIsDetectedFromTheOutOfWindowNeighbour() {
        let end = now(minutesAfterStart: 60)
        let samples = [
            // Just outside the 24h window, nearly exhausted…
            sample(minutesAfterStart: -1_400, used: 95),
            // …and refilled by the first sample inside it.
            sample(minutesAfterStart: 0, used: 5),
            sample(minutesAfterStart: 5, used: 8)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: end)

        XCTAssertEqual(series.resets, [start])
        // The out-of-window sample informs the verdict but is never plotted: both in-window samples
        // share one 15-minute bucket, so exactly one point comes out — the post-reset one.
        XCTAssertEqual(series.points.count, 1)
        XCTAssertEqual(series.points.first?.time, start.addingTimeInterval(5 * 60))
        XCTAssertEqual(series.points.first?.remainingFraction, 0.92)
        // The silence before the window's first sample is banded, clipped to what's visible.
        XCTAssertEqual(series.gaps.first?.start, end.addingTimeInterval(-QuotaHistoryRange.day.duration))
        XCTAssertEqual(series.gaps.first?.end, start)
    }

    /// A brand-new install has no earlier neighbour, and "we only started recording an hour ago" is not
    /// a gap — banding it would tell the user data went missing that never existed.
    func testNoLeadingGapIsInventedWhenHistorySimplyStartsThere() {
        let samples = [
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 5, used: 15)
        ]

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: now(minutesAfterStart: 7))

        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertTrue(series.resets.isEmpty)
    }

    /// A series that stopped being recorded entirely (provider removed, signed out) has nothing inside
    /// the window — but that is one long hole, not "no history", and the difference is what tells the
    /// user whether to go looking for a broken provider.
    func testSeriesThatStoppedRecordingIsOneLongGapRatherThanEmpty() {
        let samples = [sample(minutesAfterStart: -1_400, used: 40)]
        let end = now(minutesAfterStart: 60)

        let series = QuotaHistoryAggregator.series(samples: samples, range: .day, now: end)

        XCTAssertTrue(series.isEmpty)
        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.gaps.first?.start, end.addingTimeInterval(-QuotaHistoryRange.day.duration))
        XCTAssertEqual(series.gaps.first?.end, end)
    }

    func testEmptyInputProducesAnEmptySeries() {
        let series = QuotaHistoryAggregator.series(samples: [], range: .week, now: start)

        XCTAssertTrue(series.isEmpty)
        XCTAssertTrue(series.resets.isEmpty)
        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertNil(series.latest)
    }

    // MARK: - Bucketing

    func testBucketsAlignToTheHourForTheLongerRanges() {
        let date = Date(timeIntervalSince1970: 1_700_003_671) // 01:01:11 past an hour boundary
        let floored = QuotaHistoryAggregator.floorToBucket(date, bucket: 3_600)

        XCTAssertEqual(floored.timeIntervalSince1970.truncatingRemainder(dividingBy: 3_600), 0)
        XCTAssertLessThanOrEqual(floored, date)
        XCTAssertLessThan(date.timeIntervalSince(floored), 3_600)
    }

    func testWeekRangeRollsUpToHourlyPoints() {
        // Twelve samples across one hour must collapse to a single hourly point.
        let samples = (0..<12).map { sample(minutesAfterStart: Double($0) * 5, used: Double($0)) }

        let series = QuotaHistoryAggregator.series(samples: samples, range: .week, now: now(minutesAfterStart: 60))

        XCTAssertLessThanOrEqual(series.points.count, 2)
        XCTAssertEqual(series.range.bucket, 3_600)
    }

    func testGapThresholdIsThreeRefreshIntervals() {
        XCTAssertEqual(QuotaHistoryAggregator.gapThreshold, interval * 3)
    }
}
