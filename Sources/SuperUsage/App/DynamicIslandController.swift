import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

/// How much of itself the Top Peek panel is showing. The SwiftUI content reads this to pick a layout;
/// the controller owns every transition into it.
@MainActor
@Observable
final class DynamicIslandPresentation {
    enum Phase: Equatable {
        /// Ordered out. Nothing is mounted that ticks.
        case hidden
        /// The glanceable pill, revealed by the pointer reaching the top edge.
        case compact
        /// The full readout, opened by moving the pointer onto the pill (or by the shortcut).
        case expanded
    }

    fileprivate(set) var phase: Phase = .hidden
}

/// A panel that never takes keyboard focus. The peek panel is a read-out the user glances at while
/// working in something else; taking key away from that app — even briefly — would be the one thing it
/// must never do. Everything it offers is reachable by mouse, so it gives up keyboard input entirely
/// rather than fight the focused app for it.
private final class DynamicIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the Top Peek panel: a borderless overlay that slides out from under the menu bar when the
/// pointer is pushed into the top edge of the screen, and goes away when it leaves.
///
/// The trigger is deliberately a screen-edge gesture rather than a permanent fixture. superUsage already
/// has one always-on surface — the menu-bar strip — and a second one showing the same numbers would just
/// split the user's attention between two places that never disagree. This surface earns its keep by
/// being absent until asked for, and then saying more than the strip can.
///
/// Two different mechanisms watch the pointer, because neither covers the whole screen on its own:
/// a global event monitor sees the pointer everywhere *except* over this app's own windows, and the
/// SwiftUI content's `onHover` sees exactly that gap. While the panel is up, a low-rate poll of
/// `NSEvent.mouseLocation` decides when to dismiss — a monitor can simply stop reporting once the
/// pointer settles inside another app, and a panel that never noticed the user left would be a panel
/// stuck on screen.
@MainActor
final class DynamicIslandController {
    /// How long the pointer must rest in the top-edge band before the panel appears. Short enough to
    /// feel immediate, long enough that a pointer flung to the menu bar and straight back doesn't
    /// flash the panel on the way past.
    private static let revealDwell: Duration = .milliseconds(220)
    /// Grace period after the pointer leaves, so a hand that overshoots on the way to the panel gets it
    /// back instead of watching it vanish.
    private static let dismissDelay: Duration = .milliseconds(400)
    /// How often the pointer is checked while the panel is up. Twice a second is imperceptible for a
    /// dismissal — and this timer exists only while something is actually on screen.
    private static let pollInterval: Duration = .milliseconds(400)
    private static let revealTravel: CGFloat = 8
    private static let revealDuration: TimeInterval = 0.18
    private static let dismissDuration: TimeInterval = 0.14

    private let container: AppContainer
    private let settings: DynamicIslandSettings
    private let presentation = DynamicIslandPresentation()
    /// Opens the dashboard popover on a given screen — the panel's "Open superUsage" and "Settings"
    /// buttons. Injected rather than reached for, so this type stays independent of the status item.
    private let openPopover: (PopoverScreen) -> Void

    private var panel: DynamicIslandPanel?
    private var hosting: NSHostingController<AnyView>?
    /// The display the visible panel is anchored to. Cleared on hide; re-picked on every reveal, so a
    /// display that was unplugged in between can never place the next reveal off-screen.
    private var anchorScreen: NSScreen?

    private var revealTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var appearanceObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    /// True while the pointer is inside the panel's own content — reported by SwiftUI, since a global
    /// monitor goes quiet over this app's own windows.
    private var isPointerOverPanel = false
    /// True when the panel was summoned by the keyboard shortcut. It then ignores the pointer entirely
    /// and stays until the shortcut is pressed again or the user clicks elsewhere — otherwise it would
    /// disappear the moment the user moved the mouse to read it.
    private var isSticky = false
    /// Bumped on every reveal and hide so an in-flight fade-out can tell whether it is still the current
    /// transition before it orders the panel out from under a newer reveal.
    private var generation = 0

    init(
        container: AppContainer,
        settings: DynamicIslandSettings,
        openPopover: @escaping (PopoverScreen) -> Void
    ) {
        self.container = container
        self.settings = settings
        self.openPopover = openPopover

        applyEnablement()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        // A display unplugged while the panel is up would leave it anchored to a screen that no longer
        // exists — off in coordinates nothing can show. Re-place it, or take it down.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersChanged()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDynamicIsland) { [weak self] in
            self?.toggleSticky()
        }
    }

    // MARK: - Enablement

    /// Arms or disarms the whole feature, and re-arms itself on the next change to the setting.
    /// Mirrors `StatusItemController.applyTransparency`'s re-arm — `withObservationTracking`'s `onChange`
    /// is one-shot.
    private func applyEnablement() {
        let enabled = withObservationTracking {
            settings.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyEnablement()
            }
        }
        if enabled {
            startMouseMonitor()
        } else {
            stopMouseMonitor()
            hide()
        }
    }

    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        // Mouse events need no accessibility permission (only keyboard monitoring does), so this arms
        // silently. The handler leaves immediately unless the pointer is in the top-edge band, which is
        // the whole cost while the user works normally.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pointerMoved()
            }
        }
        AppLog.info(.statusItem, "Top Peek armed")
    }

    private func stopMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        revealTask?.cancel()
        revealTask = nil
    }

    // MARK: - Pointer tracking

    /// The reveal half. Dismissal is the poll's job — this only ever fires while the pointer is over
    /// some *other* app, which is exactly when a reveal can start and never when one needs to end.
    private func pointerMoved() {
        guard settings.isEnabled, !isSticky, presentation.phase == .hidden else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = screen(containing: mouse),
              DynamicIslandGeometry.triggerZone(screenFrame: screen.frame).contains(mouse) else {
            revealTask?.cancel()
            revealTask = nil
            return
        }
        armReveal(on: screen)
    }

    private func armReveal(on screen: NSScreen) {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.revealDwell)
            guard !Task.isCancelled, let self else { return }
            self.revealTask = nil
            // Re-check rather than trust the sample that armed us: the dwell is short, but the pointer
            // can still have moved on, and revealing under a pointer that already left is the exact
            // flicker the dwell exists to prevent.
            let mouse = NSEvent.mouseLocation
            guard self.presentation.phase == .hidden,
                  DynamicIslandGeometry.triggerZone(screenFrame: screen.frame).contains(mouse) else { return }
            self.show(on: screen, phase: .compact)
        }
    }

    /// Reported by the SwiftUI content — the one signal that can tell the pointer is on the panel, since
    /// the global monitor goes quiet over this app's own windows. Moving onto the pill is what opens the
    /// full readout; moving off closes it back down.
    private func pointerOverPanelChanged(_ isOver: Bool) {
        isPointerOverPanel = isOver
        guard !isSticky, presentation.phase != .hidden else { return }
        if isOver {
            dismissTask?.cancel()
            dismissTask = nil
            setPhase(.expanded)
        } else {
            setPhase(.compact)
            evaluateDismissal()
        }
    }

    /// Runs only while the panel is up: the deterministic answer to "is the pointer still here?", which
    /// event monitors cannot give once the pointer settles inside another app and stops generating moves.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self, self.presentation.phase != .hidden else { return }
                guard !self.isSticky else { continue }
                self.evaluateDismissal()
            }
        }
    }

    /// Schedules the panel's exit unless the pointer is still on it or in the corridor leading to it.
    private func evaluateDismissal() {
        guard presentation.phase != .hidden, !isSticky else { return }
        if isPointerOverPanel || pointerIsInKeepAliveZone() {
            dismissTask?.cancel()
            dismissTask = nil
            return
        }
        guard dismissTask == nil else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dismissDelay)
            guard !Task.isCancelled, let self else { return }
            self.dismissTask = nil
            guard !self.isPointerOverPanel, !self.pointerIsInKeepAliveZone() else { return }
            self.hide()
        }
    }

    private func pointerIsInKeepAliveZone() -> Bool {
        guard let panel, let screen = anchorScreen else { return false }
        let zone = DynamicIslandGeometry.keepAliveZone(
            panelFrame: panel.frame,
            screenFrame: screen.frame
        )
        return zone.contains(NSEvent.mouseLocation)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    // MARK: - Keyboard shortcut

    /// The shortcut opens the full readout and leaves it up: someone who pressed a key to see this is
    /// not holding the pointer at the top of the screen, so pointer-based dismissal would take it away
    /// the moment they looked at it. Pressing again — or clicking anywhere else — puts it back.
    private func toggleSticky() {
        guard settings.isEnabled else { return }
        if presentation.phase != .hidden, isSticky {
            hide()
            return
        }
        guard let screen = screen(containing: NSEvent.mouseLocation) else { return }
        isSticky = true
        show(on: screen, phase: .expanded)
        startClickMonitor()
    }

    /// Only armed for the shortcut-summoned panel. The monitor observes; it never swallows the click, so
    /// whatever the user was actually clicking still gets it.
    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: - Show / hide

    private func show(on screen: NSScreen, phase: DynamicIslandPresentation.Phase) {
        let panel = ensurePanel()
        generation += 1
        anchorScreen = screen
        presentation.phase = phase

        let frame = targetFrame(on: screen)
        if settings.reduceMotion {
            panel.setFrame(frame, display: false)
            panel.alphaValue = 1
            panel.orderFront(nil)
        } else {
            // Start a touch higher and transparent, then ease down into place — the panel reads as
            // coming out from under the menu bar rather than blinking into existence.
            panel.setFrame(frame.offsetBy(dx: 0, dy: Self.revealTravel), display: false)
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.revealDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: false)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
        startPolling()
    }

    private func hide() {
        revealTask?.cancel()
        revealTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        pollTask?.cancel()
        pollTask = nil
        stopClickMonitor()
        isSticky = false
        isPointerOverPanel = false
        anchorScreen = nil

        guard let panel, panel.isVisible else {
            presentation.phase = .hidden
            return
        }
        generation += 1
        let generation = generation
        // The phase is left alone until the fade finishes: flipping it now would swap an expanded
        // readout back to the compact pill in full view, halfway through its own exit.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = settings.reduceMotion ? 0 : Self.dismissDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.presentation.phase = .hidden
            }
        }
    }

    private func setPhase(_ phase: DynamicIslandPresentation.Phase) {
        guard presentation.phase != phase, presentation.phase != .hidden else { return }
        presentation.phase = phase
        resizeToContent(animated: !settings.reduceMotion)
    }

    /// Re-measures the SwiftUI content and moves the panel to match. Called on every phase change and
    /// whenever the content's own ideal size shifts (a value growing a digit, a provider dropping out).
    private func resizeToContent(animated: Bool) {
        guard let panel, let screen = anchorScreen, panel.isVisible else { return }
        let frame = targetFrame(on: screen)
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.revealDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: false)
            }
        } else {
            panel.setFrame(frame, display: false)
        }
        panel.invalidateShadow()
    }

    /// The panel's frame for the content it currently holds, centered under `screen`'s menu bar.
    private func targetFrame(on screen: NSScreen) -> NSRect {
        let size = contentSize()
        let inset = DynamicIslandGeometry.topInset(
            menuBarInset: DynamicIslandGeometry.menuBarInset(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            ),
            // A full-screen space (or an auto-hidden bar) reports no inset, but pushing the pointer to
            // the top edge is exactly what slides that bar back down — so reserve its height anyway and
            // the two never land on top of each other.
            fallbackInset: NSStatusBar.system.thickness
        )
        return DynamicIslandGeometry.panelFrame(
            size: size,
            screenFrame: screen.frame,
            topInset: inset
        )
    }

    /// Lays the SwiftUI content out now and measures it, rather than waiting for the size to arrive
    /// asynchronously — the frame is needed in the same turn the panel is shown, or it opens at the
    /// wrong size and corrects itself in front of the user.
    private func contentSize() -> NSSize {
        guard let hosting else { return NSSize(width: DynamicIslandView.expandedWidth, height: 44) }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        return NSSize(width: max(fitting.width, 1), height: max(fitting.height, 1))
    }

    private func screenParametersChanged() {
        guard presentation.phase != .hidden else { return }
        // The anchor screen is matched by identity, not by index: displays reshuffle on a reconnect, and
        // a stale index would place the panel on whichever screen inherited the slot.
        guard let anchorScreen, NSScreen.screens.contains(anchorScreen) else {
            hide()
            return
        }
        resizeToContent(animated: false)
    }

    // MARK: - Panel

    private func ensurePanel() -> DynamicIslandPanel {
        if let panel { return panel }

        let hosting = NSHostingController(
            rootView: AnyView(
                DynamicIslandView(
                    presentation: presentation,
                    actions: DynamicIslandActions(
                        pointerOverChanged: { [weak self] isOver in
                            self?.pointerOverPanelChanged(isOver)
                        },
                        openDashboard: { [weak self] in self?.open(.dashboard) },
                        openSettings: { [weak self] in self?.open(.settings) },
                        openCustomize: { [weak self] in self?.open(.customize) }
                    )
                )
                .environment(container)
                .environment(container.layout)
                .environment(container.dataStore)
            )
        )
        // Keeps `preferredContentSize` in step with SwiftUI's ideal size, which is what tells the
        // sizing host that the content changed shape on its own.
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting

        let host = DynamicIslandHostController()
        host.onPreferredContentSizeChange = { [weak self] _ in
            self?.resizeToContent(animated: !(self?.settings.reduceMotion ?? false))
        }
        host.embed(hosting)

        let panel = DynamicIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: DynamicIslandView.expandedWidth, height: 44),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Above ordinary windows but below menus, so an open menu is never covered by a peek.
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // Follows the user across Spaces and shows over full-screen apps, and stays out of the window
        // cycler — it is a read-out, not a window anyone tabs to.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = AppearanceSetting.current.nsAppearance
        panel.contentViewController = host
        self.panel = panel
        return panel
    }

    /// The panel's own actions all end the same way: hand off to the popover, which owns depth, and get
    /// out of the way.
    private func open(_ screen: PopoverScreen) {
        hide()
        openPopover(screen)
    }
}

/// Hosts the SwiftUI content and forwards its ideal-size changes.
///
/// `preferredContentSizeDidChange(for:)` is only delivered to a *parent* view controller, so the hosting
/// controller cannot report its own size changes — it needs this one wrapped around it.
private final class DynamicIslandHostController: NSViewController {
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    override func loadView() {
        view = NSView()
    }

    func embed(_ child: NSViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        onPreferredContentSizeChange?(viewController.preferredContentSize)
    }
}
