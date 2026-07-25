import XCTest
@testable import SuperUsage

/// The persistence layer's contract: samples survive, duplicates don't accumulate, series stay
/// separated, and retention actually deletes.
///
/// These run against a real SQLite store in a temporary directory rather than an in-memory one —
/// `NSBatchDeleteRequest` (the pruning path) and fetch indexes don't exist for the in-memory store, so
/// an in-memory test could pass while pruning is broken in production.
final class QuotaHistoryStoreTests: XCTestCase {
    private var storeURL: URL!
    private var store: QuotaHistoryStore!

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        try await super.setUp()
        let configuration = QuotaHistoryStore.Configuration.temporary()
        storeURL = configuration.storeURL
        store = QuotaHistoryStore(configuration: configuration)
        try await store.load()
    }

    override func tearDown() async throws {
        store = nil
        if let directory = storeURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        storeURL = nil
        try await super.tearDown()
    }

    private func sample(
        scopeKey: String = "claude|claude.session",
        providerID: String = "claude",
        accountDigest: String? = "aaaaaaaa",
        metricID: String = "claude.session",
        minutesAfterStart: Double,
        used: Double,
        limit: Double = 100,
        format: ProgressFormat = .percent,
        resetsAt: Date? = nil
    ) -> QuotaSample {
        QuotaSample(
            scopeKey: scopeKey,
            providerID: providerID,
            accountDigest: accountDigest,
            metricID: metricID,
            capturedAt: start.addingTimeInterval(minutesAfterStart * 60),
            used: used,
            limit: limit,
            format: format,
            resetsAt: resetsAt
        )
    }

    func testRecordedSamplesReadBackIntact() async throws {
        let resetsAt = start.addingTimeInterval(7_200)
        try await store.record([
            sample(minutesAfterStart: 0, used: 10, resetsAt: resetsAt),
            sample(minutesAfterStart: 5, used: 20, resetsAt: resetsAt)
        ])

        let read = try await store.samples(
            scopeKey: "claude|claude.session",
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(3_600)
        )

        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.map(\.used), [10, 20])
        XCTAssertEqual(read.first?.resetsAt, resetsAt)
        XCTAssertEqual(read.first?.format, .percent)
        XCTAssertEqual(read.first?.metricID, "claude.session")
    }

    /// A count metric's suffix has to survive the round trip, or the readout loses its unit.
    func testCountFormatRoundTripsWithItsSuffix() async throws {
        try await store.record([
            sample(
                scopeKey: "cursor|cursor.requests",
                providerID: "cursor",
                metricID: "cursor.requests",
                minutesAfterStart: 0,
                used: 120,
                limit: 500,
                format: .count(suffix: "requests")
            )
        ])

        let read = try await store.samples(
            scopeKey: "cursor|cursor.requests",
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )

        XCTAssertEqual(read.first?.format, .count(suffix: "requests"))
    }

    /// The same fetch can reach the recorder twice — a forced refresh racing the periodic pass, or the
    /// one-shot CLI writing while the app runs. Both carry the same `refreshedAt`, and re-recording it
    /// would show as an extra point rather than new information.
    func testReRecordingTheSameObservationIsIgnored() async throws {
        let batch = [sample(minutesAfterStart: 0, used: 10), sample(minutesAfterStart: 5, used: 20)]
        try await store.record(batch)
        try await store.record(batch)

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 2)
    }

    /// Dedup is on `(series, instant)` — a genuinely new observation at a new instant must still land.
    func testNewObservationAfterADuplicateStillLands() async throws {
        try await store.record([sample(minutesAfterStart: 0, used: 10)])
        try await store.record([
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 5, used: 20)
        ])

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 2)
    }

    /// The app and the `superusage` CLI are separate processes writing the same file, so a forced CLI
    /// refresh can land the same observation the app is already writing. Dedup therefore has to hold at
    /// the *store* level (a uniqueness constraint), not just within one recorder's in-memory context —
    /// the second process has no idea what the first one queued.
    func testDuplicateFromASecondStoreOnTheSameFileIsIgnored() async throws {
        let second = QuotaHistoryStore(
            configuration: QuotaHistoryStore.Configuration(name: "superUsageQuotaHistoryTests", storeURL: storeURL)
        )
        try await second.load()

        try await store.record([sample(minutesAfterStart: 0, used: 10)])
        try await second.record([sample(minutesAfterStart: 0, used: 10)])

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 1)
    }

    /// The digest is what makes a row attributable after the fact — the key format could change, but a
    /// row that already lost its account can never be re-attributed.
    func testAccountDigestRoundTrips() async throws {
        try await store.record([
            sample(accountDigest: "deadbeef", minutesAfterStart: 0, used: 10),
            sample(
                scopeKey: "grok|grok.weekly",
                providerID: "grok",
                accountDigest: nil,
                metricID: "grok.weekly",
                minutesAfterStart: 0,
                used: 20
            )
        ])

        let claude = try await store.samples(
            scopeKey: "claude|claude.session",
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )
        let grok = try await store.samples(
            scopeKey: "grok|grok.weekly",
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )

        XCTAssertEqual(claude.first?.accountDigest, "deadbeef")
        XCTAssertNil(grok.first?.accountDigest)
    }

    /// Two accounts of the same provider, or two metrics of one provider, must never share a series.
    /// Note the two accounts here sit on the *same* card id (`claude`, a family's default home) — that is
    /// the case the scope key has to separate, since the card id alone can't.
    func testSeriesAreReadIndependently() async throws {
        try await store.record([
            sample(minutesAfterStart: 0, used: 10),
            sample(
                scopeKey: "claude@ab12cd34|claude.session",
                accountDigest: "ab12cd34",
                minutesAfterStart: 0,
                used: 90
            ),
            sample(
                scopeKey: "claude|claude.weekly",
                metricID: "claude.weekly",
                minutesAfterStart: 0,
                used: 50
            )
        ])

        let session = try await store.samples(
            scopeKey: "claude|claude.session",
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )

        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.first?.used, 10)
    }

    func testRangeQueryExcludesSamplesOutsideTheWindow() async throws {
        try await store.record([
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 120, used: 40)
        ])

        let read = try await store.samples(
            scopeKey: "claude|claude.session",
            from: start.addingTimeInterval(60 * 60),
            to: start.addingTimeInterval(180 * 60)
        )

        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.used, 40)
    }

    func testScopesListsEachSeriesOnceNewestFirst() async throws {
        try await store.record([
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 5, used: 20),
            sample(
                scopeKey: "codex|codex.weekly",
                providerID: "codex",
                metricID: "codex.weekly",
                minutesAfterStart: 60,
                used: 30
            )
        ])

        let scopes = try await store.scopes()

        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(scopes.first?.scopeKey, "codex|codex.weekly")
        XCTAssertEqual(scopes.first?.latestSample, start.addingTimeInterval(60 * 60))
        XCTAssertEqual(scopes.last?.latestSample, start.addingTimeInterval(5 * 60))
    }

    func testPruneDeletesOnlySamplesOlderThanTheCutoff() async throws {
        try await store.record([
            sample(minutesAfterStart: 0, used: 10),
            sample(minutesAfterStart: 60, used: 20),
            sample(minutesAfterStart: 120, used: 30)
        ])

        let deleted = try await store.prune(before: start.addingTimeInterval(90 * 60))

        XCTAssertEqual(deleted, 2)
        let remaining = try await store.sampleCount()
        XCTAssertEqual(remaining, 1)
        let read = try await store.samples(
            scopeKey: "claude|claude.session",
            from: start,
            to: start.addingTimeInterval(300 * 60)
        )
        XCTAssertEqual(read.first?.used, 30)
    }

    /// The store is the app's memory across launches — samples written by one session have to be there
    /// for the next one, or every restart resets the trend.
    func testSamplesSurviveReopeningTheStore() async throws {
        try await store.record([sample(minutesAfterStart: 0, used: 10)])

        let reopened = QuotaHistoryStore(
            configuration: QuotaHistoryStore.Configuration(name: "superUsageQuotaHistoryTests", storeURL: storeURL)
        )
        try await reopened.load()

        let read = try await reopened.samples(
            scopeKey: "claude|claude.session",
            from: start.addingTimeInterval(-60),
            to: start.addingTimeInterval(60)
        )
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.used, 10)
    }

    func testOperationsBeforeLoadFailLoudly() async throws {
        let unloaded = QuotaHistoryStore(configuration: .temporary())

        do {
            _ = try await unloaded.sampleCount()
            XCTFail("Expected a storeNotLoaded error")
        } catch QuotaHistoryStoreError.storeNotLoaded {
            // Expected: the store refuses to answer rather than silently returning nothing.
        }
    }
}
