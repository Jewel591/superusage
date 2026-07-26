import XCTest
@testable import SuperUsage

/// Covers `DynamicIslandGeometry`: where the Top Peek panel hangs and which region of the screen keeps
/// it up. All of it is pure math over rects, so the notch, the hidden menu bar, an external display, and
/// a panel taller than the screen can each be checked without a window server.
final class DynamicIslandGeometryTests: XCTestCase {
    /// A 1512×982 built-in display with a notch: the menu bar takes 37pt off the top.
    private let notched = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                           visible: CGRect(x: 0, y: 0, width: 1512, height: 945))
    /// A 1920×1080 external display with the standard 24pt menu bar.
    private let external = (frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                            visible: CGRect(x: 1512, y: 76, width: 1920, height: 980))

    // MARK: - Menu bar inset

    func testMenuBarInsetReadsTheTopGapOnly() {
        XCTAssertEqual(DynamicIslandGeometry.menuBarInset(screenFrame: notched.frame, visibleFrame: notched.visible), 37)
        // The external screen's `visibleFrame` is also shortened at the bottom by the Dock, which must
        // not leak into the top inset.
        XCTAssertEqual(DynamicIslandGeometry.menuBarInset(screenFrame: external.frame, visibleFrame: external.visible), 24)
    }

    func testMenuBarInsetIsZeroWhenTheBarIsHidden() {
        // Full-screen spaces and "automatically hide the menu bar" both leave the top edge free.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(DynamicIslandGeometry.menuBarInset(screenFrame: frame, visibleFrame: frame), 0)
    }

    func testMenuBarInsetNeverGoesNegative() {
        // A `visibleFrame` taller than the frame shouldn't be possible, but a negative inset would pull
        // the panel up over the top edge, so clamp rather than trust.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let oversized = CGRect(x: 0, y: 0, width: 1512, height: 1000)
        XCTAssertEqual(DynamicIslandGeometry.menuBarInset(screenFrame: frame, visibleFrame: oversized), 0)
    }

    func testTopInsetReservesTheMenuBarEvenWhenItIsHidden() {
        // Pushing the pointer into the top edge is what slides a hidden menu bar back down, so the panel
        // has to leave room for the bar it is about to summon.
        XCTAssertEqual(DynamicIslandGeometry.topInset(menuBarInset: 0, fallbackInset: 24), 24)
        // A notch is taller than the fallback, so the real inset wins.
        XCTAssertEqual(DynamicIslandGeometry.topInset(menuBarInset: 37, fallbackInset: 24), 37)
    }

    // MARK: - Trigger zone

    func testTriggerZoneHugsTheTopEdgeAndIsCentered() {
        let zone = DynamicIslandGeometry.triggerZone(screenFrame: external.frame)
        XCTAssertEqual(zone.maxY, external.frame.maxY)
        XCTAssertEqual(zone.height, DynamicIslandGeometry.triggerHeight)
        XCTAssertEqual(zone.midX, external.frame.midX)
        XCTAssertEqual(zone.width, DynamicIslandGeometry.triggerWidth)
    }

    func testTriggerZoneIgnoresTheScreenCorners() {
        // The corners belong to the Apple menu and the status items; a trigger there would fire every
        // time the user reached for either.
        let zone = DynamicIslandGeometry.triggerZone(screenFrame: external.frame)
        let topLeft = CGPoint(x: external.frame.minX + 4, y: external.frame.maxY - 1)
        let topRight = CGPoint(x: external.frame.maxX - 4, y: external.frame.maxY - 1)
        XCTAssertFalse(zone.contains(topLeft))
        XCTAssertFalse(zone.contains(topRight))
        XCTAssertTrue(zone.contains(CGPoint(x: external.frame.midX, y: external.frame.maxY - 1)))
    }

    func testTriggerZoneIsPlacedInTheDisplaysOwnCoordinates() {
        // A second display lives at a non-zero origin; the band must land on it, not on the primary.
        let zone = DynamicIslandGeometry.triggerZone(screenFrame: external.frame)
        XCTAssertTrue(external.frame.contains(CGPoint(x: zone.midX, y: zone.midY)))
    }

    func testTriggerZoneNarrowsToFitASmallDisplay() {
        let tiny = CGRect(x: 0, y: 0, width: 160, height: 120)
        let zone = DynamicIslandGeometry.triggerZone(screenFrame: tiny)
        XCTAssertEqual(zone.width, 160)
        XCTAssertEqual(zone.minX, 0)
    }

    // MARK: - Panel frame

    func testPanelHangsBelowTheMenuBarAndIsCentered() {
        let frame = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 200),
            screenFrame: notched.frame,
            topInset: 37
        )
        XCTAssertEqual(frame.maxY, notched.frame.maxY - 37 - DynamicIslandGeometry.menuBarGap)
        XCTAssertEqual(frame.midX, notched.frame.midX)
        XCTAssertEqual(frame.size, CGSize(width: 320, height: 200))
    }

    func testPanelNeverOverlapsTheMenuBar() {
        // The single invariant that matters on a notched display: the panel's top edge stays under the
        // bar, whatever size the content asks for.
        for height in [24.0, 200.0, 900.0, 4000.0] {
            let frame = DynamicIslandGeometry.panelFrame(
                size: CGSize(width: 320, height: height),
                screenFrame: notched.frame,
                topInset: 37
            )
            XCTAssertLessThanOrEqual(frame.maxY, notched.frame.maxY - 37, "height \(height) rode up into the menu bar")
        }
    }

    func testPanelClampsToTheDisplayItIsOn() {
        // Content wider or taller than the screen is clamped rather than allowed to run off the edges.
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frame = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 900, height: 900),
            screenFrame: tiny,
            topInset: 24
        )
        XCTAssertEqual(frame.width, 300 - DynamicIslandGeometry.horizontalMargin * 2)
        XCTAssertGreaterThanOrEqual(frame.minY, tiny.minY)
        XCTAssertTrue(tiny.contains(frame), "clamped panel should sit entirely on the display")
    }

    func testPanelCoordinatesAreWholePoints() {
        // A half-point origin renders text soft on a 1x display, and odd content widths are routine.
        let frame = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 213.7, height: 41.3),
            screenFrame: external.frame,
            topInset: 24
        )
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(), "expected whole points, got \(value)")
        }
    }

    // MARK: - Keep-alive zone

    func testKeepAliveZoneCoversTheTravelFromTheTopEdgeToThePanel() {
        // Between the trigger band and the panel is a gap the size of the menu bar. If that corridor
        // weren't covered, moving down from the edge onto the panel would dismiss it halfway there.
        let panel = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 44),
            screenFrame: notched.frame,
            topInset: 37
        )
        let zone = DynamicIslandGeometry.keepAliveZone(panelFrame: panel, screenFrame: notched.frame)
        let midCorridor = CGPoint(x: notched.frame.midX, y: notched.frame.maxY - 20)
        XCTAssertTrue(zone.contains(midCorridor))
        XCTAssertTrue(zone.contains(CGPoint(x: panel.midX, y: panel.midY)))
        XCTAssertTrue(zone.contains(CGPoint(x: notched.frame.midX, y: notched.frame.maxY - 1)))
    }

    func testKeepAliveZoneToleratesASmallOvershoot() {
        let panel = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 44),
            screenFrame: notched.frame,
            topInset: 37
        )
        let zone = DynamicIslandGeometry.keepAliveZone(panelFrame: panel, screenFrame: notched.frame)
        let justBelow = CGPoint(x: panel.midX, y: panel.minY - DynamicIslandGeometry.keepAlivePadding + 2)
        XCTAssertTrue(zone.contains(justBelow), "a few points of overshoot should not dismiss the panel")
    }

    // MARK: - Height budget

    func testAvailableHeightIsWhatIsLeftBelowTheMenuBar() {
        // The budget handed to the content, so a long starred list scrolls inside the panel instead of
        // being cropped by it.
        let budget = DynamicIslandGeometry.availableHeight(screenFrame: notched.frame, topInset: 37)
        XCTAssertEqual(
            budget,
            982 - 37 - DynamicIslandGeometry.menuBarGap - DynamicIslandGeometry.bottomMargin
        )
    }

    func testAvailableHeightMatchesTheTallestPanelThatFits() {
        // The two must agree, or the content would size itself to a budget the window then clamps away.
        let budget = DynamicIslandGeometry.availableHeight(screenFrame: external.frame, topInset: 24)
        let frame = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 10_000),
            screenFrame: external.frame,
            topInset: 24
        )
        XCTAssertEqual(frame.height, budget)
        XCTAssertGreaterThanOrEqual(frame.minY, external.frame.minY)
    }

    func testAvailableHeightStaysPositiveOnADisplayShorterThanItsOwnMenuBar() {
        // Not a real Mac, but the inset is read from the system rather than derived, so a display that
        // cannot fit its own reserve must still yield a usable budget rather than a negative one.
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 30)
        let budget = DynamicIslandGeometry.availableHeight(screenFrame: tiny, topInset: 37)
        XCTAssertGreaterThan(budget, 0)
        let frame = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 200),
            screenFrame: tiny,
            topInset: 37
        )
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThan(frame.width, 0)
    }

    func testPanelSurvivesANegativeTopInset() {
        // `topInset` is clamped at its source, but the frame math must not produce an inverted rect even
        // if a negative one ever reached it.
        let frame = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 44),
            screenFrame: notched.frame,
            topInset: -50
        )
        XCTAssertEqual(frame.height, 44)
        XCTAssertGreaterThan(frame.width, 0)
    }

    func testKeepAliveZoneEndsWhereThePointerHasClearlyLeft() {
        let panel = DynamicIslandGeometry.panelFrame(
            size: CGSize(width: 320, height: 44),
            screenFrame: notched.frame,
            topInset: 37
        )
        let zone = DynamicIslandGeometry.keepAliveZone(panelFrame: panel, screenFrame: notched.frame)
        XCTAssertFalse(zone.contains(CGPoint(x: panel.midX, y: notched.frame.midY)))
        XCTAssertFalse(zone.contains(CGPoint(x: notched.frame.minX + 10, y: panel.midY)))
    }
}
