import Foundation

/// One observation of a capped metric, taken at the instant a provider refresh succeeded.
///
/// Samples are the raw material for the quota trend charts. They are deliberately stored at the
/// refresh cadence (one per successful fetch, every `RefreshSetting.interval`) rather than pre-rolled
/// into hourly buckets: bucketing is a *reading* decision, so keeping the raw points lets the same
/// stored data answer a 24-hour view at fine resolution and a 30-day view at hourly resolution,
/// and lets reset boundaries be derived exactly instead of guessed at write time.
///
/// Only normalized numbers and timestamps are carried — never credentials, provider payloads, or
/// display strings.
struct QuotaSample: Hashable, Sendable {
    /// The series this sample belongs to: `"<providerID>|<metricID>"`. `providerID` is the card id,
    /// which is already account-derived for account-first families (`claude@ab12cd34`), so two accounts
    /// of the same provider can never share a series. Built by `QuotaSeriesKey.make`.
    let scopeKey: String
    /// The card id that produced the sample (`"codex"`, `"claude@ab12cd34"`).
    let providerID: String
    /// The stable metric id from `WidgetDescriptor.id` (`"claude.session"`) — not the display label,
    /// which is user-visible copy and may be reworded between releases.
    let metricID: String
    /// When the producing refresh completed.
    let capturedAt: Date
    let used: Double
    let limit: Double
    let format: ProgressFormat
    /// The end of the quota window this sample was taken in, when the provider reports one. `nil` for
    /// windowless balances (credit pools). Reset boundaries are derived from how this moves between
    /// consecutive samples — see `QuotaHistoryAggregator`.
    let resetsAt: Date?

    /// Remaining share of the window, `0...1`. `nil` when the limit is not a usable denominator, so a
    /// bad provider reading can never be plotted as a real 0% or 100%.
    var remainingFraction: Double? {
        guard limit.isFinite, limit > 0, used.isFinite else { return nil }
        return min(1, max(0, (limit - used) / limit))
    }
}

/// Builds and parses the composite series key. One definition so the writer, the reader, and the
/// scope picker can never disagree about how a series is identified.
enum QuotaSeriesKey {
    /// The separator is `|` because neither a card id nor a descriptor id can contain it (card ids are
    /// `family` or `family@hash8`; descriptor ids are dotted identifiers).
    private static let separator: Character = "|"

    static func make(providerID: String, metricID: String) -> String {
        "\(providerID)\(separator)\(metricID)"
    }

    /// Splits a stored key back into its parts, or `nil` for a key that doesn't have the expected
    /// shape (a record written by a future schema, or a corrupted row).
    static func split(_ key: String) -> (providerID: String, metricID: String)? {
        let parts = key.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

/// A series that has samples on record, used to populate the history window's provider/metric pickers.
struct QuotaHistoryScope: Hashable, Sendable, Identifiable {
    let scopeKey: String
    let providerID: String
    let metricID: String
    /// The newest sample's timestamp, so the picker can order by recency and mark dormant series.
    let latestSample: Date

    var id: String { scopeKey }
}
