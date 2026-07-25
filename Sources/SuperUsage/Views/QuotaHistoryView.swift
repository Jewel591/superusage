import SwiftUI

/// The Usage History window: pick a provider and one of its capped metrics, pick a range, and see how
/// the remaining quota moved.
///
/// This lives in its own window rather than in the menu-bar panel because the panel is a narrow glance
/// surface — the dashboard answers "how much is left now", and a trend needs room for an axis, a range
/// switcher, and a readout without crowding any of them.
struct QuotaHistoryView: View {
    @Environment(AppContainer.self) private var container

    @State private var scopes: [QuotaHistoryDisplayScope] = []
    @State private var selectedScopeKey: String?
    @State private var range: QuotaHistoryRange = .day
    @State private var series: QuotaHistorySeries = .empty
    @State private var hasLoadedScopes = false

    /// The window re-reads on this beat so a chart left open keeps growing with each refresh pass,
    /// instead of freezing at whatever was on record when it opened.
    private static let reloadInterval: TimeInterval = RefreshSetting.interval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            // Above `content`, and deliberately outside every one of its branches. Each notice explains
            // why the data below is thinner than expected, and the states that need explaining most are
            // exactly the ones that draw no chart: a card that has never recorded produces no series at
            // all, so it can't be selected, and "No History Yet" would otherwise tell a user to leave the
            // app running for a trend that is never going to arrive.
            notices
            content
        }
        .frame(minWidth: 560, minHeight: 400)
        .task {
            await loadScopes()
            await reloadLoop()
        }
        .task(id: reloadKey) { await loadSeries() }
    }

    /// Changing either of these means the chart is showing the wrong thing until it reloads.
    private var reloadKey: String { "\(selectedScopeKey ?? "")|\(range.rawValue)" }

    private var selectedScope: QuotaHistoryDisplayScope? {
        scopes.first { $0.scopeKey == selectedScopeKey }
    }

    /// One entry in the first picker: a card as seen by one account.
    private struct HistoryCard: Identifiable, Hashable {
        /// `QuotaHistoryDisplayScope.cardKey`.
        let id: String
        let title: String
    }

    /// The cards to offer, in the order their series were last active.
    ///
    /// The account is spelled out **only** when a card holds more than one account's history — which
    /// happens after a sign-out and sign-in at a family's default home, since that card keeps the id
    /// `claude` for life. Naming the account unconditionally would put "Claude — me@example.com" in front
    /// of every single-account user for a distinction they don't have.
    private var cards: [HistoryCard] {
        var order: [String] = []
        var firstScopeByCard: [String: QuotaHistoryDisplayScope] = [:]
        var cardKeysByProvider: [String: Set<String>] = [:]
        for scope in scopes {
            if firstScopeByCard[scope.cardKey] == nil {
                firstScopeByCard[scope.cardKey] = scope
                order.append(scope.cardKey)
            }
            cardKeysByProvider[scope.providerID, default: []].insert(scope.cardKey)
        }
        return order.compactMap { key in
            guard let scope = firstScopeByCard[key] else { return nil }
            let base = container.displayName(for: scope.provider)
            guard (cardKeysByProvider[scope.providerID]?.count ?? 0) > 1 else {
                return HistoryCard(id: key, title: base)
            }
            return HistoryCard(id: key, title: "\(base) — \(accountLabel(for: scope))")
        }
    }

    /// How to name the account behind a series once it has to be named.
    ///
    /// A signed-out account is gone from the registry, so its rows can only be identified by their
    /// digest. Showing a truncated one is not a name, but it does say "this is somebody else" — which is
    /// the whole point of labelling here, and is strictly better than two identical entries.
    private func accountLabel(for scope: QuotaHistoryDisplayScope) -> String {
        guard let digest = scope.accountDigest else { return "unattributed" }
        guard let name = container.accounts.accountLabel(identityDigest: digest) else {
            return "account \(digest.prefix(6))"
        }
        return Self.shortened(name)
    }

    /// The longest account name this picker will render. Past this it truncates.
    private static let accountLabelLimit = 22

    /// Squeezes an account name down to something a picker can hold: prefer the org out of our own
    /// "email (Org Name)" label shape, then cap the length.
    ///
    /// Not cosmetic. The controls row is three fixed-size pickers, so an untruncated
    /// "someone@example.com (Someone's Organization)" widens the first one until the range switcher is
    /// pushed off the window and the chart is clipped — which is exactly what the full label did.
    private static func shortened(_ label: String) -> String {
        var name = label
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            let org = name[name.index(after: open)..<name.index(before: name.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if !org.isEmpty { name = org }
        }
        guard name.count > accountLabelLimit else { return name }
        return name.prefix(accountLabelLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private var metricsForSelectedCard: [QuotaHistoryDisplayScope] {
        guard let cardKey = selectedScope?.cardKey else { return [] }
        return scopes.filter { $0.cardKey == cardKey }
    }

    // MARK: - Chrome

    private var controls: some View {
        HStack(spacing: 10) {
            providerPicker
            metricPicker
            Spacer(minLength: 12)
            rangePicker
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(scopes.isEmpty)
    }

    private var providerPicker: some View {
        Picker("Provider", selection: cardSelection) {
            ForEach(cards) { card in
                Text(card.title).tag(card.id)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Switching card has to move the metric selection too — the previous metric belongs to the old card
    /// and would leave the chart showing a series the pickers no longer describe.
    private var cardSelection: Binding<String> {
        Binding(
            get: { selectedScope?.cardKey ?? cards.first?.id ?? "" },
            set: { cardKey in
                selectedScopeKey = scopes.first { $0.cardKey == cardKey }?.scopeKey
            }
        )
    }

    private var metricPicker: some View {
        Picker("Metric", selection: Binding(
            get: { selectedScopeKey ?? "" },
            set: { selectedScopeKey = $0 }
        )) {
            ForEach(metricsForSelectedCard) { scope in
                Text(scope.metricTitle).tag(scope.scopeKey)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(QuotaHistoryRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // The failure branch comes first, and covers reads as well as opening. A database that can't be
        // read must not fall through to "No History Yet" — telling a user their history is empty when it
        // is actually unreadable invites them to shrug at a real problem.
        if let failure = container.quotaHistory.failure {
            message(
                icon: "exclamationmark.triangle",
                title: "History Unavailable",
                detail: failure
            )
        } else if !hasLoadedScopes {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scopes.isEmpty {
            message(
                icon: "chart.xyaxis.line",
                title: "No History Yet",
                detail: """
                superUsage records a point for every metric with a limit each time it refreshes, \
                about every \(RefreshSetting.defaultMinutes) minutes. Leave it running and the trend \
                fills in.
                """
            )
        } else if series.isEmpty {
            message(
                icon: "clock.badge.questionmark",
                title: "Nothing in This Range",
                detail: "No successful refresh landed in the last \(range.title) for this metric."
            )
        } else {
            chart
        }
    }

    /// Everything the window has to say about data that *isn't* being recorded, or wasn't written.
    ///
    /// Reported per card rather than for the selection, because the cards worth reporting are the ones
    /// the selection can't reach. A card whose account never resolved has no series in the picker, and a
    /// card that stopped recording the day it was installed has none either — keying this off the
    /// selected scope (as it first did) made both of them invisible.
    @ViewBuilder
    private var notices: some View {
        let history = container.quotaHistory
        let gaps = history.recordingGaps
        // A store that won't open already says so in `content`; repeating it as a write failure here
        // would be the same problem twice in two different voices.
        let writeIssue = history.failure == nil ? (history.recordingFailure ?? history.retentionFailure) : nil
        if !gaps.isEmpty || writeIssue != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(gaps) { gap in
                    notice(icon: gap.reason.icon, text: text(for: gap))
                }
                if let writeIssue {
                    notice(
                        icon: "exclamationmark.triangle",
                        text: history.recordingFailure != nil
                            ? "superUsage couldn't save the latest points to the history database (\(writeIssue)). What's already on record still charts normally, and it will try again on the next refresh."
                            : "superUsage couldn't delete points older than its retention window (\(writeIssue)). Nothing is lost — the database is just holding more than it means to, and it will try again later."
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func text(for gap: QuotaHistoryRecordingGap) -> String {
        let name = container.displayName(for: gap.provider)
        switch gap.reason {
        case .unattributable:
            return "\(name) isn't being recorded: superUsage can't tell which account it's signed in as, "
                + "and history is only ever filed under a known account. Signing in with its CLI so the "
                + "login names an account, then reopening superUsage, starts the recording."
        case .mismatched:
            return "\(name)'s refreshes are coming back from a different account than the one superUsage "
                + "started with, so recording is paused and this account's history stays its own. It "
                + "resumes when the original account signs back in — or right away if you quit and "
                + "reopen superUsage."
        }
    }

    private func notice(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuotaHistoryChart(
                series: series,
                kind: series.format.metricKind,
                countSuffix: series.format.countSuffix
            )
            footnote
        }
        .padding(16)
    }

    /// Names the things the chart draws differently from consumption, so a dashed rule or a break in the
    /// line reads as deliberate rather than as a rendering glitch.
    private var footnote: some View {
        HStack(spacing: 14) {
            if !series.resets.isEmpty {
                Label("\(series.resets.count) reset\(series.resets.count == 1 ? "" : "s")", systemImage: "arrow.counterclockwise")
            }
            if !series.gaps.isEmpty {
                Label(
                    "\(series.gaps.count) gap\(series.gaps.count == 1 ? "" : "s") with no successful refresh",
                    systemImage: "wave.3.right"
                )
            }
            Spacer(minLength: 0)
            Text("\(series.points.count) point\(series.points.count == 1 ? "" : "s")")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Loading

    private func loadScopes() async {
        let loaded = await container.quotaHistory.scopes()
        scopes = loaded
        hasLoadedScopes = true
        // Keep the current selection when it survived the reload; otherwise fall back to the series with
        // the most recent activity, which is what the user most likely came to look at.
        if selectedScopeKey == nil || !loaded.contains(where: { $0.scopeKey == selectedScopeKey }) {
            selectedScopeKey = loaded.first?.scopeKey
        }
    }

    /// Reads the series for whatever the pickers currently say, discarding a result that arrives after
    /// the user has moved on.
    ///
    /// Two callers race here: `task(id:)` on every picker change, and the reload loop on its own beat.
    /// Without the key check, a slow 30d read that started before the user switched to 24h can land last
    /// and leave the chart showing 30d under a "24h" selection until the next reload — the picker and
    /// the chart silently disagreeing about what is on screen.
    private func loadSeries() async {
        guard let requestedScopeKey = selectedScopeKey else {
            series = .empty
            return
        }
        let requestedRange = range
        let loaded = await container.quotaHistory.series(scopeKey: requestedScopeKey, range: requestedRange)
        guard requestedScopeKey == selectedScopeKey, requestedRange == range else { return }
        series = loaded
    }

    /// Re-reads on the refresh cadence for as long as the window is open. `task` cancels this when the
    /// view goes away, so a closed window stops touching the database.
    private func reloadLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.reloadInterval))
            guard !Task.isCancelled else { return }
            await loadScopes()
            await loadSeries()
        }
    }
}
