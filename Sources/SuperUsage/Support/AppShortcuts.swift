import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Toggles the menu-bar popover from anywhere. No default combo — the user records one on the
    /// popover's Settings screen (the recorder field clears with its ⓧ, which disables the shortcut).
    static let togglePopover = Self("togglePopover")

    /// Opens the Top Peek panel from anywhere, for people who would rather press a key than push the
    /// pointer into the top edge of the screen. No default combo — recorded on the Settings screen,
    /// and only offered there while Top Peek is turned on.
    static let toggleDynamicIsland = Self("toggleDynamicIsland")
}
