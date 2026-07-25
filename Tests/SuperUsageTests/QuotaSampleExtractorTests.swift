import XCTest
@testable import SuperUsage

/// What gets written into the quota-history log — and, just as importantly, what doesn't. A metric that
/// slips in with a bogus limit, or an error snapshot that records a point, produces a chart that lies
/// about the user's burn rate, and neither is visible until someone reads the chart days later.
final class QuotaSampleExtractorTests: XCTestCase {
    private let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// Claude is an account-first family, so every sample has to be attributable to an account.
    private let identityKey = "account-a"
    /// The account half of a series key: the family plus the account's FULL identity digest — not the
    /// truncated `hash8` a card id carries. Spelled out rather than borrowed from `QuotaSeriesKey` so a
    /// change to the key format has to be made here too, deliberately: history is append-only, so a
    /// silently reformatted key strands every row already on disk.
    private var accountScope: String { "claude@\(ProviderAccountID.identityDigest(identityKey))" }

    private var sessionDescriptor: WidgetDescriptor {
        .percent(id: "claude.session", provider: provider, title: "Session")
    }

    private var extraDescriptor: WidgetDescriptor {
        .boundedDollars(id: "claude.extra", provider: provider, title: "Extra Usage", limit: 50)
    }

    func testSamplesCappedMetricsWithStableDescriptorIDs() {
        let resetsAt = capturedAt.addingTimeInterval(3_600)
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent, resetsAt: resetsAt),
                .progress(label: "Extra Usage", used: 12.5, limit: 50, format: .dollars)
            ],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor, extraDescriptor],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertEqual(samples.count, 2)
        let session = samples[0]
        // The stable descriptor id, not the display label — a metric reworded in a later release must
        // stay the same series rather than starting a new one.
        XCTAssertEqual(session.metricID, "claude.session")
        XCTAssertEqual(session.scopeKey, "\(accountScope)|claude.session")
        XCTAssertEqual(session.used, 40)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.resetsAt, resetsAt)
        XCTAssertEqual(session.remainingFraction, 0.6)

        XCTAssertEqual(samples[1].scopeKey, "\(accountScope)|claude.extra")
        XCTAssertEqual(samples[1].remainingFraction, 0.75)
        XCTAssertNil(samples[1].resetsAt)
    }

    /// A failed refresh has to leave a gap. Recording the error snapshot would instead plant a point,
    /// making "we couldn't look" indistinguishable from "the quota stopped moving".
    func testErrorSnapshotProducesNoSamples() {
        let snapshot = ProviderSnapshot.error(provider: provider, message: "Not logged in")

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// Unbounded rows, charts, and badges have no remaining-quota story; sampling them would chart a
    /// denominator that doesn't exist.
    func testSkipsUnboundedAndNonProgressLines() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [
                .values(label: "Today", values: [MetricValue(number: 4.08, kind: .dollars)]),
                .badge(label: "Plan", text: "Max"),
                .chart(label: "Usage Trend", points: [MetricChartPoint(value: 1, label: "Jul 1")])
            ],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [
                .values(id: "claude.today", provider: provider, title: "Today"),
                .badge(id: "claude.plan", provider: provider, title: "Plan"),
                .usageTrend(provider: provider)
            ],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// A zero or non-finite limit is not a usable denominator. Charting it would render as a hard 0% or
    /// 100% that the provider never actually reported.
    func testSkipsUnusableLimits() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [
                .progress(label: "Session", used: 10, limit: 0, format: .percent),
                .progress(label: "Extra Usage", used: 10, limit: .nan, format: .dollars)
            ],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor, extraDescriptor],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// The stored point has to match the meter the user saw. The dashboard clamps an out-of-range
    /// percent at its single construction choke point, so the extractor clamps identically — otherwise
    /// the chart and the bar would disagree about the same refresh.
    func testClampsOutOfRangePercentLikeTheDashboard() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 137, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertEqual(samples.first?.used, 100)
        XCTAssertEqual(samples.first?.remainingFraction, 0)
    }

    /// A dollar overage is real information, so it survives where a percent overage is clamped.
    func testKeepsDollarOverage() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Extra Usage", used: 62, limit: 50, format: .dollars)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [extraDescriptor],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertEqual(samples.first?.used, 62)
        // Remaining still floors at zero: the window can't hold less than nothing.
        XCTAssertEqual(samples.first?.remainingFraction, 0)
    }

    /// An extra account card already carries a digest in its id — but a truncated one the account
    /// registry is free to salt on a collision. A series key has no arbiter, so it is rebuilt from the
    /// full digest instead of reusing the card id: two salted cards must not be able to collide into one
    /// permanent, unsplittable series.
    func testAccountCardIsKeyedByItsFullDigestNotItsCardID() {
        let cardID = ProviderAccountID.make(family: "claude", identityKey: identityKey)
        let accountProvider = Provider(id: cardID, displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.percent(id: "\(cardID).session", provider: accountProvider, title: "Session")
        let snapshot = ProviderSnapshot(
            providerID: cardID,
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [descriptor],
            capturedAt: capturedAt,
            identityKey: identityKey
        )

        XCTAssertEqual(samples.first?.scopeKey, "\(accountScope)|\(cardID).session")
        XCTAssertEqual(samples.first?.accountDigest, ProviderAccountID.identityDigest(identityKey))
        // The card id's own truncated digest is a prefix of the key's, never the whole of it.
        XCTAssertNotEqual(accountScope, cardID)
        XCTAssertTrue(accountScope.hasPrefix(cardID))
    }

    /// The one that matters: the account holding a family's *default home* keeps the bare `claude` card
    /// id for life, so after a sign-out and sign-in the same card is a different account. Keying history
    /// by card id alone would append account B's usage onto account A's line — permanently, since a row
    /// carries no way to tell them apart afterwards. History is append-only; there is no cleanup pass
    /// that could separate them later.
    func testDefaultCardSwappingAccountsStartsANewSeries() {
        func sample(identityKey: String) -> QuotaSample? {
            let snapshot = ProviderSnapshot(
                providerID: "claude",
                displayName: "Claude",
                lines: [.progress(label: "Session", used: 40, limit: 100, format: .percent)],
                refreshedAt: capturedAt
            )
            return QuotaSampleExtractor.samples(
                from: snapshot,
                descriptors: [sessionDescriptor],
                capturedAt: capturedAt,
                identityKey: identityKey
            ).first
        }

        let a = sample(identityKey: "account-a")
        let b = sample(identityKey: "account-b")

        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a?.scopeKey, b?.scopeKey)
        // Both still report the card they came from; the account lives in its own column so a row stays
        // attributable even if the key format ever changes.
        XCTAssertEqual(a?.providerID, "claude")
        XCTAssertEqual(b?.providerID, "claude")
        XCTAssertEqual(a?.accountDigest, ProviderAccountID.identityDigest("account-a"))
        XCTAssertEqual(b?.accountDigest, ProviderAccountID.identityDigest("account-b"))
    }

    /// An account-first card whose identity didn't resolve records nothing at all. A gap is recoverable;
    /// a sample written under an unattributable bare `claude` is not — the next swap would silently
    /// append a second account's usage to it.
    func testUnresolvedIdentityOnAccountFamilyRecordsNothing() {
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 40, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [sessionDescriptor],
            capturedAt: capturedAt,
            identityKey: nil
        )

        XCTAssertTrue(samples.isEmpty)
    }

    /// Providers with no account model at all (Grok, Copilot, …) are unaffected: they have one identity
    /// by construction, so a nil key is normal and must still record.
    func testProviderWithoutAccountModelRecordsWithoutIdentity() {
        let grok = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor.percent(id: "grok.weekly", provider: grok, title: "Weekly")
        let snapshot = ProviderSnapshot(
            providerID: "grok",
            displayName: "Grok",
            lines: [.progress(label: "Weekly", used: 30, limit: 100, format: .percent)],
            refreshedAt: capturedAt
        )

        let samples = QuotaSampleExtractor.samples(
            from: snapshot,
            descriptors: [descriptor],
            capturedAt: capturedAt,
            identityKey: nil
        )

        XCTAssertEqual(samples.first?.scopeKey, "grok|grok.weekly")
        XCTAssertNil(samples.first?.accountDigest)
    }
}
