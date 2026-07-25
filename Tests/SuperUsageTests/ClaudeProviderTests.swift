import XCTest
@testable import SuperUsage

final class ClaudeAuthStoreTests: XCTestCase {
    func testParsesHexEncodedCredentials() {
        let raw = #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro"}}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let credentials = ClaudeAuthStore.parseCredentials(hex)

        XCTAssertEqual(credentials?.claudeAiOauth?.accessToken, "token")
        XCTAssertEqual(credentials?.claudeAiOauth?.subscriptionType, "pro")
    }

    func testCredentialDiagnosticsLabelIsTokenFreeWithSourceRefreshAndExpiredFlags() {
        // The info-level "refresh start" / fallback diagnostics must name the source kind and whether each
        // candidate carries a refresh token + is already expired — never any token value (#738 diagnosis).
        let now = Date(timeIntervalSince1970: 1_000_000) // 1_000_000_000 ms

        let fresh = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "ACCESS_SECRET", refreshToken: "REFRESH_SECRET", expiresAt: 2_000_000_000_000),
            source: .keychainCurrentUser(service: "Claude Code-credentials"),
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(fresh.diagnosticsLabel(now: now), "keychainCurrentUser refresh=yes expired=no")
        XCTAssertFalse(fresh.diagnosticsLabel(now: now).contains("SECRET")) // never leaks token values

        // No refresh token + an already-expired access token: the #738 shape that can never self-heal.
        let lockedOut = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: nil, expiresAt: 1),
            source: .file,
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(lockedOut.diagnosticsLabel(now: now), "file refresh=no expired=yes")

        // Empty refresh token counts as absent; missing expiry is reported as unknown, not assumed fresh.
        let unknownExpiry = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: "", expiresAt: nil),
            source: .keychainLegacy(service: "svc"),
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(unknownExpiry.diagnosticsLabel(now: now), "keychainLegacy refresh=no expired=unknown")
    }

    func testPrefersCurrentUserKeychainCredentialsBeforeFile() {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max"}}"#

        let credentials = store.loadCredentialCandidates().first

        XCTAssertTrue(hashedService.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(credentials?.oauth.accessToken, "keychain-token")
        XCTAssertEqual(credentials?.oauth.subscriptionType, "max")
    }

    func testPrefersKeychainOverFileEvenWhenFileTokenExpiresLater() {
        // #738 regression: the keychain is Claude Code's live source of truth, so it must win even when a
        // stale `~/.claude/.credentials.json` carries a *later* expiry. Ranking purely by expiry (the old
        // #694 behavior) let that stale file outrank the live keychain and starved token refresh. Both
        // candidates stay available so the refresh loop can still fall back keychain → file on auth expiry.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":4070908800000,"subscriptionType":"max"}}"#

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token"])
        XCTAssertEqual(store.loadCredentialCandidates().first?.oauth.accessToken, "keychain-token")
    }

    func testEnvironmentTokenIsInferenceOnly() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        let credentials = store.loadCredentialCandidates().first

        XCTAssertEqual(credentials?.oauth.accessToken, "env-token")
        XCTAssertEqual(store.liveUsageAvailability(credentials!), .inferenceOnlyToken)
    }

    func testEnvTokenDoesNotShadowProfileScopedStoredLogin() {
        // An inference-only CLAUDE_CODE_OAUTH_TOKEN (often just ambiently exported and captured from the
        // login shell) must not shadow a real stored login that CAN read usage. The profile-scoped login
        // is preferred for the live usage call; the env token trails as an inference-only fallback.
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "env-token"])
        // The keychain login (first) can fetch live usage; the env token is the inference-only fallback.
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .available)
        XCTAssertFalse(candidates[0].inferenceOnly)
        XCTAssertEqual(store.liveUsageAvailability(candidates[1]), .inferenceOnlyToken)
    }

    func testEnvTokenIsSoleCandidateWhenStoredLoginCannotReadUsage() {
        // A stored login that itself lacks user:profile can't read usage either, so it is not preferred
        // over the env token; the env token stays the sole inference-only candidate (spend tiles still
        // load) — the headless/no-usable-login behavior is unchanged.
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"inference-login","subscriptionType":"max","scopes":["user:inference"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["env-token"])
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .inferenceOnlyToken)
    }

    func testEnvFallbackBorrowsMetadataFromThePreferredLiveCapableLogin() {
        // When the first stored login is NOT live-capable but a later one is (an inference-only keychain
        // login plus a profile-scoped file login), the env fallback should inherit its display metadata
        // from the credential actually preferred (the file login), not from the keychain login we skipped.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: files,
            keychain: keychain
        )
        keychain.currentUserValues[store.keychainServiceCandidates().first!] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"pro","scopes":["user:inference"]}}"#

        let candidates = store.loadCredentialCandidates()

        // Keychain login (no user:profile) is dropped from the usage-capable set; the file login is
        // preferred and the env token trails.
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["file-token", "env-token"])
        // The env fallback borrows the preferred (file) login's plan, not the skipped keychain login's.
        XCTAssertEqual(candidates[1].oauth.subscriptionType, "max")
    }

    func testLiveUsageAvailabilityReflectsProfileScope() {
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain())
        func state(_ scopes: [String]?, inferenceOnly: Bool = false) -> ClaudeCredentialState {
            ClaudeCredentialState(
                oauth: ClaudeOAuth(accessToken: "token", scopes: scopes),
                source: .keychainCurrentUser(service: "Claude Code-credentials"),
                fullData: nil,
                inferenceOnly: inferenceOnly
            )
        }

        // Older credentials predate the scopes field; an absent/empty list is "unknown, allow".
        XCTAssertEqual(store.liveUsageAvailability(state(nil)), .available)
        XCTAssertEqual(store.liveUsageAvailability(state([])), .available)
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference", "user:profile"])), .available)
        // An inference-only token (e.g. from `claude setup-token`) lacks user:profile → can't read usage.
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"])), .missingProfileScope)
        // An explicit env token is inference-only by design: silent, not a missing-scope notice.
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"], inferenceOnly: true)), .inferenceOnlyToken)
    }

    func testMalformedCustomOAuthURLThrowsInsteadOfCrashing() {
        // A malformed custom OAuth URL is system-boundary input: oauthConfig() must fail loudly
        // rather than force-unwrap a nil URL (which crashes) or silently fall back to prod.
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_CUSTOM_OAUTH_URL": "http://exa mple.com"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        XCTAssertThrowsError(try store.oauthConfig()) { error in
            guard case ClaudeAuthError.invalidOAuthURL = error else {
                return XCTFail("expected ClaudeAuthError.invalidOAuthURL, got \(error)")
            }
        }

        // The forgiving credential-load path only needs the file suffix, so a malformed URL must not
        // break keychain candidate resolution.
        XCTAssertEqual(store.keychainServiceCandidates(), ["Claude Code-custom-oauth-credentials"])
    }

    /// Which credential sources can be attributed to a card's own account, and which can't. This is the
    /// whole basis of `ProviderSnapshot.accountProof` for Claude: a token carries no account claim, so
    /// only a credential that came from *this card's own home* can be tied to the account signed in
    /// there. Desktop's login is one system-wide login shared by every Claude card, and an ambient
    /// `CLAUDE_CODE_OAUTH_TOKEN` is whatever the launch environment exported — attributing either would
    /// be a guess, written into a history that can never be corrected.
    func testOnlyHomeBoundCredentialSourcesCanBeAttributedToAnAccount() {
        XCTAssertTrue(ClaudeCredentialState.Source.file.isBoundToItsHome)
        XCTAssertTrue(ClaudeCredentialState.Source.keychainCurrentUser(service: "svc").isBoundToItsHome)
        XCTAssertTrue(ClaudeCredentialState.Source.keychainLegacy(service: "svc").isBoundToItsHome)
        XCTAssertFalse(ClaudeCredentialState.Source.desktop.isBoundToItsHome)
        XCTAssertFalse(ClaudeCredentialState.Source.environment.isBoundToItsHome)
    }

    /// A scoped card must name the account at *its own* config dir, never the default home's — that
    /// answer belongs to a different card and a different person's usage.
    func testHomeAccountIdentityKeyReadsTheStoresOwnHome() {
        let files = FakeFiles([
            "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"DEFAULT-ACCT"}}"#,
            "/tmp/work/.claude.json": #"{"oauthAccount":{"accountUuid":"WORK-ACCT","organizationUuid":"WORK-ORG"}}"#
        ])

        let scoped = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: FakeKeychain(),
            scope: .configDir(path: "/tmp/work", keychainLiteral: "/tmp/work")
        )
        XCTAssertEqual(scoped.homeAccountIdentityKey(), "work-acct|work-org")

        // And a home with nothing naming an account stays unattributable rather than borrowing one.
        let empty = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: FakeKeychain(),
            scope: .configDir(path: "/tmp/empty", keychainLiteral: "/tmp/empty")
        )
        XCTAssertNil(empty.homeAccountIdentityKey())
    }
}

final class ClaudeUsageMapperTests: XCTestCase {
    func testMapsUsageWindowsExtraUsageAndPlan() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": { "utilization": 5, "resets_at": "2099-01-01T00:00:00.000Z" },
              "extra_usage": { "is_enabled": true, "used_credits": 500, "monthly_limit": 1000 }
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: "claude_max_subscription_20x")
        )

        XCTAssertEqual(mapped.plan, "Max 20x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Sonnet")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.limit, 10)
    }

    func testMapsFableScopedWeeklyLimitFromLimitsArray() throws {
        // Anthropic moved per-model weekly windows into `limits[]` as `weekly_scoped` rows keyed by
        // `scope.model.display_name`; the legacy `seven_day_<model>` top-level keys now come back null.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": null,
              "limits": [
                { "kind": "session", "group": "session", "percent": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
                { "kind": "weekly_all", "group": "weekly", "percent": 20, "resets_at": "2099-01-08T00:00:00.000Z" },
                { "kind": "weekly_scoped", "group": "weekly", "percent": 7,
                  "resets_at": "2099-01-08T00:00:00.000Z",
                  "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } }
              ]
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        XCTAssertEqual(progress(mapped.lines, "Fable")?.used, 7)
        XCTAssertEqual(progress(mapped.lines, "Fable")?.limit, 100)
        XCTAssertEqual(progress(mapped.lines, "Fable")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
    }

    func testUncappedExtraUsageIsAnUnboundedValuesRow() throws {
        // No `monthly_limit`: the spend has no cap, so it's an unbounded `.values` row (which formats
        // through `MetricFormatter`, matching the spend tiles) rather than a baked full-currency `.text`.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"extra_usage":{"is_enabled":true,"used_credits":123456}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        guard case .values(_, let values, _, _, _, _)? = mapped.lines.first(where: { $0.label == "Extra usage spent" }) else {
            return XCTFail("Expected an Extra usage spent .values line")
        }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.kind, .dollars)
        XCTAssertEqual(try XCTUnwrap(values.first?.number), 1234.56, accuracy: 0.0001)
        XCTAssertNil(progress(mapped.lines, "Extra usage spent"))
    }

    func testMapsResetsAtFromMicrosecondTimestampWithoutTimezone() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":"2099-06-01T12:00:00.123456"}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(SuperUsageISO8601.string(from: resetsAt), "2099-06-01T12:00:00.123Z")
    }

    func testMapsResetsAtFromUnixEpochNumber() throws {
        let epochSeconds = 2_099_010_100.0
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":2099010100}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, epochSeconds, accuracy: 1)
    }

    func testRateLimitRetryAfterBadge() {
        let mapped = ClaudeUsageMapper.rateLimitedUsage(
            credentials: ClaudeOAuth(subscriptionType: "pro"),
            retryAfterSeconds: 600
        )

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(badge(mapped.lines, "Status"), "Rate limited, retry in ~10m")
        XCTAssertEqual(text(mapped.lines, "Note"), "Live usage rate limited - retry in ~10m")
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }
}

@MainActor
final class ClaudeProviderTests: XCTestCase {
    func testRefreshFetchesLiveUsageAndScansConfigDirLogs() async throws {
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        // The spend tiles come from the scanner reading `CLAUDE_CONFIG_DIR/projects/**/*.jsonl` —
        // the fixture line carries costUSD so the tile is a carried (not computed) dollar figure.
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertTrue(httpClient.requests.contains { $0.url.absoluteString == "https://api.anthropic.com/api/oauth/usage" })
    }

    func testInferenceOnlyScopeSurfacesReloginWarningAndSkipsUsageCallButKeepsSpendTiles() async throws {
        // A credential that authenticates for inference but lacks the `user:profile` scope (e.g. a
        // `claude setup-token` token) can't read the usage endpoint. The provider must NOT silently leave
        // Session/Weekly blank: it surfaces a soft provider warning (the header's amber triangle, like
        // Z.ai's "no coding plan" notice) telling the user to re-login, skips the usage HTTP call, and
        // still loads the local log-scanned spend tiles.
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // A soft provider warning explains the missing scope — not a hard error badge, and the live-usage
        // meters stay blank (no "Session" line) rather than silently loading nothing.
        XCTAssertEqual(snapshot.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertNil(snapshot.line(label: "Session"))
        // The usage endpoint was never called — that's the whole point of the scope gate.
        XCTAssertFalse(httpClient.requests.contains { $0.url.absoluteString.hasSuffix("/api/oauth/usage") })
        // Local spend tiles are unaffected and still load.
        XCTAssertNotNil(values(snapshot.lines, "Today"))
        XCTAssertEqual(snapshot.plan, "Max 5x")
    }

    func testLiveClaudeUsageReportsResetFields() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUPERUSAGE_LIVE_CLAUDE"] == "1")

        let store = ClaudeAuthStore()
        guard let state = store.loadCredentialCandidates().first else {
            throw XCTSkip("No Claude credentials on this machine")
        }

        let response = try await ClaudeUsageClient().fetchUsage(
            accessToken: state.oauth.accessToken ?? "",
            config: store.oauthConfig()
        )
        XCTAssertTrue((200..<300).contains(response.statusCode))
        let resetHeaders = response.headers.filter { $0.key.localizedCaseInsensitiveContains("reset") }
        print("LIVE response reset headers:", resetHeaders)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        for key in ["five_hour", "seven_day", "seven_day_sonnet"] {
            guard let window = body[key] as? [String: Any] else { continue }
            print("LIVE \(key)=", window)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: state.oauth
        )
        for label in ["Session", "Weekly", "Sonnet"] {
            let resetsAt = Self.progress(mapped.lines, label)?.resetsAt
            print("LIVE mapped \(label) resetsAt=", resetsAt as Any)
        }
    }

    func testRetriesOnceAfter401AndPersistsRefreshedCredentials() async {
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-token") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"fresh-token","refresh_token":"refresh-2","expires_in":3600}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        let usageCalls = httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
        XCTAssertEqual(usageCalls.count, 2)
        let saved = files.files["/tmp/claude/.credentials.json"] ?? ""
        XCTAssertTrue(saved.contains("fresh-token"))
        XCTAssertTrue(saved.contains("refresh-2"))
    }

    func testFallsBackToFileWhenKeychainTokenIsLockedOut() async {
        // #687: a stale/locked-out token sits in the keychain (its refresh token is server-revoked →
        // invalid_grant → "session expired") while a fresh external `claude` re-login wrote a working
        // token to the file. The refresh must fall through to the file source and recover instead of
        // surfacing the stale keychain error until the app is restarted.
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"fresh-access","refreshToken":"fresh-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        // The keychain is always probed first (it's the source of truth), so this exercises the
        // auth-failure fallback: the stale keychain token's refresh is revoked, and recovery comes from
        // falling through to the fresh file token — not from any expiry-based reordering.
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-access") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            // Refresh endpoint: only the stale candidate reaches here, and its refresh token is revoked.
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // Recovered from the file source: plan + usage reflect the fresh token, with no error badge.
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 42)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testSurfacesAuthErrorWhenAllCredentialSourcesAreExpired() async {
        // The fallback must not mask a genuine all-sources-expired state: when both keychain and file
        // tokens are revoked, the refresh fails loudly with the auth error rather than silently
        // recovering or dropping it.
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-stale","refreshToken":"file-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-stale","refreshToken":"keychain-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        // Every usage call 401s and every refresh is revoked → both sources are dead.
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.sessionExpired.localizedDescription)
    }

    func testNoCredentialsReportsNotLoggedIn() async {
        func makeProvider(files: FakeFiles) -> ClaudeProvider {
            ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(),
                    files: files,
                    keychain: FakeKeychain()
                ),
                usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                pricing: { TestPricing.bundled }
            )
        }

        let noneAtAll = makeProvider(files: FakeFiles())
        let plainSnapshot = await noneAtAll.refresh()
        XCTAssertEqual(badge(plainSnapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)

        // A stored-but-blank CLI token (whitespace accessToken survives the store's isEmpty check but is
        // dropped by the provider's trim filter) is still unusable.
        let corruptCLI = makeProvider(files: FakeFiles([
            "~/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"   "}}"#
        ]))
        let corruptSnapshot = await corruptCLI.refresh()
        XCTAssertEqual(badge(corruptSnapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)
    }

    func testRateLimitedResponseMapsToRetryBadgeNotError() async {
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "600"],
            body: Data()
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
        // The badge/note lines only render when enabled in the layout, so the state must also reach the
        // provider header warning (amber triangle) — without it the default dashboard is silently blank.
        XCTAssertEqual(
            snapshot.warning,
            "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse. Retrying in ~10m."
        )
    }

    func testRateLimitServesLastGoodUsageThenBacksOff() async {
        // Tier 2: once a live fetch succeeds, a subsequent 429 keeps showing the cached bars (with a
        // staleness note) instead of a bare badge, and the cooldown then skips the live call entirely so
        // a constantly-limited endpoint isn't hammered. Mirrors the legacy plugin's cache + 429 backoff.
        let t0 = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let clock = TestClock(t0)
        let usageCalls = CallCounter()
        let httpClient = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            }
            if usageCalls.next() == 1 {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )

        // 1) Live fetch succeeds and is cached; no warning rides along.
        let first = await provider.refresh()
        XCTAssertEqual(Self.progress(first.lines, "Session")?.used, 25)
        XCTAssertNil(first.warning)
        // The live reading is stamped with when it was read, exactly as the re-serve below will be.
        // These two must be the *same* instant or the first re-serve doesn't collide with the row this
        // pass wrote — in production `refreshedAt` is taken later than the read (after the pricing and
        // log scans), so leaving a fresh reading unstamped would put the two minutes apart.
        XCTAssertEqual(first.quotaObservedAt, t0)
        XCTAssertEqual(first.quotaReadAt, t0)

        // 2) 429: still shows the cached Session bar plus the staleness note, not a bare "Status" badge —
        // and the header warning flags the rate-limited state even when the note line isn't in the layout.
        let second = await provider.refresh()
        XCTAssertEqual(Self.progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))
        XCTAssertEqual(second.warning?.hasPrefix("Updates blocked by Anthropic"), true)

        // 3) Within the cooldown the live call is skipped entirely; the cached bar is still shown and the
        // warning persists.
        clock.set(t0.addingTimeInterval(60))
        let third = await provider.refresh()
        XCTAssertEqual(Self.progress(third.lines, "Session")?.used, 25)
        XCTAssertEqual(third.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        XCTAssertEqual(httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }.count, 2)
        // 4) The re-served bars carry the time they were actually read, not the time they were re-served.
        // Without this the cooldown — which this endpoint enters routinely — mints a fresh history point
        // every refresh interval for a window nobody measured, drawing a flat line through it. Stamped
        // with the real reading time, the re-serve collides with the row already on record and the
        // untouched stretch shows up as the gap it is.
        XCTAssertEqual(second.quotaObservedAt, t0)
        XCTAssertEqual(third.quotaObservedAt, t0)
        XCTAssertEqual(third.quotaReadAt, t0)
        XCTAssertEqual(third.refreshedAt, t0.addingTimeInterval(60))
        // All three passes therefore claim the same reading instant, which is what makes the cooldown
        // one row in history rather than one row per refresh.
        XCTAssertEqual(Set([first, second, third].map(\.quotaReadAt)), [t0])
    }

    func testRefreshSurfacesRequestFailureForNonOAuthRefreshErrorBody() async {
        // The usage call 401s (forcing a refresh); the refresh endpoint then returns a non-OAuth 400
        // (an HTML proxy/WAF page). The snapshot must report a request failure, NOT "token expired" —
        // a transport/infra error the user can't fix by re-logging in.
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>Bad Gateway</html>".utf8))
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ProviderUsageErrorText.requestFailed(statusCode: 400))
        XCTAssertNotEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    /// A Claude OAuth token names no account, so what ties a snapshot to one is the home its credential
    /// came from — this card reads only its own. Quota history compares this against the account the app
    /// launched with before it will write an append-only row, so it must be spelled exactly the way
    /// `DefaultAccountObserver` spells it, org UUID and all (one human's personal Max org and company
    /// Team org are different usage pools under one account UUID).
    func testSnapshotIsStampedWithTheAccountItsOwnHomeIsSignedInTo() async {
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#,
                    "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"ORG-9","emailAddress":"a@example.com"}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            ))),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.accountProof, "acct-1|org-9")
    }

    /// A home that names no account can't attribute the reading that came out of it. History has to drop
    /// the batch rather than file it under whoever the app launched with — a gap can be filled in later,
    /// two accounts on one append-only line cannot be separated ever.
    func testSnapshotFromAHomeThatNamesNoAccountCarriesNoProof() async {
        let now = SuperUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            ))),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.accountProof)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private static func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

/// A monotonic call counter for stateful `RoutingHTTPClient` handlers (e.g. "succeed once, then 429").
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// A mutable clock so a test can advance `now` between refreshes to exercise time-based gates.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
