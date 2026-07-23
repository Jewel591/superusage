import AppKit
import SwiftUI

/// Uses a system symbol until superUsage has its own final icon.
@MainActor
enum MenuBarIcon {
    /// Side length (points) of the menu bar glyph.
    private static let side: CGFloat = 18

    /// Cached template image.
    static let image: NSImage? = render()

    private static func render() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "superUsage"
        )
        image?.size = NSSize(width: side, height: side)
        image?.isTemplate = true
        return image
    }
}
