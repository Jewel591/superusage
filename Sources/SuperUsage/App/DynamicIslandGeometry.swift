import Foundation

/// Pure placement math for the Top Peek panel, kept free of `NSScreen`/`NSWindow` so the display,
/// notch, full-screen, and multi-monitor cases can all be tested without a window server.
///
/// Everything is expressed in AppKit's screen coordinates (origin bottom-left, y growing upward), which
/// is what `NSScreen.frame` and `NSEvent.mouseLocation` both speak.
enum DynamicIslandGeometry {
    /// Breathing room between the bottom of the menu bar and the top of the panel.
    static let menuBarGap: CGFloat = 6
    /// How far the panel stays clear of the left/right screen edges when the content is wider than the
    /// display can hold.
    static let horizontalMargin: CGFloat = 12
    /// Floor kept below the panel, so a very tall expansion still can't run off the bottom edge.
    static let bottomMargin: CGFloat = 12
    /// Width of the top-edge band that arms the reveal. Narrow and centered on purpose: the corners of
    /// the menu bar belong to the Apple menu and the status items, and a full-width trigger would fire
    /// every time the pointer went there.
    static let triggerWidth: CGFloat = 260
    /// Height of that band. Only the extreme top edge counts — the pointer has to be pushed all the way
    /// into the edge, the same deliberate gesture that reveals the menu bar in a full-screen app. A band
    /// as tall as the menu bar would fire while the user was simply reaching for a menu.
    static let triggerHeight: CGFloat = 4
    /// Slack around the panel that still counts as "the pointer is on it", so a hand that overshoots by
    /// a few points on the way down doesn't dismiss what it was reaching for.
    static let keepAlivePadding: CGFloat = 16

    /// Height of the menu bar on this screen: the gap `visibleFrame` leaves at the top. Handles the
    /// notch (a taller bar) without special-casing it, and reads 0 whenever the bar is hidden — inside a
    /// full-screen space, or with "Automatically hide and show the menu bar" on.
    ///
    /// Only the top edge is consulted. The Dock also shrinks `visibleFrame`, but never from the top.
    static func menuBarInset(screenFrame: CGRect, visibleFrame: CGRect) -> CGFloat {
        max(0, screenFrame.maxY - visibleFrame.maxY)
    }

    /// The inset the panel actually hangs from. A hidden menu bar reports 0, but pushing the pointer to
    /// the top edge is exactly what makes macOS slide that bar back down — so we reserve room for it
    /// anyway and the two never overlap.
    ///
    /// - Parameter fallbackInset: the height the menu bar would have if shown (`NSStatusBar.system.thickness`).
    static func topInset(menuBarInset: CGFloat, fallbackInset: CGFloat) -> CGFloat {
        max(menuBarInset, max(0, fallbackInset))
    }

    /// The band that arms the reveal: a thin strip hugging the top edge, centered on the display.
    static func triggerZone(screenFrame: CGRect) -> CGRect {
        let width = min(triggerWidth, screenFrame.width)
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - triggerHeight,
            width: width,
            height: triggerHeight
        )
    }

    /// Where a panel of `size` sits: horizontally centered on the display, hanging just under the menu
    /// bar. The size is clamped to what the display can hold, so an expansion taller than the screen
    /// scrolls its content rather than running off the bottom.
    ///
    /// Coordinates are rounded to whole points — a half-point origin makes text render soft on a 1x
    /// display.
    static func panelFrame(size: CGSize, screenFrame: CGRect, topInset: CGFloat) -> CGRect {
        let width = min(max(size.width, 1), max(1, screenFrame.width - horizontalMargin * 2))
        let top = screenFrame.maxY - topInset - menuBarGap
        let height = min(max(size.height, 1), max(1, top - screenFrame.minY - bottomMargin))
        return CGRect(
            x: (screenFrame.midX - width / 2).rounded(),
            y: (top - height).rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    /// The region the pointer may occupy without dismissing the panel: the panel plus a little slack,
    /// the trigger band, and — crucially — the corridor between them, so travelling down from the screen
    /// edge onto the panel never passes through dead space.
    static func keepAliveZone(panelFrame: CGRect, screenFrame: CGRect) -> CGRect {
        let padded = panelFrame.insetBy(dx: -keepAlivePadding, dy: -keepAlivePadding)
        let corridor = CGRect(
            x: padded.minX,
            y: padded.minY,
            width: padded.width,
            height: max(0, screenFrame.maxY - padded.minY)
        )
        return corridor.union(triggerZone(screenFrame: screenFrame))
    }
}
