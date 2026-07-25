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
        store: QuotaHistoryStore? = nil,
        now: @escaping () -> Date = Date.init
    ) -> QuotaHistoryRecorder {
        QuotaHistoryRecorder(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            identityKeys: identityKeys,
            store: store ?? self.store,
            now: now
        )
    }

    private func sample(used: Double, at date: Date) -> QuotaSample {
        QuotaSample(
            scopeKey: "claude|claude.session",
            providerID: "claude",
            accountDigest: "aaaaaaaa",
            metricID: "claude.session",
            capturedAt: date,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: nil
        )
    }

    /// `accountProof` defaults to the account the recorder is launched with, i.e. the ordinary case:
    /// the credential that fetched belongs to the account the card is keyed by.
    private func snapshot(
        used: Double,
        at date: Date,
        quotaObservedAt: Date? = nil,
        accountProof: String? = "account-a"
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: date,
            quotaObservedAt: quotaObservedAt,
            accountProof: accountProof
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
        afterSwap.record(snapshot: snapshot(
            used: 5,
            at: capturedAt.addingTimeInterval(300),
            accountProof: "account-b"
        ))
        flushed = await afterSwap.flushPendingWrites()
        XCTAssertTrue(flushed)

        let scopes = try await store.scopes()
        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(
            Set(scopes.map(\.scopeKey)),
            [
                "claude@\(ProviderAccountID.identityDigest("account-a"))|claude.session",
                "claude@\(ProviderAccountID.identityDigest("account-b"))|claude.session"
            ]
        )
        // Both rows still name the card they came from, so a swap is visible rather than inferred.
        XCTAssertEqual(Set(scopes.map(\.providerID)), ["claude"])
    }

    /// The launch identity map is fixed for the process, but the app runs for weeks — sign out and back
    /// in mid-session and the providers start returning the NEW account's usage while the map still names
    /// the old one. Every other surface self-corrects at the next launch; history is append-only, so a
    /// row written under the wrong account is wrong forever. The batch is dropped instead.
    func testSnapshotFromAnotherAccountPausesRecordingInsteadOfMixingSeries() async throws {
        let recorder = makeRecorder(identityKeys: ["claude": "account-a"])

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt, accountProof: "account-b"))
        let flushed = await recorder.flushPendingWrites()

        XCTAssertTrue(flushed)
        let count = try await store.sampleCount()
        XCTAssertEqual(count, 0)
        // And the window can say why the chart stopped growing, instead of just showing a stale line.
        XCTAssertEqual(recorder.pausedCards, ["claude"])
    }

    /// A snapshot whose credential can't name its account is refused exactly as firmly as one from a
    /// different account. This is the Claude Desktop / ambient-token / two-logins-in-one-home case:
    /// "we couldn't tell" is what the provider reports, and it is not permission to write a row that can
    /// never be un-written.
    ///
    /// It is *reported* differently, though. "A different account is refreshing" is a claim about the
    /// user's machine, and there is no evidence for it here — so it gets its own reason, and the window
    /// doesn't send someone chasing a sign-out that never happened.
    func testSnapshotThatCannotProveItsAccountPausesUnderItsOwnReason() async throws {
        let recorder = makeRecorder(identityKeys: ["claude": "account-a"])

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt, accountProof: nil))
        _ = await recorder.flushPendingWrites()

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(recorder.pausedCards, ["claude"])
        XCTAssertEqual(recorder.recordingGaps.map(\.reason), [.unproven])

        // And a later refresh that *does* name another account is the other claim, so it re-reports.
        recorder.record(snapshot: snapshot(
            used: 41,
            at: capturedAt.addingTimeInterval(300),
            accountProof: "account-b"
        ))
        _ = await recorder.flushPendingWrites()
        XCTAssertEqual(recorder.recordingGaps.map(\.reason), [.mismatched])
    }

    /// The check must be invisible in the normal case — the credential that fetched belongs to the
    /// account the card is keyed by — and a card must un-pause once that is true again. Every write is
    /// proof-checked individually, so resuming can only ever write rows that have been proven; making
    /// the pause stick until relaunch would drop provably-correct samples for no gain.
    func testProvenSnapshotRecordsAndResumesAPausedCard() async throws {
        let recorder = makeRecorder(identityKeys: ["claude": "account-a"])

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt, accountProof: "account-b"))
        _ = await recorder.flushPendingWrites()
        XCTAssertEqual(recorder.pausedCards, ["claude"])

        recorder.record(snapshot: snapshot(used: 42, at: capturedAt.addingTimeInterval(300)))
        _ = await recorder.flushPendingWrites()

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(recorder.pausedCards.isEmpty)
    }

    /// A card whose account never resolved records nothing, ever — the extractor has no key to file its
    /// samples under, so `record` returns before the proof check and the card never lands in
    /// `pausedCards`. That makes it the one silence nothing on screen can otherwise explain: it has no
    /// series, so it isn't in the picker to be selected, and the window would tell the user to leave the
    /// app running for a trend that is never going to arrive. It has to be reported by card.
    func testCardWithNoResolvedAccountIsReportedAsRecordingNothing() async throws {
        let recorder = makeRecorder(identityKeys: [:])
        XCTAssertTrue(recorder.recordingGaps.isEmpty, "nothing is claimed before the card has refreshed")

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt, accountProof: "account-a"))
        _ = await recorder.flushPendingWrites()

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(recorder.pausedCards.isEmpty, "it never reaches the proof check")
        XCTAssertEqual(recorder.recordingGaps.map(\.id), ["claude"])
        XCTAssertEqual(recorder.recordingGaps.first?.reason, .unattributable)
    }

    /// The report is driven by refreshes, never by the provider catalog — which lists every provider the
    /// app supports, whether or not this user has the tool, has enabled it, or has ever signed in. A
    /// refresh that had nothing to record (an error badge, a provider with no capped metric) says nothing
    /// about attribution, and claiming otherwise would tell someone who doesn't use Codex that their
    /// Codex history is broken.
    func testRefreshWithNothingToRecordIsNotReportedAsAnAttributionProblem() async throws {
        let recorder = makeRecorder(identityKeys: [:])

        recorder.record(snapshot: ProviderSnapshot.error(
            provider: provider,
            error: URLError(.notConnectedToInternet)
        ))
        recorder.record(snapshot: ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.badge(label: "Plan", text: "Max")],
            refreshedAt: capturedAt
        ))
        _ = await recorder.flushPendingWrites()

        XCTAssertTrue(recorder.recordingGaps.isEmpty)
        XCTAssertTrue(recorder.unattributableCards.isEmpty)
    }

    /// A card that resolved but is now returning another account's numbers is a *different* silence: it
    /// is suspended, not stuck, and resumes on its own. Reporting both the same way would tell a user to
    /// go fix something that isn't broken — or leave them waiting on a recovery that can't happen.
    func testMismatchedCardIsReportedSeparatelyFromAnUnresolvedOne() async throws {
        let recorder = makeRecorder(identityKeys: ["claude": "account-a"])
        XCTAssertTrue(recorder.recordingGaps.isEmpty, "nothing to report before anything goes wrong")

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt, accountProof: "account-b"))
        _ = await recorder.flushPendingWrites()

        XCTAssertEqual(recorder.recordingGaps.map(\.reason), [.mismatched])

        recorder.record(snapshot: snapshot(used: 42, at: capturedAt.addingTimeInterval(300)))
        _ = await recorder.flushPendingWrites()

        XCTAssertTrue(recorder.recordingGaps.isEmpty, "cleared when the card resumes")
    }

    /// A write failure must be visible without blanking the chart. `failure` is the "can't read it at
    /// all" state and takes the whole window over; a failed write leaves every earlier point perfectly
    /// readable, so it gets its own state — otherwise the only symptom is a line that quietly stops
    /// growing, which is exactly the ambiguity this window exists to remove.
    func testWriteFailureIsSurfacedSeparatelyFromAnUnreadableStore() async throws {
        let blocked = try BlockedStore()
        defer { blocked.cleanUp() }
        let recorder = makeRecorder(store: blocked.store)

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt))
        _ = await recorder.flushPendingWrites()

        XCTAssertNotNil(recorder.recordingFailure, "the window can say the latest points weren't saved")

        // And it clears itself once writing works again, so a transient error doesn't leave a warning
        // sitting over a chart that is filling in perfectly well.
        try blocked.unblock()
        recorder.record(snapshot: snapshot(used: 42, at: capturedAt.addingTimeInterval(300)))
        _ = await recorder.flushPendingWrites()

        XCTAssertNil(recorder.recordingFailure)
    }

    /// Retention is a promise about the user's disk (35 days, `docs/quota-history.md`). A prune that
    /// keeps failing means the app has quietly stopped keeping it — nothing on screen changes, so
    /// without this it would be discoverable only by reading the log.
    func testRetentionFailureIsSurfacedAndClearedByASuccessfulPrune() async throws {
        let blocked = try BlockedStore()
        defer { blocked.cleanUp() }
        var clock = capturedAt
        let recorder = makeRecorder(store: blocked.store, now: { clock })

        await recorder.pruneIfDue()
        XCTAssertNotNil(recorder.retentionFailure)

        try blocked.unblock()
        clock = capturedAt.addingTimeInterval(60)
        await recorder.pruneIfDue()

        XCTAssertNil(recorder.retentionFailure)
    }

    /// A store whose directory is occupied by a plain *file*, so `load()` fails until `unblock()` clears
    /// it. Lets a test drive the recorder's failure states with a real Core Data error rather than a stub.
    private struct BlockedStore {
        let store: QuotaHistoryStore
        private let directory: URL
        private let blocked: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quota-history-blocked-\(UUID().uuidString)", isDirectory: true)
            blocked = directory.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: blocked)
            store = QuotaHistoryStore(
                configuration: .init(name: "blocked", storeURL: blocked.appendingPathComponent("blocked.sqlite"))
            )
        }

        func unblock() throws {
            try FileManager.default.removeItem(at: blocked)
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Providers outside the account-aware families have no account to prove. They must record normally
    /// rather than be gated into permanent silence by a check that can never pass for them.
    func testProviderWithoutAnAccountIdentityRecordsWithoutProof() async throws {
        let grok = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor.percent(id: "grok.session", provider: grok, title: "Session")
        let recorder = QuotaHistoryRecorder(
            registry: WidgetRegistry(providers: [grok], descriptors: [descriptor]),
            identityKeys: [:],
            store: store
        )

        recorder.record(snapshot: ProviderSnapshot(
            providerID: "grok",
            displayName: "Grok",
            lines: [.progress(label: "Session", used: 40, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        ))
        _ = await recorder.flushPendingWrites()

        let scopes = try await store.scopes()
        XCTAssertEqual(scopes.map(\.scopeKey), ["grok|grok.session"])
        XCTAssertTrue(recorder.pausedCards.isEmpty)
    }

    /// Claude's usage endpoint rate-limits routinely, and during the cooldown the provider re-serves its
    /// last-good reading on a perfectly successful, non-error snapshot. Recording that at the refresh
    /// time would mint a new point every five minutes for hours nobody measured — a flat line where the
    /// truth is a gap. Stamped with the instant the quota was actually read, the re-serve lands on the
    /// row already on record and the store's uniqueness constraint absorbs it.
    func testReServedQuotaReadingDoesNotMintANewPoint() async throws {
        let recorder = makeRecorder()

        recorder.record(snapshot: snapshot(used: 40, at: capturedAt))
        _ = await recorder.flushPendingWrites()
        // Same reading, re-served five and ten minutes later while the cooldown holds.
        recorder.record(snapshot: snapshot(
            used: 40,
            at: capturedAt.addingTimeInterval(300),
            quotaObservedAt: capturedAt
        ))
        recorder.record(snapshot: snapshot(
            used: 40,
            at: capturedAt.addingTimeInterval(600),
            quotaObservedAt: capturedAt
        ))
        _ = await recorder.flushPendingWrites()

        let count = try await store.sampleCount()
        XCTAssertEqual(count, 1)
    }

    /// The left edge of a chart is only interpretable against the sample on the other side of it — and
    /// that sample can be arbitrarily old, because a Mac that slept for two days has nothing in between.
    /// Reading a fixed span past the window would find it only when it happens to be recent, so a woken
    /// Mac would open on a chart that silently claims the range began at its first post-wake reading.
    func testSeriesFindsTheNeighbourBeforeTheWindowHoweverOldItIs() async throws {
        let now = capturedAt
        // Nearly drained three days ago, nearly full again twelve minutes ago: the window rolled over
        // during the silence, and only the out-of-window sample can prove it.
        try await store.record([
            sample(used: 90, at: now.addingTimeInterval(-3 * 24 * 60 * 60)),
            sample(used: 5, at: now.addingTimeInterval(-12 * 60)),
            sample(used: 8, at: now.addingTimeInterval(-7 * 60))
        ])
        let recorder = makeRecorder(now: { now })

        let series = await recorder.series(scopeKey: "claude|claude.session", range: .day)

        XCTAssertEqual(series.resets, [now.addingTimeInterval(-12 * 60)])
        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.gaps.first?.start, now.addingTimeInterval(-24 * 60 * 60))
        XCTAssertEqual(series.gaps.first?.end, now.addingTimeInterval(-12 * 60))
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

    /// A prune that *failed* must not count as a prune. Stamping the attempt would let one transient
    /// error — an Application Support directory briefly unavailable at launch, which is exactly when the
    /// first prune runs — silence retention for another 24 hours, i.e. the app quietly keeping data past
    /// the window it promises.
    func testFailedPruneDoesNotCountAsHavingPruned() async throws {
        let blocked = try BlockedStore()
        defer { blocked.cleanUp() }
        let blockedStore = blocked.store
        var clock = capturedAt
        let recorder = makeRecorder(store: blockedStore, now: { clock })

        await recorder.pruneIfDue()
        XCTAssertNotNil(recorder.failure, "the store could not be opened, so nothing was pruned")

        // Clear the blockage and put an expired row in place.
        try blocked.unblock()
        try await blockedStore.load()
        try await blockedStore.record([sample(used: 10, at: capturedAt.addingTimeInterval(-40 * 24 * 60 * 60))])

        // A minute later — far inside the daily interval. It must still run, because the first attempt
        // never actually pruned anything.
        clock = capturedAt.addingTimeInterval(60)
        await recorder.pruneIfDue()

        let remaining = try await blockedStore.sampleCount()
        XCTAssertEqual(remaining, 0)
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
        // An error snapshot carries no proof either, but it isn't an attribution problem — telling the
        // user recording is paused because the provider is failing would name the wrong cause.
        XCTAssertTrue(recorder.pausedCards.isEmpty)
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
        XCTAssertTrue(recorder.pausedCards.isEmpty, "nothing was ever recorded for this card to pause")
    }
}
