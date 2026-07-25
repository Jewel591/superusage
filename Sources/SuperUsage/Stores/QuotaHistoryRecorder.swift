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
    /// to it. Re-reading identity here alone would make history disagree with every other surface
    /// during the window it's meant to fix. The bounded consequence is stated in `docs/quota-history.md`.
    private let identityKeys: [String: String]

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
        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: registry.descriptors(for: snapshot.providerID),
            capturedAt: snapshot.refreshedAt,
            identityKey: identityKeys[snapshot.providerID]
        )
        guard !samples.isEmpty else { return }
        let id = UUID()
        pendingWrites[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.open()
                try await self.store.record(samples)
                AppLog.debug(.history, "recorded \(samples.count) samples for \(snapshot.providerID)")
            } catch {
                AppLog.error(.history, "sample write failed for \(snapshot.providerID): \(error.localizedDescription)")
            }
            self.pendingWrites[id] = nil
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
        // Read one bucket earlier than the range so the first bucket is complete and so a reset or gap
        // straddling the left edge is detected from a real neighbouring sample instead of appearing as a
        // series that simply starts there.
        let start = end.addingTimeInterval(-(range.duration + range.bucket))
        do {
            try await open()
            let samples = try await store.samples(scopeKey: scopeKey, from: start, to: end)
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
        lastPruneAt = current
        do {
            try await open()
            let deleted = try await store.prune(before: current.addingTimeInterval(-retentionWindow))
            if deleted > 0 {
                AppLog.info(.history, "pruned \(deleted) samples older than \(Int(retentionWindow / 86_400))d")
            }
        } catch {
            AppLog.warn(.history, "prune failed: \(error.localizedDescription)")
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
}
