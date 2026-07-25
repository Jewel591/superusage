import Foundation

/// The chart ranges the history window offers, and the bucket size each one reads at.
///
/// Samples are stored raw (one per refresh, every `RefreshSetting.interval`); bucketing happens here,
/// at read time. That split is why a single stored series can answer a fine-grained day view and a
/// month view without keeping two copies of the data.
enum QuotaHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }

    /// How wide one plotted point is. The day view reads at three refreshes per point so a fast burn is
    /// still visible; the longer ranges roll up to the hour, which is the resolution the trend question
    /// ("when did usage accelerate?") is actually asked at.
    var bucket: TimeInterval {
        switch self {
        case .day: return 15 * 60
        case .week, .month: return 60 * 60
        }
    }
}

/// One plotted point: a bucket of raw samples reduced to what the chart draws.
struct QuotaHistoryPoint: Hashable, Sendable, Identifiable {
    /// The bucket's start instant, which is also its x position.
    let time: Date
    /// Remaining share of the window at the end of the bucket, `0...1`. The *last* observation in the
    /// bucket rather than an average, so the line reads as "what was left at that time".
    let remainingFraction: Double
    /// Remaining amount in the metric's own unit (percent points, dollars, or counts).
    let remainingValue: Double
    let limit: Double
    /// Lowest and highest remaining fraction seen inside the bucket, so a range band can show intra-hour
    /// movement that the single closing value hides.
    let low: Double
    let high: Double
    let sampleCount: Int

    var id: Date { time }
}

/// A run of points with no gap and no reset between them — one continuous line on the chart.
struct QuotaHistorySegment: Hashable, Sendable, Identifiable {
    let id: Int
    let points: [QuotaHistoryPoint]

    var start: Date? { points.first?.time }
    var end: Date? { points.last?.time }
}

/// Everything the chart needs for one series over one range.
struct QuotaHistorySeries: Hashable, Sendable {
    let scopeKey: String
    let range: QuotaHistoryRange
    let format: ProgressFormat
    /// Line segments, split at reset boundaries and at gaps so neither is ever drawn as consumption.
    let segments: [QuotaHistorySegment]
    /// Instants where the quota window rolled over. Drawn as boundary rules, never as a usage spike.
    let resets: [Date]
    /// Stretches with no successful refresh on record. Drawn as absence, never interpolated across.
    let gaps: [DateInterval]

    var isEmpty: Bool { segments.allSatisfy(\.points.isEmpty) }
    var points: [QuotaHistoryPoint] { segments.flatMap(\.points) }
    var latest: QuotaHistoryPoint? { segments.last?.points.last }

    static let empty = QuotaHistorySeries(
        scopeKey: "",
        range: .day,
        format: .percent,
        segments: [],
        resets: [],
        gaps: []
    )
}

/// Turns raw stored samples into a chartable series.
///
/// Everything here is pure and deterministic — no clock, no store — so the reset/gap rules that decide
/// what the user believes about their burn rate are directly testable.
enum QuotaHistoryAggregator {
    /// No successful refresh for longer than this means the series has a hole. Three refresh intervals:
    /// one missed pass is normal jitter (a slow provider, a forced refresh landing off-cadence), but
    /// fifteen minutes of silence means the Mac slept, the network was down, or the provider kept
    /// failing — none of which is data we may interpolate across.
    static let gapThreshold: TimeInterval = RefreshSetting.interval * 3

    /// Remaining quota must climb by more than this share of the limit to count as a reset rather than
    /// provider rounding noise. One percent of the window.
    static let resetRiseThreshold = 0.01

    /// A reported window end must move forward by more than this to count as a rollover. Providers that
    /// report a rolling window recompute `resetsAt` on every refresh, so it creeps forward by about one
    /// refresh interval each time; requiring twice that ignores the creep while a real rollover — which
    /// jumps by the whole window length — still registers.
    static let windowRollThreshold: TimeInterval = RefreshSetting.interval * 2

    /// Build the series for one range.
    ///
    /// - Parameters:
    ///   - samples: raw samples for a single series, oldest first (the store's query order).
    ///   - range: the window to plot.
    ///   - now: the right edge of the chart. Samples after it are ignored.
    static func series(
        samples: [QuotaSample],
        range: QuotaHistoryRange,
        now: Date
    ) -> QuotaHistorySeries {
        let start = now.addingTimeInterval(-range.duration)
        let windowed = samples
            .filter { $0.capturedAt >= start && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let first = windowed.first else {
            return QuotaHistorySeries(
                scopeKey: samples.first?.scopeKey ?? "",
                range: range,
                format: samples.first?.format ?? .percent,
                segments: [],
                resets: [],
                gaps: []
            )
        }

        var runs: [[QuotaSample]] = []
        var current: [QuotaSample] = [first]
        var resets: [Date] = []
        var gaps: [DateInterval] = []

        for (previous, sample) in zip(windowed, windowed.dropFirst()) {
            let isGap = sample.capturedAt.timeIntervalSince(previous.capturedAt) > gapThreshold
            let isReset = didReset(from: previous, to: sample, acrossGap: isGap)
            if isGap {
                gaps.append(DateInterval(start: previous.capturedAt, end: sample.capturedAt))
            }
            if isReset {
                // Attribute the boundary to the first sample that shows the refilled window — that is the
                // earliest instant we can actually prove the reset had happened.
                resets.append(sample.capturedAt)
            }
            if isGap || isReset {
                runs.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        runs.append(current)

        let segments = runs.enumerated().compactMap { index, run -> QuotaHistorySegment? in
            let points = bucketed(run, bucket: range.bucket)
            guard !points.isEmpty else { return nil }
            return QuotaHistorySegment(id: index, points: points)
        }

        return QuotaHistorySeries(
            scopeKey: first.scopeKey,
            range: range,
            format: first.format,
            segments: segments,
            resets: resets,
            gaps: gaps
        )
    }

    /// Whether the quota window rolled over between two consecutive samples.
    ///
    /// Two independent signals, because neither alone covers every provider:
    ///
    /// - **Remaining went up.** Quota does not refill mid-window, so a meaningful rise is a reset. This
    ///   is the signal that works for providers with no reported window at all (credit balances), and it
    ///   also catches a top-up or plan change — which is likewise a boundary, not consumption.
    /// - **The reported window end jumped forward.** This catches a reset that the used value can't
    ///   show, most importantly a window that rolled over while sitting at zero usage.
    ///
    /// The window-end signal is suppressed across a gap: with no samples for hours, a rolling window's
    /// normal creep is indistinguishable from a rollover, and calling that a reset would draw a boundary
    /// that may never have happened. A genuine reset across a gap still shows through the rise signal.
    static func didReset(from previous: QuotaSample, to sample: QuotaSample, acrossGap: Bool) -> Bool {
        if let before = previous.remainingFraction, let after = sample.remainingFraction,
           after - before > resetRiseThreshold {
            return true
        }
        guard !acrossGap,
              let previousReset = previous.resetsAt,
              let sampleReset = sample.resetsAt
        else { return false }
        return sampleReset.timeIntervalSince(previousReset) > windowRollThreshold
    }

    /// Reduce one continuous run of samples to bucketed points.
    ///
    /// The closing value of each bucket becomes the point, so the line answers "what was left at that
    /// time" rather than smearing a mid-bucket average across a steep burn. `low`/`high` retain the
    /// spread the closing value drops.
    private static func bucketed(_ samples: [QuotaSample], bucket: TimeInterval) -> [QuotaHistoryPoint] {
        var points: [QuotaHistoryPoint] = []
        var bucketStart: Date?
        var members: [QuotaSample] = []

        func flush() {
            guard let start = bucketStart, let last = members.last else { return }
            let fractions = members.compactMap(\.remainingFraction)
            guard let closing = last.remainingFraction, let low = fractions.min(), let high = fractions.max() else {
                return
            }
            points.append(
                QuotaHistoryPoint(
                    time: start,
                    remainingFraction: closing,
                    remainingValue: max(0, last.limit - last.used),
                    limit: last.limit,
                    low: low,
                    high: high,
                    sampleCount: members.count
                )
            )
        }

        for sample in samples {
            let start = floorToBucket(sample.capturedAt, bucket: bucket)
            if start != bucketStart {
                flush()
                bucketStart = start
                members = []
            }
            members.append(sample)
        }
        flush()
        return points
    }

    /// Snap an instant down to its bucket boundary.
    ///
    /// Anchored to the absolute time axis rather than to the user's calendar: bucket sizes here divide an
    /// hour evenly, so this lands on wall-clock boundaries in every whole-hour time zone, and stays
    /// stable across a daylight-saving change instead of producing a short or doubled bucket.
    static func floorToBucket(_ date: Date, bucket: TimeInterval) -> Date {
        precondition(bucket > 0)
        let interval = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (interval / bucket).rounded(.down) * bucket)
    }
}
