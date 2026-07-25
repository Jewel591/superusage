import Foundation

/// Turns a successful `ProviderSnapshot` into the quota samples worth recording.
///
/// Pure and descriptor-driven: a metric is sampled only when the provider published a `.progress` line
/// for a descriptor the registry knows, so the stored series is keyed by the same stable
/// `WidgetDescriptor.id` the rest of the app uses. Unbounded rows, charts, badges, and notices have no
/// remaining-quota story and are skipped entirely.
enum QuotaSampleExtractor {
    /// Every recordable capped metric in this snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: a *successful* snapshot. Error snapshots must never reach here — a failed refresh
    ///     has to leave a gap in the series, not a fabricated point (see `docs/quota-history.md`).
    ///   - descriptors: the provider's registry descriptors, which supply the stable metric ids.
    ///   - capturedAt: the observation instant. Callers pass the snapshot's `quotaReadAt` — when the
    ///     quota was actually *read*, which is the refresh time except when the provider re-served an
    ///     earlier reading (Claude's rate-limit cooldown). Stamping such a re-serve with the refresh
    ///     time would mint a new point every 5 minutes for a window nobody measured; stamping it with
    ///     the real reading time makes it collide with the row already on record, so the store's
    ///     uniqueness constraint absorbs it and the untouched stretch shows up as the gap it is.
    ///   - identityKey: the account signed in at this card right now, or `nil` when unresolved.
    static func samples(
        from snapshot: ProviderSnapshot,
        descriptors: [WidgetDescriptor],
        capturedAt: Date,
        identityKey: String?
    ) -> [QuotaSample] {
        // An error snapshot carries only its error badge; guarding here (rather than trusting callers)
        // keeps the "failures leave gaps" invariant true at the single place samples are minted.
        guard !snapshot.lines.contains(where: \.isError) else { return [] }

        // An account-first family whose identity we can't resolve records *nothing*. History is
        // append-only: a bare `claude` card is a different account after a swap, so writing an
        // unattributable sample would splice two people's usage into one line with no way to separate
        // them later. A gap is recoverable; a mixed series is not.
        let family = ProviderAccountID.family(of: snapshot.providerID)
        let isAccountAware = ProviderAccountID.families.contains(family)
        guard !isAccountAware || identityKey != nil else { return [] }
        let accountDigest = identityKey.map(ProviderAccountID.identityDigest)

        return cappedReadings(in: snapshot, descriptors: descriptors).map { reading in
            QuotaSample(
                scopeKey: QuotaSeriesKey.make(
                    providerID: snapshot.providerID,
                    accountDigest: accountDigest,
                    metricID: reading.metricID
                ),
                providerID: snapshot.providerID,
                accountDigest: accountDigest,
                metricID: reading.metricID,
                capturedAt: capturedAt,
                used: reading.used,
                limit: reading.limit,
                format: reading.format,
                resetsAt: reading.resetsAt
            )
        }
    }

    /// Whether this snapshot had anything worth recording *before* attribution is considered.
    ///
    /// Lets a caller tell the two empty results of `samples(...)` apart, which look identical but mean
    /// opposite things: "this refresh had no capped metrics" (an error badge, a provider with nothing
    /// bounded to plot) is nothing to report, while "it had them but the account couldn't be resolved"
    /// is a card that will silently record nothing for the whole session, and the one silence the
    /// history window can't otherwise explain — such a card never gets a series, so it never even
    /// appears in the picker. See `QuotaHistoryRecorder.recordingGaps`.
    static func hasRecordableMetrics(in snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor]) -> Bool {
        guard !snapshot.lines.contains(where: \.isError) else { return false }
        return !cappedReadings(in: snapshot, descriptors: descriptors).isEmpty
    }

    /// One usable capped reading, before it is keyed to an account.
    private struct CappedReading {
        let metricID: String
        let used: Double
        let limit: Double
        let format: ProgressFormat
        let resetsAt: Date?
    }

    private static func cappedReadings(
        in snapshot: ProviderSnapshot,
        descriptors: [WidgetDescriptor]
    ) -> [CappedReading] {
        descriptors.compactMap { descriptor in
            guard let line = snapshot.line(label: descriptor.metricLabel),
                  case .progress(_, let used, let limit, let format, let resetsAt, _, _) = line
            else { return nil }
            // A non-positive or non-finite limit is not a usable denominator — a provider reporting one
            // has told us nothing about remaining quota, and plotting it would invent a 0% or 100%.
            guard limit.isFinite, limit > 0, used.isFinite else { return nil }
            // Mirror the dashboard's own normalization (`WidgetDataStore.resolve`): a percent meter is a
            // bounded 0...100 domain, so an out-of-range provider reading is clamped here too. Without
            // this the chart and the meter would disagree about the same refresh. Non-percent meters keep
            // their raw `used` — a dollar or count overage is real information.
            return CappedReading(
                metricID: descriptor.id,
                used: format == .percent ? ProviderParse.clampPercent(used) : used,
                limit: limit,
                format: format,
                resetsAt: resetsAt
            )
        }
    }
}
