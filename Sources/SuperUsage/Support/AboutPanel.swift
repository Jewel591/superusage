import AppKit

/// Presents the standard macOS About panel for the footer menu's "About superUsage" item.
///
/// As a menu-bar accessory app, superUsage is not the active app while the popover is showing, so the
/// app is activated first — otherwise the panel would open behind whatever app currently owns the
/// foreground. The panel pulls the app icon, name, and version (`CFBundleShortVersionString` — the
/// same string `AppInfo.version` surfaces in the footer) straight from the bundle; we only supply the
/// credits line, naming the maintainers and linking the GitHub repo.
enum AboutPanel {
    @MainActor
    static func present() {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Centered credits for the current project and its upstream foundation.
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Created by ", attributes: base))
        credits.append(link("Liao Lin", "https://github.com/Jewel591", base: base))
        credits.append(NSAttributedString(string: "\nDerived from ", attributes: base))
        credits.append(link("OpenUsage", "https://github.com/robinebers/openusage", base: base))
        credits.append(NSAttributedString(string: " by Robin Ebers", attributes: base))
        credits.append(NSAttributedString(string: "\n\nOpen source on ", attributes: base))
        credits.append(link("GitHub", "https://github.com/Jewel591/superusage", base: base))
        return credits
    }

    private static func link(_ text: String, _ urlString: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = base
        if let url = URL(string: urlString) {
            attributes[.link] = url
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
