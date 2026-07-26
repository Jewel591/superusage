import SwiftUI

/// The callbacks the peek panel hands back to `DynamicIslandController`. Passing them in keeps the view
/// free of any window knowledge — it reports what the pointer did and what the user clicked, and the
/// controller decides what that means for the panel.
struct DynamicIslandActions {
    var pointerOverChanged: (Bool) -> Void = { _ in }
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    var openCustomize: () -> Void = {}
}

/// The Top Peek panel's content: a compact pill that widens into a full readout when the pointer moves
/// onto it.
///
/// The panel has no window chrome of its own (its host is a borderless, clear `NSPanel`), so the surface
/// is drawn here. It is a floating overlay above whatever the user is working in — a HUD, not a document
/// surface — so it takes a standard material rather than the dashboard's opaque tray, which would read
/// as a slab dropped on the screen.
struct DynamicIslandView: View {
    @Environment(AppContainer.self) private var container
    let presentation: DynamicIslandPresentation
    let actions: DynamicIslandActions

    /// Matches the dashboard popover, so the expanded readout and the popover it links to line up.
    static let expandedWidth: CGFloat = 320
    private static let cornerRadius: CGFloat = 14

    var body: some View {
        content
            // The display's budget, applied before `fixedSize` so the ideal height is clamped rather
            // than merely cropped by the window. The expanded readout puts a scroll view in the slack,
            // which is what absorbs this on a screen too short for every starred metric.
            .frame(maxHeight: presentation.maxHeight)
            .background {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
            }
            .fixedSize()
            // The one place the pointer's presence on the panel is reported. The controller pairs it with
            // its screen-wide monitor: the monitor sees the pointer everywhere *except* over our own
            // window, and this sees exactly that gap.
            .onHover { actions.pointerOverChanged($0) }
    }

    @ViewBuilder
    private var content: some View {
        // Hide From Screen Share covers this panel exactly like the menu-bar strip: a floating overlay
        // full of token counts is the last thing that should survive a "hide my usage" toggle. Saying so
        // beats silently refusing to open, which would just read as the feature being broken.
        if container.privacy.concealUsage {
            notice("Usage hidden while sharing", symbol: "eye.slash")
        } else if islandContent.isAwaitingData {
            awaitingDataState
        } else if islandContent.isEmpty {
            emptyState
        } else if presentation.phase == .expanded {
            DynamicIslandExpandedView(content: islandContent, actions: actions)
                .frame(width: Self.expandedWidth)
        } else {
            compact
        }
    }

    /// Live starred metrics, resolved the same way the menu-bar strip resolves them.
    private var islandContent: DynamicIslandContent {
        DynamicIslandContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) },
            title: { container.displayName(for: $0) }
        )
    }

    // MARK: - Compact

    /// The glanceable state: one segment per starred provider, its mark followed by that provider's
    /// values. No labels here — at this size the numbers are the message, and the expanded state a few
    /// points below carries the names, meters, and reset times.
    private var compact: some View {
        HStack(spacing: 12) {
            ForEach(islandContent.groups) { group in
                HStack(spacing: 5) {
                    ProviderIcon(source: group.icon, inset: 0.05)
                        .frame(width: 12, height: 12)
                    ForEach(Array(group.metrics.enumerated()), id: \.element.id) { index, metric in
                        if index > 0 {
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(metric.data.menuBarValue)
                            .monospacedDigit()
                            .foregroundStyle(tint(for: metric.data))
                    }
                }
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(islandContent.accessibilityText)
    }

    /// Compact values carry their pace verdict in their color, so a metric heading for trouble is
    /// visible without expanding anything. A healthy metric stays plain — coloring everything would
    /// make the warning colors mean nothing.
    private func tint(for data: WidgetData) -> AnyShapeStyle {
        switch data.meterState().severity {
        case .warning: return Theme.meterFill(.warning)
        case .critical: return Theme.meterFill(.critical)
        case .normal, nil: return AnyShapeStyle(.primary)
        }
    }

    // MARK: - Placeholder states

    /// Nothing starred yet: point at the screen that fixes it rather than showing an empty pill that
    /// looks broken.
    private var emptyState: some View {
        Button { actions.openCustomize() } label: {
            notice("Star metrics to see them here", symbol: "star")
        }
        .buttonStyle(.plain)
    }

    /// Starred, but nothing has data — a first fetch still in flight, or every starred provider failing
    /// at once. Sending these to Customize would be a lie: there is nothing to star that isn't starred
    /// already. A failure opens the popover instead, which is where the reason lives.
    @ViewBuilder
    private var awaitingDataState: some View {
        if !container.dataStore.refreshingProviderIDs.isEmpty {
            notice("Updating…", symbol: "arrow.clockwise")
        } else if !container.dataStore.providerErrors.isEmpty {
            Button { actions.openDashboard() } label: {
                notice("Couldn't refresh — open for details", symbol: "exclamationmark.triangle")
            }
            .buttonStyle(.plain)
        } else {
            notice("No usage data yet", symbol: "clock")
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
