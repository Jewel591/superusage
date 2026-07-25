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

        return descriptors.compactMap { descriptor in
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
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            return QuotaSample(
                scopeKey: QuotaSeriesKey.make(
                    providerID: snapshot.providerID,
                    accountDigest: accountDigest,
                    metricID: descriptor.id
                ),
                providerID: snapshot.providerID,
                accountDigest: accountDigest,
                metricID: descriptor.id,
                capturedAt: capturedAt,
                used: normalizedUsed,
                limit: limit,
                format: format,
                resetsAt: resetsAt
            )
        }
    }
}
