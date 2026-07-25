import Charts
import SwiftUI

/// The remaining-quota trend chart.
///
/// Plots **remaining share of the window** (0–100%) rather than each metric's own unit, so a percent
/// meter, a dollar balance, and a credit pool all read on one axis and can be compared at a glance. The
/// absolute figure is never lost: it rides in the hover readout, in the metric's own unit.
///
/// Three things this chart refuses to draw as consumption, because each would tell the user a lie about
/// their burn rate:
///
/// - **Resets.** A window rolling over refills the quota. Joining across it would draw a vertical climb
///   that looks like quota appearing from nowhere; instead each side is its own line and the boundary
///   gets a rule.
/// - **Gaps.** No successful refresh means no observation. Interpolating across a sleeping Mac would
///   invent a smooth burn that never happened, so segments simply stop and restart — and the untouched
///   stretch is shaded, so "nothing was recorded here" reads differently from "the line is flat here".
/// - **Intra-bucket movement.** The line follows each bucket's closing value; the band behind it shows
///   the spread that value hides, so a spike inside an hour is visible rather than silently flattened.
struct QuotaHistoryChart: View {
    let series: QuotaHistorySeries
    /// The metric's own unit, used to render the absolute remaining figure in the readout.
    let kind: MetricKind
    let countSuffix: String?

    @State private var hovered: QuotaHistoryPoint?

    private static let height: CGFloat = 260

    var body: some View {
        Chart {
            // Drawn first so everything else sits on top of it. A break between two segments is only
            // absence-shaped if you already know segments exist; shading the stretch says outright that
            // nothing was recorded there, which is the difference between "usage held steady overnight"
            // and "the Mac was asleep overnight".
            ForEach(series.gaps, id: \.self) { gap in
                RectangleMark(
                    xStart: .value("Gap start", gap.start),
                    xEnd: .value("Gap end", gap.end),
                    yStart: .value("Bottom", 0),
                    yEnd: .value("Top", 1)
                )
                .foregroundStyle(.secondary.opacity(0.09))
            }

            ForEach(series.segments) { segment in
                ForEach(segment.points) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Low", point.low),
                        yEnd: .value("High", point.high),
                        series: .value("Segment", "band-\(segment.id)")
                    )
                    .foregroundStyle(Theme.chartSeries.opacity(0.14))
                    .interpolationMethod(.monotone)
                }
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Remaining", point.remainingFraction),
                        series: .value("Segment", "line-\(segment.id)")
                    )
                    .foregroundStyle(Theme.chartSeries)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
                // A line through one point draws nothing, which is exactly the state a brand-new install
                // is in until its second refresh — and a blank chart reads as broken rather than early.
                if let only = segment.points.first, segment.points.count == 1 {
                    PointMark(
                        x: .value("Time", only.time),
                        y: .value("Remaining", only.remainingFraction)
                    )
                    .foregroundStyle(Theme.chartSeries)
                    .symbolSize(40)
                }
            }

            ForEach(series.resets, id: \.self) { reset in
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        // No `.help` tooltip: the footnote under the chart already counts the resets in
                        // view, so hovering would only repeat it. The label is for VoiceOver, which has
                        // no footnote to read.
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Quota reset")
                    }
            }

            if let hovered {
                RuleMark(x: .value("Selected", hovered.time))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Selected", hovered.time),
                    y: .value("Remaining", hovered.remainingFraction)
                )
                .foregroundStyle(Theme.chartSeries)
                .symbolSize(60)
            }
        }
        // Pinned to the full window so a nearly-drained quota reads as nearly drained, instead of the
        // axis auto-scaling a 3%-to-1% slide into a dramatic cliff.
        .chartYScale(domain: 0...1)
        // The x axis is pinned to the range the user picked, not to the data. Letting it auto-fit makes
        // ten minutes of history fill a chart labelled "24h", and makes a series that stopped updating
        // hours ago end flush against the right edge as though it were current. Pinned, missing time
        // shows up as the blank it is.
        .chartXScale(domain: series.window)
        .chartYAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
            }
        }
        .chartXAxis {
            // No `.aligned` preset: it pins a mark to each plot edge, and a time label centered on the
            // leading edge hangs off the window and gets its first characters clipped.
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date))
                    }
                }
            }
        }
        .chartXSelection(value: selectionBinding)
        .frame(height: Self.height)
        .overlay(alignment: .topLeading) { readout }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Maps the chart's x selection to the nearest plotted point. Charts reports an interpolated date
    /// anywhere along the axis, so snapping to a real point keeps the readout honest — it always names a
    /// bucket that actually has samples, never a moment between two segments.
    private var selectionBinding: Binding<Date?> {
        Binding(
            get: { hovered?.time },
            set: { date in
                guard let date else {
                    hovered = nil
                    return
                }
                hovered = series.points.min {
                    abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
                }
            }
        )
    }

    @ViewBuilder
    private var readout: some View {
        if let point = hovered ?? series.latest {
            VStack(alignment: .leading, spacing: 1) {
                Text(point.remainingFraction.formatted(.percent.precision(.fractionLength(0))) + " left")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text("\(remainingLabel(point)) · \(timestampLabel(point.time))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(6)
            .allowsHitTesting(false)
        }
    }

    /// The absolute amount left, in the metric's own unit — the one figure the percentage axis drops.
    private func remainingLabel(_ point: QuotaHistoryPoint) -> String {
        let number = MetricFormatter.number(point.remainingValue, kind: kind, style: .row)
        guard let countSuffix, kind == .count, !countSuffix.isEmpty else { return number }
        return "\(number) \(countSuffix)"
    }

    /// Every label that prints an hour goes through the user's Auto/12h/24h choice, the same as the
    /// reset times on the dashboard — a chart reading "18:00" under a 12-hour setting would be the one
    /// clock in the app that ignores it.
    private var clockLocale: Locale { TimeFormatSetting.current.locale() }

    private func axisLabel(_ date: Date) -> String {
        switch series.range {
        case .day:
            return date.formatted(.dateTime.hour().minute().locale(clockLocale))
        case .week:
            return date.formatted(.dateTime.weekday(.abbreviated).hour().locale(clockLocale))
        case .month:
            return Formatters.monthDayLabel(date)
        }
    }

    private func timestampLabel(_ date: Date) -> String {
        switch series.range {
        case .day:
            return date.formatted(.dateTime.hour().minute().locale(clockLocale))
        case .week, .month:
            return date.formatted(.dateTime.month(.abbreviated).day().hour().locale(clockLocale))
        }
    }

    private var accessibilityLabel: String {
        guard let latest = series.latest, let earliest = series.segments.first?.points.first else {
            return "Remaining quota trend. No data."
        }
        let percent = latest.remainingFraction.formatted(.percent.precision(.fractionLength(0)))
        let resets = series.resets.isEmpty ? "" : " \(series.resets.count) reset(s) in range."
        // The shaded bands carry no meaning to VoiceOver, so the count is spoken instead — otherwise a
        // chart mostly made of silence sounds identical to one with continuous coverage.
        let gaps = series.gaps.isEmpty ? "" : " \(series.gaps.count) gap(s) with no successful refresh."
        return """
        Remaining quota trend from \(timestampLabel(earliest.time)) to \(timestampLabel(latest.time)). \
        \(percent) left.\(resets)\(gaps)
        """
    }
}
