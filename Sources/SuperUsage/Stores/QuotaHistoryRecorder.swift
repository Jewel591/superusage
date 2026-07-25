import Foundation
import Observation

/// Owns the quota-history database: records a sample per capped metric on every successful refresh,
/// keeps retention bounded, and serves the ranges the history window charts.
///
/// This is the only thing that talks to `QuotaHistoryStore`. `WidgetDataStore` just hands it successful
/// snapshots through a closure, exactly as it hands outcomes to telemetry — so the refresh path stays
/// unaware of persistence, and a store failure can never fail a refresh.
@MainActor
@Observable
final class QuotaHistoryRecorder {
    private let store: QuotaHistoryStore
    private let registry: WidgetRegistry
    private let retentionWindow: TimeInterval
    private let now: () -> Date
    /// The account signed in at each card, by card id — the same map the snapshot cache stamps its
    /// entries with. Absent means "unresolved", which for an account-first family means don't record.
    ///
    /// Fixed for the process, because that is what the account-first model guarantees: the identity
    /// pass runs once per launch (see `ProviderAccountAssembly`, "a mid-run swap is caught on the next
    /// launch"), and the card set, the provider catalog, and the cache's account stamps are all pinned
    /// to it. History does not re-key itself mid-session — it would then be the only surface describing
    /// the new account. What it does instead is refuse to write anything the producing credential
    /// doesn't prove belongs to this account; see `isProven`.
    private let identityKeys: [String: String]

    /// Cards whose refreshes are currently coming back from a different account than the one this
    /// process launched with. Recording is suspended for these, and the history window says so —
    /// otherwise the chart would just stop growing with no stated reason.
    private(set) var pausedCards: Set<String> = []

    /// Serializes "the store is open" across every caller: each operation awaits this one task instead
    /// of racing its own `load()`.
    @ObservationIgnored private var openTask: Task<Void, Error>?
    /// In-flight writes, so `flushPendingWrites()` can wait them out before the app exits. Keyed so each
    /// task can retire its own entry on completion and the map can't grow across a long session.
    @ObservationIgnored private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastPruneAt: Date?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?

    /// Why the history is unavailable, if it is: the store wouldn't open, or a read failed. Surfaced so
    /// the window can say "we couldn't read it" instead of showing the same empty chart it shows when
    /// there genuinely is nothing yet — on a corrupt or unreadable database those two are very different
    /// answers.
    private(set) var failure: String?

    /// Why the last sample write failed, if it did — cleared by the next write that succeeds.
    ///
    /// Kept apart from `failure` because the two need opposite treatments on screen: an unreadable store
    /// has nothing to draw, but a *write* failure leaves every earlier point perfectly readable. Blanking
    /// the chart for it would destroy the very thing the user came to look at, so this is surfaced as a
    /// non-blocking notice over a chart that still renders. It is surfaced at all because the alternative
    /// is the failure mode this whole window exists to prevent: a line that just stops growing, with the
    /// reason visible only in the log.
    private(set) var recordingFailure: String?

    /// Why the last retention pass failed, if it did — cleared by the next prune that succeeds.
    ///
    /// Nothing on screen depends on pruning, so this never blocks anything either. It is reported because
    /// retention is a promise the app makes about the user's disk (35 days, `docs/quota-history.md`), and
    /// a promise that has quietly stopped being kept should not be discoverable only by reading the log.
    private(set) var retentionFailure: String?

    /// How often retention runs. Pruning is pure bookkeeping — nothing user-visible depends on it
    /// happening promptly — so once a day is plenty, and it costs one indexed range delete.
    private static let pruneInterval: TimeInterval = 24 * 60 * 60
    /// How often the maintenance loop wakes to *check* whether a prune is due. Short enough that a Mac
    /// left running for weeks still prunes daily, long enough to be free.
    private static let maintenanceInterval: TimeInterval = 60 * 60

    init(
        registry: WidgetRegistry,
        identityKeys: [String: String] = [:],
        store: QuotaHistoryStore = QuotaHistoryStore(),
        retentionWindow: TimeInterval = QuotaHistoryStore.retentionWindow,
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.identityKeys = identityKeys
        self.store = store
        self.retentionWindow = retentionWindow
        self.now = now
    }

    /// Records every capped metric in a *successful* snapshot.
    ///
    /// Fire-and-forget: the refresh path must not wait on a database write, and a write failure must
    /// not turn a good refresh into a failed one. Failures log loudly instead.
    func record(snapshot: ProviderSnapshot) {
        let cardID = snapshot.providerID
        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: registry.descriptors(for: cardID),
            // The instant the quota was *read*, which is the refresh time unless the provider re-served
            // an earlier reading. See `ProviderSnapshot.quotaObservedAt`.
            capturedAt: snapshot.quotaReadAt,
            identityKey: identityKeys[cardID]
        )
        // After extraction, not before: a snapshot with nothing to record — an error badge, a provider
        // with no capped metrics, a card whose launch identity never resolved — has no attribution
        // question to answer, and running the proof check on it would park a card in `pausedCards` (and
        // tell the user recording is paused) over a refresh that was never going to write a row.
        guard !samples.isEmpty, isProven(snapshot) else { return }
        let id = UUID()
        pendingWrites[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingWrites[id] = nil }
            do {
                try await self.open()
                try await self.store.record(samples)
                self.recordingFailure = nil
                AppLog.debug(.history, "recorded \(samples.count) samples for \(cardID)")
            } catch {
                self.recordingFailure = error.localizedDescription
                AppLog.error(.history, "sample write failed for \(cardID): \(error.localizedDescription)")
            }
        }
    }

    /// Whether this snapshot's own credential proves it belongs to the account the card is keyed by.
    ///
    /// The launch identity map says which account is signed in where; `accountProof` says which account
    /// actually produced *these numbers*. Those are the same answer right up until they aren't — the
    /// providers walk credential fallback chains (Codex: each `auth.json`, then the keychain; Claude:
    /// keychain, file, then possibly the system-wide Desktop login), and a sign-out and sign-in under a
    /// running app moves the live credential without moving the launch map. Only the proof may key a
    /// row, so a snapshot that can't produce one — a Desktop-backed fetch, an ambient env token, a
    /// credential naming no account — is dropped whole.
    ///
    /// Dropping is deliberately the *conservative* outcome and not a data loss worth trading away: a
    /// gap can be filled in by the next refresh, or by relaunching so the identity pass re-runs. Two
    /// accounts spliced into one append-only line cannot be separated afterwards, ever.
    ///
    /// Providers outside the account-aware families have no account identity to prove and are waved
    /// through here; `QuotaSampleExtractor` keys their series by card id alone.
    private func isProven(_ snapshot: ProviderSnapshot) -> Bool {
        let cardID = snapshot.providerID
        guard ProviderAccountID.families.contains(ProviderAccountID.family(of: cardID)) else { return true }
        guard let launchIdentity = identityKeys[cardID], snapshot.accountProof == launchIdentity else {
            // Logged once per card rather than once per refresh: a swapped account stays swapped, and a
            // warning every 5 minutes for days would bury everything else in the log.
            if pausedCards.insert(cardID).inserted {
                AppLog.warn(
                    .history,
                    "\(cardID): this refresh came from a different account than the one superUsage "
                        + "launched with (or from a credential that can't name its account); "
                        + "history paused for this card"
                )
            }
            return false
        }
        // Recording resumes on its own if the proven account comes back — signing out and back in, or a
        // Desktop-backed pass followed by a normal one. Nothing is at risk in resuming: every single
        // write is checked against this same proof, so a resumed card is writing rows it has proven.
        if pausedCards.remove(cardID) != nil {
            AppLog.info(.history, "\(cardID): refreshes are the launch account's again; history resumed")
        }
        return true
    }

    /// Every card that is currently recording nothing, and why.
    ///
    /// Two different silences, and neither one can be seen from the chart — a card that has never
    /// recorded has no series, so it isn't even in the picker to be selected and explained:
    ///
    /// - `.unattributable` — the launch identity pass never named this card's account (a Codex login
    ///   held in the keychain is the ordinary case), so `QuotaSampleExtractor` produces nothing to key
    ///   and no row is ever written. Permanent for the life of the process, and *not* something waiting
    ///   longer fixes, which is exactly why saying nothing would be the wrong answer.
    /// - `.mismatched` — the card did resolve, but its refreshes are now coming back from a different
    ///   account (see `isProven`). Recording is suspended until they match again.
    ///
    /// Only the account-first families can be in either state; everything else is keyed by card id alone
    /// and always records.
    var recordingGaps: [QuotaHistoryRecordingGap] {
        registry.providers.compactMap { provider in
            guard ProviderAccountID.families.contains(ProviderAccountID.family(of: provider.id)) else {
                return nil
            }
            guard identityKeys[provider.id] != nil else {
                return QuotaHistoryRecordingGap(provider: provider, reason: .unattributable)
            }
            guard pausedCards.contains(provider.id) else { return nil }
            return QuotaHistoryRecordingGap(provider: provider, reason: .mismatched)
        }
    }

    /// Opens the store and runs retention, independent of whether anything is being written.
    ///
    /// Retention deliberately does **not** hang off the write path. A user who signs out, disables every
    /// capped provider, or simply has a provider failing for weeks stops producing samples — and that is
    /// exactly when the old rows most need to age out. Hanging pruning off new writes would let the
    /// database keep data past the 35 days the app promises, for as long as nothing new arrives.
    func startMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pruneIfDue()
                try? await Task.sleep(for: .seconds(Self.maintenanceInterval))
            }
        }
    }

    func stopMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    /// The series that have samples on record, annotated with the display names the picker shows.
    /// Series whose provider or metric is no longer in the registry are dropped — a provider removed by
    /// an update leaves rows behind, and there is nothing meaningful to label them with.
    func scopes() async -> [QuotaHistoryDisplayScope] {
        do {
            try await open()
            let scopes = try await store.scopes().compactMap { scope -> QuotaHistoryDisplayScope? in
                guard let provider = registry.provider(id: scope.providerID),
                      let descriptor = registry.descriptor(id: scope.metricID)
                else { return nil }
                return QuotaHistoryDisplayScope(
                    scope: scope,
                    provider: provider,
                    metricTitle: descriptor.title
                )
            }
            failure = nil
            return scopes
        } catch {
            AppLog.error(.history, "scope read failed: \(error.localizedDescription)")
            failure = error.localizedDescription
            return []
        }
    }

    /// The chartable series for one scope and range.
    func series(scopeKey: String, range: QuotaHistoryRange) async -> QuotaHistorySeries {
        let end = now()
        let start = end.addingTimeInterval(-range.duration)
        do {
            try await open()
            var samples = try await store.samples(scopeKey: scopeKey, from: start, to: end)
            // Splice on the newest sample from before the window, whenever it was taken. The aggregator
            // needs exactly one such neighbour to judge the left edge (see `QuotaHistoryAggregator`); an
            // arbitrary over-read of the range would supply it only when the neighbour happens to be
            // recent, which is precisely not the case after a long sleep or outage.
            if let previous = try await store.sampleImmediatelyBefore(scopeKey: scopeKey, date: start) {
                samples.insert(previous, at: 0)
            }
            failure = nil
            return QuotaHistoryAggregator.series(samples: samples, range: range, now: end)
        } catch {
            AppLog.error(.history, "series read failed for \(scopeKey): \(error.localizedDescription)")
            failure = error.localizedDescription
            return .empty
        }
    }

    /// Whether any sample write is still in flight.
    var hasPendingWrites: Bool { !pendingWrites.isEmpty }

    /// Waits out in-flight sample writes, giving up after `timeout`. Returns whether everything drained.
    ///
    /// Called from the app-termination hook so a quit right after a refresh doesn't drop that pass's
    /// samples — but a quit must never be *held* by the database. That rules out awaiting the write
    /// tasks: a task group only returns once every child is done, and cancelling a child doesn't cancel
    /// the Core Data save underneath it, so racing a write against a sleep would still wait for the
    /// write. Polling the pending set instead is the only shape where the timeout is real, and it makes
    /// the worst case a bounded delay rather than an app stuck in `.terminateLater` until force-quit.
    @discardableResult
    func flushPendingWrites(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !pendingWrites.isEmpty {
            if clock.now >= deadline {
                AppLog.warn(.history, "quit with \(pendingWrites.count) sample write(s) still in flight")
                return false
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    private func open() async throws {
        if let openTask {
            return try await openTask.value
        }
        let task = Task { [store] in
            try await store.load()
        }
        openTask = task
        do {
            try await task.value
            failure = nil
        } catch {
            // A store that won't open is a real, user-visible problem (no history will ever be recorded),
            // so it is surfaced rather than swallowed. Clearing the task lets a later refresh retry —
            // the common causes (a locked or briefly unavailable Application Support directory) are
            // transient.
            openTask = nil
            failure = error.localizedDescription
            AppLog.error(.history, "store failed to open: \(error.localizedDescription)")
            throw error
        }
    }

    func pruneIfDue() async {
        let current = now()
        if let lastPruneAt, current.timeIntervalSince(lastPruneAt) < Self.pruneInterval { return }
        do {
            try await open()
            let deleted = try await store.prune(before: current.addingTimeInterval(-retentionWindow))
            // Only a prune that actually ran counts. Stamping the attempt would let one transient store
            // error (a locked Application Support directory at launch) silence retention for a further
            // 24 hours, which is the app quietly keeping data past the window it promises.
            lastPruneAt = current
            retentionFailure = nil
            if deleted > 0 {
                AppLog.info(.history, "pruned \(deleted) samples older than \(Int(retentionWindow / 86_400))d")
            }
        } catch {
            retentionFailure = error.localizedDescription
            AppLog.warn(.history, "prune failed: \(error.localizedDescription)")
        }
    }
}

/// One card that is recording nothing, and why. See `QuotaHistoryRecorder.recordingGaps`.
struct QuotaHistoryRecordingGap: Hashable, Sendable, Identifiable {
    enum Reason: Hashable, Sendable {
        /// No account was resolved for this card at launch, so nothing it reports can be keyed.
        case unattributable
        /// Refreshes are coming back from a different account than the one this process launched with.
        case mismatched
    }

    let provider: Provider
    let reason: Reason

    var id: String { provider.id }
}

extension QuotaHistoryRecordingGap.Reason {
    /// "this will not start on its own" vs "this is suspended" — the two need to read differently at a
    /// glance, since only one of them is worth acting on.
    var icon: String {
        switch self {
        case .unattributable: "person.crop.circle.badge.questionmark"
        case .mismatched: "pause.circle"
        }
    }
}

/// A recorded series plus the names the picker renders it under.
struct QuotaHistoryDisplayScope: Hashable, Sendable, Identifiable {
    let scope: QuotaHistoryScope
    let provider: Provider
    let metricTitle: String

    var id: String { scope.scopeKey }
    var scopeKey: String { scope.scopeKey }
    var providerID: String { scope.providerID }
    var accountDigest: String? { scope.accountDigest }

    /// The picker's first-level unit: a card **as seen by one account**. Two accounts that have both
    /// held a family's default home share the card id `claude`, so grouping by `providerID` alone would
    /// stack two people's series under one entry.
    var cardKey: String { "\(scope.providerID)|\(scope.accountDigest ?? "")" }
}
