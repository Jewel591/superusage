import Foundation

/// Latest normalized output for one provider refresh.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    /// The card title at refresh time — always the baked DERIVED name (renames never reach the
    /// cache or iCloud). The CLI/API boundary re-resolves it against the account registry at
    /// respond time (`LocalUsageAPI.State.resolvingDisplayNames`), so human-facing output carries
    /// renames without persisting them.
    var displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// Raw normalized daily history used to build spend rows. This always belongs to this Mac; peer
    /// history is combined only in the in-memory rendered view and is never written into the cache.
    var usageHistory: ProviderUsageHistory?
    /// A soft, non-blocking notice carried on a *successful* snapshot — e.g. Claude's "Re-login for live
    /// usage" when the saved login lacks the `user:profile` scope. Distinct from `errorCategory` (which is
    /// only on error snapshots): the refresh succeeded and partial data (spend tiles) still loads, so this
    /// surfaces as the provider header's amber triangle rather than blanking the provider. Cached with the
    /// snapshot; cleared on the next refresh when the condition resolves.
    var warning: String?
    /// Set only on error snapshots: a stable, non-PII bucket for the failure, read by telemetry on the
    /// failure path. Always `nil` on success (and error snapshots aren't cached), so it never persists.
    var errorCategory: ErrorCategory?
    /// When the quota figures in `lines` were actually observed, when that differs from `refreshedAt`.
    ///
    /// A refresh can succeed while the quota numbers in it are *not* a new observation: Claude's usage
    /// endpoint rate-limits often, and during the cooldown the provider deliberately serves its
    /// last-good usage with a staleness note rather than blanking the dashboard. That snapshot is not an
    /// error and its `refreshedAt` is now, so anything that treats "successful refresh" as "new reading"
    /// would record the same values over and over — drawing a flat line through a window nobody
    /// measured, and erasing the gap that should mark it.
    ///
    /// Providers that can name the instant of the read stamp it here — both when the reading is fresh
    /// and when they re-serve an earlier one, so the two carry the *same* instant and the re-serve
    /// collides with the row already on record instead of minting a new point. `nil` means the provider
    /// doesn't distinguish the two, and `quotaReadAt` falls back to `refreshedAt`.
    var quotaObservedAt: Date?

    /// The account that the credential which actually produced these numbers belongs to, in the same
    /// `identityKey` spelling `ProviderAccountAssembly` resolves at launch. `nil` when the provider
    /// cannot prove it from that credential — including every provider outside the account-aware
    /// families, which have no account identity at all.
    ///
    /// This exists for quota history, which is append-only and therefore the one surface that can be
    /// corrupted permanently by attributing a reading to the wrong account. Credential selection is a
    /// fallback chain (Codex tries each `auth.json` then the keychain; Claude tries keychain, file, then
    /// possibly Claude Desktop), so "which account is signed in" and "which account produced this
    /// snapshot" are different questions whenever the chain falls past its first rung. Only the second
    /// one may key a history row, so the producing credential answers it directly.
    ///
    /// **Deliberately not `Codable`** (see `CodingKeys`): this model is written verbatim to the local
    /// snapshot cache, to the local HTTP API, and — with iCloud Sync on — to CloudKit. An account
    /// identity key has no business in any of those. Excluding it also makes a decoded snapshot
    /// unprovable by construction, which is correct: a cache entry restored at launch, or a snapshot
    /// synced from another Mac, is not evidence about a credential on *this* machine right now.
    var accountProof: String?

    /// Every field that is persisted or sent. `accountProof` is absent on purpose — see above.
    private enum CodingKeys: String, CodingKey {
        case providerID, displayName, plan, lines, refreshedAt, usageHistory, warning, errorCategory
        case quotaObservedAt
    }

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        errorCategory: ErrorCategory? = nil,
        quotaObservedAt: Date? = nil,
        accountProof: String? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.warning = warning
        self.errorCategory = errorCategory
        self.quotaObservedAt = quotaObservedAt
        self.accountProof = accountProof
    }

    /// The instant the quota figures in this snapshot were read — the real observation time, which is
    /// the refresh time unless the provider re-served an earlier reading.
    var quotaReadAt: Date { quotaObservedAt ?? refreshedAt }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// The success-path counterpart to `error(provider:message:)`: derives `providerID`/`displayName`
    /// from the provider so every runtime builds its snapshot the same way (`refreshedAt` is required
    /// so each call passes its own `now()`).
    static func make(
        provider: Provider,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date,
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        quotaObservedAt: Date? = nil,
        accountProof: String? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: warning,
            quotaObservedAt: quotaObservedAt,
            accountProof: accountProof
        )
    }

    /// Build an error snapshot straight from a caught error: the badge text stays the error's
    /// user-facing `localizedDescription` (UI copy is unchanged), and the telemetry category is derived
    /// from the error's `CategorizedError` conformance (falling back to `.other` for anything that
    /// doesn't classify itself). Preferred over `error(provider:message:)` wherever an `Error` is in hand.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(
            provider: provider,
            message: error.localizedDescription,
            category: (error as? CategorizedError)?.errorCategory ?? .other
        )
    }

    static func error(provider: Provider, message: String, category: ErrorCategory? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")],
            errorCategory: category
        )
    }
}
