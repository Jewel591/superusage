import XCTest
@testable import SuperUsage

/// Guards the in-memory write-through mirror: reads must reflect writes, a second store must not drop
/// the first, and the mirror must stay a cache over real persistence (a fresh instance reads from disk).
final class ProviderSnapshotCacheTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "providerSnapshotCache.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    func testStoreAccumulatesAcrossProvidersAndReadsReflectWrites() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        // The second store must not drop the first, and reads come back from the mirror unchanged.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(providerID: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    func testWritesPersistForAFreshInstance() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now))

        // A fresh instance starts with an empty mirror, so the *display* read (`loadSnapshots`) proves the
        // write reached disk — the mirror is a cache over persistence, not a replacement for it. (The
        // freshness gate `snapshot(providerID:)` deliberately treats this disk-loaded value as stale; see
        // `testRelaunchLoadedSnapshotIsStaleEvenWithinTTL`.)
        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["alpha"])["alpha"]?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    /// #697 core guarantee: a snapshot persisted by a *previous* session and reloaded on launch must not
    /// satisfy the refresh gate, even when its `refreshedAt` is still well within TTL — otherwise the app
    /// would wait out the previous session's remaining interval before refetching. It must still *display*
    /// (instant paint), so `loadSnapshots` returns it.
    func testRelaunchLoadedSnapshotIsStaleEvenWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        // Session 1 writes a snapshot 1s ago — comfortably inside the 9_999s TTL.
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-1)))

        // Session 2 (fresh instance = relaunch) reloads it from disk.
        let relaunched = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        // Display still paints the last-known value...
        XCTAssertNotNil(relaunched.loadSnapshots(providerIDs: ["alpha"])["alpha"])
        // ...but the refresh gate treats it as stale, forcing a refresh on the first post-launch pass.
        XCTAssertNil(relaunched.snapshot(providerID: "alpha"))
    }

    /// Acceptance criterion 2: a snapshot written *this* session still short-circuits a redundant refresh
    /// within that session (no refresh storm) — the gate is "written this session AND within TTL", not
    /// "written this session" alone.
    func testSnapshotWrittenThisSessionStaysFreshWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    /// A snapshot written this session still expires once it ages past TTL, so the periodic loop resumes
    /// refetching on the normal cadence (the session-write flag widens freshness on launch, it doesn't
    /// pin a snapshot fresh forever).
    func testSnapshotWrittenThisSessionExpiresAfterTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 100, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        now = now.addingTimeInterval(101)
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }

    /// `accountProof` names the account behind the credential that fetched, and it is deliberately left
    /// out of `ProviderSnapshot.CodingKeys` — so it never reaches this cache, the local HTTP API, or
    /// CloudKit. Two things are pinned here, and a future field added to `CodingKeys` by reflex would
    /// break both: the account identity is not written to disk, and a *decoded* snapshot is unprovable by
    /// construction, which is correct — a cache entry restored at launch is not evidence about which
    /// credential is on this machine now, and quota history must not treat it as any.
    func testAccountProofIsNeverEncodedAndDecodesBackToNil() throws {
        var proven = snapshot("alpha", used: 42, now: Date())
        proven.accountProof = "acct-1|org-9"

        let encoded = try JSONEncoder().encode(proven)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("accountProof"))
        XCTAssertFalse(json.contains("acct-1"), "not under any other key either")

        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: encoded)
        XCTAssertNil(decoded.accountProof)
        XCTAssertEqual(decoded.lines, proven.lines, "everything else still round-trips")
    }
}
