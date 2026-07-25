import CryptoKit
import Foundation

@MainActor
final class ClaudeProvider: ProviderRuntime {
    /// The default card's identity. Extra account cards inject their own `Provider` with an
    /// `@`-suffixed id and an account-derived display name; everything else about the runtime is
    /// identical.
    static func makeProvider(id: String = "claude", displayName: String = "Claude") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    let provider: Provider

    let authStore: ClaudeAuthStore
    let usageClient: ClaudeUsageClient
    let logUsageScanner: ClaudeLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// Last successful live-usage result and a rate-limit cooldown, carried across refreshes (the provider
    /// is a long-lived singleton). `/api/oauth/usage` rate-limits aggressively, so on a 429 we serve the
    /// last-good bars with a staleness note instead of blanking the dashboard, and skip the live call
    /// entirely until the cooldown expires so we don't keep hammering an endpoint that's already limiting
    /// us. Mirrors the legacy plugin's `cachedUsageData` + `rateLimitedUntilMs`.
    private var cachedCredentialFingerprint: Data?
    private var lastGoodUsage: ClaudeMappedUsage?
    /// When `lastGoodUsage` was actually fetched, so a re-serve during the cooldown can say so rather
    /// than pass a stale reading off as a new observation.
    private var lastGoodUsageAt: Date?
    private var rateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    init(
        provider: Provider = ClaudeProvider.makeProvider(),
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        logUsageScanner: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent"),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Claude usage history (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Scoped cards answer from footprints only (file existence / keychain attributes) so the
        // every-launch seeding probe can never raise a keychain dialog for an account the user
        // hasn't granted yet. The secret read happens on the first refresh.
        if authStore.scope != .standard {
            return await loadOffMainActor { [authStore] in authStore.hasCredentialFootprint() }
        }
        // Never trigger another app's Keychain prompt during first-run detection. Encrypted Desktop
        // material still counts as a local login; the first manual refresh requests access if needed.
        let load = await loadOffMainActor { [authStore] in authStore.loadCredentialSet() }
        if load.candidates.contains(where: \.hasUsableAccessToken) { return true }
        return load.desktopStatus == .permissionRequired || load.desktopStatus == .stale
    }

    func refresh() async -> ProviderSnapshot {
        await refresh(
            credentialReloadsRemaining: 1,
            forceDesktopFallback: false,
            previousFallbackError: nil
        )
    }

    /// Claude Code can replace a login while a request is in flight. Reload once when that happens so
    /// the older account cannot reach the dashboard or cache; bound the retry for a changing source.
    private func refresh(
        credentialReloadsRemaining: Int,
        forceDesktopFallback: Bool,
        previousFallbackError: ClaudeAuthError?
    ) async -> ProviderSnapshot {
        let allowDesktopInteraction = ProviderRefreshContext.isManual
        // Both disk reads ride one hop off the main actor. The home's account is read here, next to the
        // credentials it belongs with, rather than after the fetch: read later it would describe a home
        // that could have been re-logged-in during the request, and `probe` would attribute this
        // reading to whoever signed in while it was in flight.
        let (credentialLoad, homeAccount) = await loadOffMainActor { [authStore] in
            (
                authStore.loadCredentialSet(
                    allowDesktopInteraction: allowDesktopInteraction,
                    forceDesktopFallback: forceDesktopFallback
                ),
                authStore.homeAccountIdentityKey()
            )
        }
        let candidates = credentialLoad.candidates.filter {
            $0.hasUsableAccessToken && (!forceDesktopFallback || $0.source == .desktop)
        }
        if forceDesktopFallback {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale, .invalid, .notFound:
                if let previousFallbackError {
                    return ProviderSnapshot.error(provider: provider, error: previousFallbackError)
                }
            case .notChecked, .available:
                break
            }
        }
        let hasLiveUsageCandidate = candidates.contains {
            authStore.liveUsageAvailability($0) == .available
        }
        let desktopFallbackWarning: String? = if !hasLiveUsageCandidate {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                ClaudeAuthError.desktopPermissionRequired.localizedDescription
            case .stale:
                ClaudeAuthError.desktopTokenExpired.localizedDescription
            case .invalid:
                ClaudeAuthError.desktopCredentialsUnavailable.localizedDescription
            case .notChecked, .notFound, .available:
                nil
            }
        } else {
            nil
        }
        guard !candidates.isEmpty else {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopTokenExpired)
            case .invalid:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopCredentialsUnavailable)
            case .notChecked, .notFound, .available:
                break
            }
            AppLog.info(LogTag.auth("claude"), "no access token, not logged in")
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.notLoggedIn)
        }

        // Per-source diagnostics at info level (token-free: source kind + refresh-token-present + expired
        // booleans) so a "token expired" report is diagnosable from a default log without a debug build —
        // e.g. all sources showing `refresh=no` explains why an expiry can never self-heal (issue #738).
        let sources = candidates.map { $0.diagnosticsLabel(now: now()) }.joined(separator: ", ")
        AppLog.info(LogTag.plugin("claude"), "refresh start (\(candidates.count) source\(candidates.count == 1 ? "" : "s"): \(sources))")
        let start = Date()
        // Probe each credential source in keychain-before-file order. An auth-expiry failure on one source (a
        // stale/locked-out token that an external `claude` re-login replaced in another source) falls
        // through to the next rather than failing the whole refresh; any non-auth error (rate limit,
        // request/transport failure) surfaces immediately so a real outage is never masked as a retry.
        var lastFallbackError: ClaudeAuthError?
        var credentialGeneration = ClaudeCredentialGeneration(credentialLoad.attributionCandidates)
        // Logins this refresh has *ruled out* — each one the endpoint rejected as unauthenticated. They
        // stop competing for the attribution of whatever succeeds afterwards; see `attributionIsAmbiguous`.
        var eliminatedLogins: Set<Data> = []
        for state in candidates {
            // The environment token cannot read subscription usage. If a CLI login was rejected, try
            // Desktop before this spend-only fallback can turn the refresh into a false success.
            if !forceDesktopFallback,
               lastFallbackError != nil,
               credentialLoad.desktopStatus == .notChecked,
               authStore.liveUsageAvailability(state) == .inferenceOnlyToken
            {
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining,
                    forceDesktopFallback: true,
                    previousFallbackError: lastFallbackError
                )
            }
            do {
                let snapshot = try await probe(
                    state: state,
                    credentialGeneration: &credentialGeneration,
                    fallbackWarning: desktopFallbackWarning,
                    homeAccount: homeAccount,
                    attributionIsAmbiguous: Self.attributionIsAmbiguous(
                        winner: state,
                        among: credentialLoad.attributionCandidates,
                        eliminated: eliminatedLogins,
                        isBoundToThisHome: { [authStore] in authStore.isBoundToThisHome($0) }
                    )
                )
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch ClaudeAuthError.credentialsChanged where credentialReloadsRemaining > 0 {
                AppLog.info(LogTag.auth("claude"), "credential source changed during refresh; reloading current login")
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining - 1,
                    forceDesktopFallback: forceDesktopFallback,
                    previousFallbackError: previousFallbackError
                )
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                AppLog.warn(LogTag.auth("claude"), "\(state.source.label) failed (\(error)); falling back to next source if any")
                lastFallbackError = error
                eliminatedLogins.insert(Self.loginFingerprint(state.oauth))
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        if !forceDesktopFallback,
           lastFallbackError != nil,
           credentialLoad.desktopStatus == .notChecked
        {
            AppLog.info(LogTag.auth("claude"), "stored Claude login failed; trying Claude Desktop")
            return await refresh(
                credentialReloadsRemaining: credentialReloadsRemaining,
                forceDesktopFallback: true,
                previousFallbackError: lastFallbackError
            )
        }
        return ProviderSnapshot.error(
            provider: provider,
            error: lastFallbackError ?? ClaudeAuthError.notLoggedIn
        )
    }

    /// Whether more than one distinct login in this card's own home could have produced these numbers.
    ///
    /// This is the hole that "the credential came from my home" leaves open, and it is a **supported**
    /// state rather than a corrupt one: the loader deliberately reads keychain *and* file and prefers the
    /// keychain, because a re-login can land in either one and leave the other behind (see
    /// `orderedStoredCandidates`, issue #687). So a home can hold a live login for account B in the file
    /// and a leftover — still-valid — token for account A in the keychain, with `.claude.json` naming B.
    /// The keychain wins, A's numbers come back, and nothing about the home has changed before, during, or
    /// after the request. Both the identity re-read and `credentialsChanged` see a perfectly stable home,
    /// because it *is* stable; what's unknown is which of its two logins belongs to the account it names.
    ///
    /// So attribution is refused whenever a second bound login is still in the running. A login the
    /// endpoint has already rejected this refresh is not — that is the ordinary "stale source, fresh
    /// re-login elsewhere" recovery, and once the stale one is out, the survivor is the home's only
    /// working login. The cost is samples lost while two live logins sit in one home; the alternative is
    /// one account's usage welded into another's series, which no later refresh can take back.
    ///
    /// Logins are compared by refresh token (falling back to the access token), so the same login copied
    /// into both stores — or rotated in one of them — is correctly seen as one login, not two.
    ///
    /// `among` must be `ClaudeCredentialLoad.attributionCandidates` — every login the home holds — and
    /// never the probe order: a login that can't *read usage* (no `user:profile` scope) is dropped from
    /// the probe order once an ambient token exists, yet it can still be the account the home names, and
    /// a competitor invisible to this check is exactly a competitor that gets ignored.
    static func attributionIsAmbiguous(
        winner: ClaudeCredentialState,
        among candidates: [ClaudeCredentialState],
        eliminated: Set<Data>,
        isBoundToThisHome: (ClaudeCredentialState.Source) -> Bool
    ) -> Bool {
        // An unbound winner (Desktop, ambient token) has no proof to lose — `provenAccount` already
        // refuses it, and the other candidates say nothing about a credential that isn't from this home.
        guard isBoundToThisHome(winner.source) else { return false }
        let winnerLogin = loginFingerprint(winner.oauth)
        return candidates.contains { other in
            guard isBoundToThisHome(other.source) else { return false }
            let login = loginFingerprint(other.oauth)
            return login != winnerLogin && !eliminated.contains(login)
        }
    }

    /// Identifies a *login* rather than a credential snapshot: the refresh token survives access-token
    /// rotation, so one login saved in two places (or refreshed in one of them) still reads as one login.
    static func loginFingerprint(_ oauth: ClaudeOAuth) -> Data {
        let material = oauth.refreshToken?.nilIfEmpty ?? oauth.accessToken ?? ""
        return Data(SHA256.hash(data: Data(material.utf8)))
    }

    private func probe(
        state initialState: ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        fallbackWarning: String?,
        homeAccount: String?,
        attributionIsAmbiguous: Bool
    ) async throws -> ProviderSnapshot {
        var state = initialState
        var mapped = ClaudeMappedUsage(
            plan: ClaudeUsageMapper.formatPlan(
                subscriptionType: state.oauth.subscriptionType,
                rateLimitTier: state.oauth.rateLimitTier
            ),
            lines: []
        )

        var warning: String?
        switch authStore.liveUsageAvailability(state) {
        case .available:
            mapped = try await fetchLiveUsage(
                state: &state,
                credentialGeneration: &credentialGeneration
            )
            // A rate-limited fetch rides its "Updates blocked by Anthropic" notice on the mapped usage so
            // it reaches the header triangle even when the badge/note lines aren't in the user's layout.
            warning = mapped.warning
        case .missingProfileScope:
            // The login authenticates for inference but lacks the `user:profile` scope the usage endpoint
            // needs (typically a `claude setup-token` token). Don't leave the session/weekly bars silently
            // blank — log it for diagnosis and surface a provider header warning (the amber triangle, like
            // Z.ai's "no coding plan" notice) telling the user a re-login restores them. The local-log
            // spend tiles below are unaffected and still load.
            AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: credential lacks the user:profile scope (inference-only token); re-login with `claude` to restore session/weekly limits")
            warning = ClaudeUsageMapper.missingProfileScopeWarning
        case .inferenceOnlyToken:
            // An explicit CLAUDE_CODE_OAUTH_TOKEN is inference-only by design; nothing to fetch and nothing
            // to nag about — the spend tiles still load below.
            break
        }
        if let fallbackWarning {
            warning = fallbackWarning
        }

        // Local spend tiles, scanned natively from Claude Code's session logs and priced through the
        // shared pricing store, merged with Claude usage that happened inside pi (attributed back here).
        // Both scans run on their scanner actors, off the main actor.
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan = await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
        var usageHistory: ProviderUsageHistory?
        // Cancellation can land between the native and pi scans. Treat the pair as one unit so a
        // partial result cannot replace the last-good combined history in WidgetDataStore.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Claude usage history (estimated)"
                : "From your Claude usage history and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        let accountProof = attributionIsAmbiguous
            ? nil
            : await provenAccount(for: state.source, pinnedTo: homeAccount)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning,
            quotaObservedAt: mapped.observedAt,
            accountProof: accountProof
        )
    }

    /// Whose account this reading may be recorded under — `nil` meaning "unprovable, don't record".
    ///
    /// A Claude OAuth token names no account (unlike Codex's, which carries one), and neither does the
    /// usage response, so the only thing that can tie these numbers to an account is the *home* the
    /// winning credential came out of: this card reads one home, and that home's `.claude.json` names
    /// who is signed in there. Two conditions, both required:
    ///
    /// 1. The credential provably came from this card's own home — `isBoundToThisHome`, which excludes
    ///    Claude Desktop's system-wide login, an ambient `CLAUDE_CODE_OAUTH_TOKEN`, and the bare-default
    ///    keychain item a `CLAUDE_CONFIG_DIR` store falls back to — and it was the home's only login
    ///    still in the running (`attributionIsAmbiguous`, checked by the caller).
    /// 2. The home still names the same account **after** the fetch as it did before it. The identity is
    ///    read up front, next to the credentials (a later-only read would describe whoever signed in
    ///    while the request was in flight); re-reading it here pins the pair across the whole request, so
    ///    a re-login landing mid-refresh drops the reading instead of filing it under the new account.
    ///    This is the identity-side twin of the `credentialsChanged` check `fetchLiveUsage` already runs.
    private func provenAccount(
        for source: ClaudeCredentialState.Source,
        pinnedTo homeAccount: String?
    ) async -> String? {
        guard let homeAccount, authStore.isBoundToThisHome(source) else { return nil }
        let after = await loadOffMainActor { [authStore] in authStore.homeAccountIdentityKey() }
        guard after == homeAccount else {
            AppLog.warn(
                LogTag.auth("claude"),
                "this home changed account while the refresh was in flight; reading not attributed"
            )
            return nil
        }
        return homeAccount
    }

    private func fetchLiveUsage(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration
    ) async throws -> ClaudeMappedUsage {
        var expectedGeneration = credentialGeneration
        defer { credentialGeneration = expectedGeneration }
        activateLiveUsageCache(for: state.oauth)

        // Inside an active rate-limit cooldown, skip the live call and serve the last-good usage so a
        // constantly-limited endpoint doesn't blank the dashboard (and we don't pile on more 429s).
        if let until = rateLimitedUntil, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: state.oauth, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        if authStore.needsRefresh(state.oauth),
           let refreshToken = state.oauth.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: expectedGeneration
            )
            state.oauth.accessToken = refreshed.accessToken
            if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(state) }
        }

        var working = state
        defer { state = working }
        let response = try await ProviderAuthRetry.fetch(
            token: working.oauth.accessToken ?? "",
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, config: self.authStore.oauthConfig()) },
            refreshAccessToken: {
                if working.source == .desktop {
                    throw ClaudeAuthError.desktopTokenExpired
                }
                guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                    throw ClaudeAuthError.tokenExpired
                }
                let refreshed = try await self.refreshAccessToken(
                    state: &working,
                    refreshToken: refreshToken,
                    expectedGeneration: expectedGeneration
                )
                if refreshed.persisted {
                    expectedGeneration = expectedGeneration.replacing(working)
                }
                return refreshed.accessToken
            },
            connectionFailed: ClaudeUsageError.connectionFailed,
            authExpired: ClaudeAuthError.tokenExpired
        )

        let forceDesktopGeneration = working.source == .desktop
        let currentGeneration = await loadOffMainActor { [authStore] in
            authStore.credentialGeneration(forceDesktopFallback: forceDesktopGeneration)
        }
        guard currentGeneration == expectedGeneration else { throw ClaudeAuthError.credentialsChanged }

        // 429 can come back from either attempt; the helper hands both through unchanged. Start a cooldown
        // (respecting Retry-After) and serve the last-good usage rather than a bare badge.
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown)))
            AppLog.info(LogTag.plugin("claude"), "rate-limited (serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: working.oauth, retryAfterSeconds: retryAfterSeconds)
        }

        var mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: now())
        let observedAt = now()
        // Stamp the fresh reading with the same instant the cooldown re-serve will stamp it with. One
        // `now()` for both, and specifically *this* one: `probe` takes its own `now()` for `refreshedAt`
        // after the pricing and log scans, so leaving this reading unstamped would date it minutes later
        // than the re-serve dates it. The first re-serve would then miss the row it is meant to collide
        // with and mint a second point for a reading taken once. See `ProviderSnapshot.quotaObservedAt`.
        mapped.observedAt = observedAt
        lastGoodUsage = mapped
        lastGoodUsageAt = observedAt
        rateLimitedUntil = nil
        return mapped
    }

    /// Last-good usage with an appended staleness note when we have it; otherwise the plain rate-limited
    /// badge (no successful fetch yet this run). `lastGoodUsage` only ever holds a clean `mapUsageResponse`
    /// result (never a rate-limited snapshot), so the note is never duplicated and no stale spend tiles
    /// ride along — `probe` appends those fresh after this returns.
    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        // These bars are the previous reading, not a new one. Carrying when they were actually taken is
        // what keeps quota history from recording a cooldown as a flat, measured stretch.
        mapped.observedAt = lastGoodUsageAt
        return mapped
    }

    /// Cache state belongs to the complete access + refresh credential pair. A login change therefore
    /// clears both last-good usage and cooldown, even when the two accounts share an access token.
    private func activateLiveUsageCache(for credentials: ClaudeOAuth) {
        let fingerprint = Self.credentialFingerprint(credentials)
        guard cachedCredentialFingerprint != fingerprint else { return }
        cachedCredentialFingerprint = fingerprint
        lastGoodUsage = nil
        lastGoodUsageAt = nil
        rateLimitedUntil = nil
    }

    private static func credentialFingerprint(_ credentials: ClaudeOAuth) -> Data {
        let access = Data((credentials.accessToken ?? "").utf8)
        let refresh = Data((credentials.refreshToken ?? "").utf8)
        var pair = Data(SHA256.hash(data: access))
        pair.append(contentsOf: SHA256.hash(data: refresh))
        return Data(SHA256.hash(data: pair))
    }

    private struct RefreshedAccess {
        var accessToken: String
        var persisted: Bool
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: ClaudeCredentialGeneration
    ) async throws -> RefreshedAccess {
        AppLog.info(LogTag.auth("claude"), "token refresh attempt")
        let response = try await usageClient.refreshToken(refreshToken, config: authStore.oauthConfig())
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            let errorCode = body?["error"] as? String ?? body?["error_description"] as? String
            if errorCode == "invalid_grant" {
                AppLog.warn(LogTag.auth("claude"), "session expired (invalid_grant)")
                throw ClaudeAuthError.sessionExpired
            }
            // A 400/401 without a recognized OAuth error code isn't necessarily an expired token — it
            // can be an HTML proxy/WAF page or a gateway error. Surface the HTTP status rather than
            // telling the user to re-login (which can't fix a transport/infra failure).
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        // NEVER log decoded.accessToken / refreshToken — only the fact that a rotation happened.
        let decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        let previousOAuth = state.oauth
        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = decoded.refreshToken {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        // Fail loudly: a swallowed save leaves the OLD refresh token on disk after a rotation, so the
        // next launch refreshes with a server-invalidated token and the user sees a misleading
        // "session expired". The refreshed token still works for this session, so we log and continue
        // rather than fail the live fetch.
        let persisted: Bool
        do {
            guard try await Task.detached(priority: .utility, operation: { [authStore, state] in
                try authStore.save(state, ifUnchanged: expectedGeneration)
            }).value else {
                throw ClaudeAuthError.credentialsChanged
            }
            persisted = true
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            throw error
        } catch {
            AppLog.error(LogTag.auth("claude"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
            persisted = false
        }
        if cachedCredentialFingerprint == Self.credentialFingerprint(previousOAuth) {
            cachedCredentialFingerprint = Self.credentialFingerprint(state.oauth)
        }
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return RefreshedAccess(accessToken: decoded.accessToken, persisted: persisted)
    }

}
