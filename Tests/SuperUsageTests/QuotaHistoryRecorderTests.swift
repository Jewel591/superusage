import XCTest
@testable import SuperUsage

/// The recorder is the only thing that writes history, and the three things it has to get right are all
/// invisible until they've already gone wrong: samples must be attributed to the account that produced
/// them, retention must run whether or not anything is being written, and a quit must never be held
/// open by the database.
@MainActor
final class QuotaHistoryRecorderTests: XCTestCase {
    private var storeURL: URL!
    private var store: QuotaHistoryStore!

    private let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

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

    private var descriptor: WidgetDescriptor {
        .percent(id: "claude.session", provider: provider, title: "Session")
    }

    private func makeRecorder(
        identityKeys: [String: String] = ["claude": "account-a"],
        now: @escaping () -> Date = Date.init
    ) -> QuotaHistoryRecorder {
        QuotaHistoryRecorder(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            identityKeys: identityKeys,
            store: store,
            now: now
        )
    }

    private func snapshot(used: Double, at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: date
        )
    }

    /// Signing out of one account and into another on a family's *default* card keeps the card id
    /// `claude`, so the identity the recorder was launched with is the only thing separating the two
    /// histories. Identity is a launch pass throughout the app, so the two recorders here stand for two
    /// launches — the second must open a new line rather than continue account A's.
    func testSwappingAccountsStartsANewSeriesOnTheNextLaunch() async throws {
        let beforeSwap = makeRecorder(identityKeys: ["claude": "account-a"])
        beforeSwap.record(snapshot: snapshot(used: 40, at: capturedAt))
        var flushed = await beforeSwap.flushPendingWrites()
        XCTAssertTrue(flushed)

        let afterSwap = makeRecorder(identityKeys: ["claude": "account-b"])
        afterSwap.record(snapshot: snapshot(used: 5, at: capturedAt.addingTimeInterval(300)))
        flushed = await afterSwap.flushPendingWrites()
        XCTAssertTrue(flushed)

        let scopes = try await store.scopes()
        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(
            Set(scopes.map(\.scopeKey)),
            [
                "\(ProviderAccountID.make(family: "claude", identityKey: "account-a"))|claude.session",
                "\(ProviderAccountID.make(family: "claude", identityKey: "account-b"))|claude.session"
            ]
        )
        // Both rows still name the card they came from, so a swap is visible rather than inferred.
        XCTAssertEqual(Set(scopes.map(\.providerID)), ["claude"])
    }

    /// Retention deliberately does not hang off the write path. The user whose data most needs to age
    /// out is exactly the one who stopped producing samples — signed out, provider disabled, or a
    /// provider that has been failing for weeks — and hanging pruning off new writes would keep their
    /// rows forever while the app promises 35 days.
    func testPruneRunsWhenNothingIsBeingRecorded() async throws {
        let old = capturedAt.addingTimeInterval(-40 * 24 * 60 * 60)
        try await store.record([
            QuotaSample(
                scopeKey: "claude|claude.session",
                providerID: "claude",
                accountDigest: "aaaaaaaa",
                metricID: "claude.session",
                capturedAt: old,
                used: 10,
                limit: 100,
                format: .percent,
                resetsAt: nil
            )
        ])
        let recorder = makeRecorder(now: { self.capturedAt })

        // No `record(snapshot:)` call at all — the maintenance path is the only thing running.
        await recorder.pruneIfDue()

        let remaining = try await store.sampleCount()
        XCTAssertEqual(remaining, 0)
    }

    /// A prune is bookkeeping, not something the user waits for, so it runs at most daily rather than on
    /// every wake-up of the maintenance loop.
    func testPruneIsRateLimited() async throws {
        var clock = capturedAt
        let recorder = makeRecorder(now: { clock })
        await recorder.pruneIfDue()

        try await store.record([
            QuotaSample(
                scopeKey: "claude|claude.session",
                providerID: "claude",
                accountDigest: "aaaaaaaa",
                metricID: "claude.session",
                capturedAt: capturedAt.addingTimeInterval(-40 * 24 * 60 * 60),
                used: 10,
                limit: 100,
                format: .percent,
                resetsAt: nil
            )
        ])

        clock = capturedAt.addingTimeInterval(60 * 60)
        await recorder.pruneIfDue()
        var count = try await store.sampleCount()
        XCTAssertEqual(count, 1, "an hour later is too soon to prune again")

        clock = capturedAt.addingTimeInterval(25 * 60 * 60)
        await recorder.pruneIfDue()
        count = try await store.sampleCount()
        XCTAssertEqual(count, 0, "a day later it runs")
    }

    /// The quit hook waits for in-flight writes so a quit right after a refresh doesn't punch a hole in
    /// the trend — but the wait has to be genuinely bounded, or a wedged store turns into an app stuck
    /// in `.terminateLater` until the user force-quits. Racing a write task against a sleep does *not*
    /// give that bound: cancelling the child doesn't cancel the Core Data save underneath it, so the
    /// group still waits out the full write. Polling does.
    func testFlushIsBoundedByItsTimeout() async {
        let recorder = makeRecorder()
        recorder.record(snapshot: snapshot(used: 40, at: capturedAt))
        XCTAssertTrue(recorder.hasPendingWrites)

        let elapsed = await ContinuousClock().measure {
            _ = await recorder.flushPendingWrites(timeout: .milliseconds(50))
        }

        XCTAssertLessThan(elapsed, .milliseconds(500))
        // Whatever the verdict was, the write is still allowed to land on its own.
        _ = await recorder.flushPendingWrites()
    }

    /// Nothing in flight must return immediately and truthfully, so the common quit path (no refresh in
    /// the last few seconds) doesn't defer termination at all.
    func testFlushWithNothingPendingSucceedsImmediately() async {
        let recorder = makeRecorder()

        XCTAssertFalse(recorder.hasPendingWrites)
        let flushed = await recorder.flushPendingWrites(timeout: .milliseconds(1))
        XCTAssertTrue(flushed)
    }

    /// A failed refresh must leave a hole rather than a point — and must not be attributed to anyone.
    func testErrorSnapshotIsNotRecorded() async throws {
        let recorder = makeRecorder()

        recorder.record(snapshot: .error(provider: provider, message: "Not logged in"))

        XCTAssertFalse(recorder.hasPendingWrites)
        let count = try await store.sampleCount()
        XCTAssertEqual(count, 0)
    }

    /// An account-first card with no resolved identity records nothing at all. The alternative — writing
    /// it under the bare card id — is unrecoverable: the next account to occupy that card would append
    /// to the same line with no way to tell the two apart afterwards.
    func testUnresolvedIdentityRecordsNothing() async throws {
        let recorder = makeRecorder(identityKeys: [:])

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt))

        XCTAssertFalse(recorder.hasPendingWrites)
        let count = try await store.sampleCount()
        XCTAssertEqual(count, 0)
    }
}
