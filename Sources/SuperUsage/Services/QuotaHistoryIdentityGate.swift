import Foundation

/// Re-reads which account is signed in at a card *right now*, so quota history can refuse to write
/// rather than attribute a sample to the wrong account.
///
/// The app resolves account identity once per launch (see `ProviderAccountAssembly`: "a mid-run swap is
/// caught on the next launch"), and the card set, the provider catalog, and the snapshot cache's account
/// stamps are all pinned to that one pass. Providers, however, read live credentials on every refresh —
/// so after a sign-out and sign-in, the numbers coming back belong to the *new* account while the launch
/// map still names the old one.
///
/// Everywhere else that mismatch is self-correcting: a cache entry stamped with the wrong account is
/// discarded at the next launch. History is append-only, and a row written under account A holding
/// account B's usage is indistinguishable from a real one forever. So history alone gets a gate.
///
/// Note this is deliberately a *gate*, not a switch: history does not start writing to the new account's
/// series mid-session either. Doing that would make history the one surface disagreeing with the card
/// set, the dashboard, and the cache. It stops, loudly, until the app is restarted — at which point the
/// launch pass resolves the new account and everything agrees again.
struct QuotaHistoryIdentityGate: Sendable {
    /// Config dir per extra Claude account card. An extra card is pinned to its own home, so it must be
    /// verified against that home; the default home would answer about a different account entirely.
    let claudeConfigDirsByCard: [String: String]
    var observer: DefaultAccountObserver = DefaultAccountObserver()

    init(claudeConfigDirsByCard: [String: String] = [:], observer: DefaultAccountObserver = DefaultAccountObserver()) {
        self.claudeConfigDirsByCard = claudeConfigDirsByCard
        self.observer = observer
    }

    /// The identity signed in at `cardID` now, or `nil` if it can't be established.
    ///
    /// `nil` is deliberately indistinguishable from "a different account" to the caller: an identity we
    /// cannot verify is not one we may write history under.
    func liveIdentityKey(cardID: String) -> String? {
        let outcome: DefaultAccountObserver.Outcome
        if let configDir = claudeConfigDirsByCard[cardID] {
            outcome = observer.observeClaude(configDirPath: configDir)
        } else if ProviderAccountID.isAccountCard(cardID) {
            // An extra card whose home we don't know. Never fall back to the default home — that is the
            // one answer guaranteed to be about someone else.
            return nil
        } else {
            switch ProviderAccountID.family(of: cardID) {
            case "claude": outcome = observer.observeClaude()
            case "codex": outcome = observer.observeCodex()
            default: return nil
            }
        }
        guard case .resolved(let identityKey, _, _) = outcome else { return nil }
        return identityKey
    }
}
