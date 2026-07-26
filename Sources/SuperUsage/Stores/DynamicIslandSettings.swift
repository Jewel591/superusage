import AppKit
import Observation

/// Preferences for the top-edge peek panel, plus the live Reduce Motion flag it yields to.
///
/// The type name follows the feature's working name ("dynamic island"); the user-facing copy says
/// **Top Peek** instead, because "Dynamic Island" is Apple's own name for an iPhone hardware feature
/// and this is neither that nor an imitation of it. Keep the split: issue threads and code talk about
/// the island, Settings and the docs talk about Top Peek.
@MainActor
@Observable
final class DynamicIslandSettings {
    static let key = "dynamicIslandEnabled"

    /// Off by default: this is a second always-armed surface, so it should be a choice the user makes
    /// rather than something a routine update starts doing to their screen edge. The no-op guard avoids
    /// a redundant defaults write (and the firehose `UserDefaults.didChangeNotification` it would emit),
    /// matching `PopoverTransparencyStore`.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.key)
            AppLog.info(.statusItem, "Top Peek \(isEnabled ? "enabled" : "disabled")")
        }
    }

    /// macOS Reduce Motion. The panel's reveal is a slide-and-fade; with this on it appears and
    /// disappears outright. The panel still shows the same information either way — motion is
    /// decoration here, never the signal.
    private(set) var reduceMotion: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessibilityObservation: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.key)
        // Injectable so tests can pin the flag instead of inheriting the test host's system settings.
        self.reduceMotion = reduceMotion
        startObservingAccessibility()
    }

    deinit { accessibilityObservation?.cancel() }

    /// Accessibility display options post to `NSWorkspace`'s OWN notification center (never `.default`).
    /// The notification carries no payload, so we ignore it and re-read the flag on the main actor —
    /// which also sidesteps the non-`Sendable` `Notification` under Swift 6 strict concurrency.
    private func startObservingAccessibility() {
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        accessibilityObservation = Task { [weak self] in
            for await _ in center.notifications(named: name) {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }
}
