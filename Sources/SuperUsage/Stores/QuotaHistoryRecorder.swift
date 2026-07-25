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

    /// Serializes "the store is open" across every caller: each operation awaits this one task instead
    /// of racing its own `load()`.
    @ObservationIgnored private var openTask: Task<Void, Error>?
    /// In-flight writes, so `flushPendingWrites()` can wait them out before the app exits. Keyed so each
    /// task can retire its own entry on completion and the map can't grow across a long session.
    @ObservationIgnored private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastPruneAt: Date?

    /// Whether the store has failed to open. Surfaced so the history window can explain itself rather
    /// than showing a permanently empty chart.
    private(set) var openFailure: String?

    /// How often retention runs. Pruning is pure bookkeeping — nothing user-visible depends on it
    /// happening promptly — so once a day is plenty, and it costs one indexed range delete.
    private static let pruneInterval: TimeInterval = 24 * 60 * 60

    init(
        registry: WidgetRegistry,
        store: QuotaHistoryStore = QuotaHistoryStore(),
        retentionWindow: TimeInterval = QuotaHistoryStore.retentionWindow,
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
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
            capturedAt: snapshot.refreshedAt
        )
        guard !samples.isEmpty else { return }
        let id = UUID()
        pendingWrites[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.open()
                try await self.store.record(samples)
                AppLog.debug(.history, "recorded \(samples.count) samples for \(snapshot.providerID)")
                await self.pruneIfDue()
            } catch {
                AppLog.error(.history, "sample write failed for \(snapshot.providerID): \(error.localizedDescription)")
            }
            self.pendingWrites[id] = nil
        }
    }

    /// The series that have samples on record, annotated with the display names the picker shows.
    /// Series whose provider or metric is no longer in the registry are dropped — a provider removed by
    /// an update leaves rows behind, and there is nothing meaningful to label them with.
    func scopes() async -> [QuotaHistoryDisplayScope] {
        do {
            try await open()
            return try await store.scopes().compactMap { scope in
                guard let provider = registry.provider(id: scope.providerID),
                      let descriptor = registry.descriptor(id: scope.metricID)
                else { return nil }
                return QuotaHistoryDisplayScope(
                    scope: scope,
                    provider: provider,
                    metricTitle: descriptor.title
                )
            }
        } catch {
            AppLog.error(.history, "scope read failed: \(error.localizedDescription)")
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
            return QuotaHistoryAggregator.series(samples: samples, range: range, now: end)
        } catch {
            AppLog.error(.history, "series read failed for \(scopeKey): \(error.localizedDescription)")
            return .empty
        }
    }

    /// Waits out any in-flight sample writes. Called from the app-termination hook so a quit right after
    /// a refresh doesn't drop that pass's samples.
    func flushPendingWrites() async {
        for task in pendingWrites.values {
            await task.value
        }
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
            openFailure = nil
        } catch {
            // A store that won't open is a real, user-visible problem (no history will ever be recorded),
            // so it is surfaced rather than swallowed. Clearing the task lets a later refresh retry —
            // the common causes (a locked or briefly unavailable Application Support directory) are
            // transient.
            openTask = nil
            openFailure = error.localizedDescription
            AppLog.error(.history, "store failed to open: \(error.localizedDescription)")
            throw error
        }
    }

    private func pruneIfDue() async {
        let current = now()
        if let lastPruneAt, current.timeIntervalSince(lastPruneAt) < Self.pruneInterval { return }
        lastPruneAt = current
        do {
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
