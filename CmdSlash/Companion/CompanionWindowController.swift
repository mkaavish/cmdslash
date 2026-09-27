import AppKit
import SwiftUI

/// The full companion app window — sign-in/account status today, settings/connectors later
/// (Docs/PLANNING.md §59). Distinct from the ⌘/ overlay: this is a deliberate, pinnable app
/// surface, not a glanceable quick-command bar.
///
/// Toggles the app's Dock presence while open — the standard technique for a menu-bar-only
/// (`LSUIElement`) app to also offer a normal, pinnable window (same approach utilities like
/// Bartender/Ice use): `NSApp.activationPolicy` flips to `.regular` so a Dock icon appears (and
/// can be kept there) while this window is open, and back to `.accessory` when it closes, so the
/// app returns to its usual invisible-until-⌘/ menu-bar presence rather than permanently
/// cluttering the Dock.
@MainActor
final class CompanionWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let hosting = NSHostingView(rootView: AccountView())
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "CmdSlash"
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.delegate = self
        // Not released on close — this controller keeps reusing the same window instance across
        // repeated opens rather than recreating it (and its SwiftUI state) each time.
        newWindow.isReleasedWhenClosed = false
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
