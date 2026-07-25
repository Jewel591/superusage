import AppKit
import SwiftUI

/// Owns the standalone Usage History window.
///
/// superUsage is an accessory (`LSUIElement`) app, so opening a real window needs two things a normal
/// app gets for free: an explicit activation so the window comes to the front of whatever the user was
/// working in, and a controller that outlives the click — an `NSWindow` with no owner is released the
/// moment it falls out of scope. One window is reused across opens, so repeated menu clicks bring the
/// existing chart forward instead of stacking duplicates.
@MainActor
final class QuotaHistoryWindowController: NSObject, NSWindowDelegate {
    private let container: AppContainer
    private var window: NSWindow?

    private static let defaultSize = NSSize(width: 720, height: 500)
    /// Restores position and size across launches. AppKit keys this in `UserDefaults` for us.
    private static let frameAutosaveName = "superusage.quotaHistoryWindow"

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    /// Shows the window, creating it on first use so a user who never opens it pays nothing.
    func present() {
        if let window {
            activate(window)
            return
        }
        let hosting = NSHostingController(
            rootView: QuotaHistoryView()
                .environment(container)
                .environment(container.dataStore)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Usage History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = NSSize(width: 560, height: 400)
        // Without this the window is destroyed on close and the next open would use a freed object.
        // The controller decides the lifetime instead, in `windowWillClose`.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.delegate = self
        window.center()
        self.window = window
        activate(window)
    }

    /// An accessory app is not "active", so ordering the window front is not enough on its own — without
    /// activating, the window appears behind the frontmost app and can't take keyboard focus.
    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the reference so the hosting controller (and the view's reload loop with it) goes away
        // rather than sitting in memory polling the database for a window nobody is looking at.
        window = nil
    }
}

/// Hands the "open Usage History" action to the footer menu. `nil` (the default — previews, share-card
/// renders) simply hides the item, so a rendered card can't offer an action with nothing behind it.
private struct QuotaHistoryPresenterKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var openQuotaHistory: (@MainActor () -> Void)? {
        get { self[QuotaHistoryPresenterKey.self] }
        set { self[QuotaHistoryPresenterKey.self] = newValue }
    }
}
