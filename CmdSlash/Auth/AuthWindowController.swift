import AppKit
import SwiftUI

/// Owns the sign-in/sign-up window — a real `NSWindow`, not the ⌘/ overlay panel (see
/// `AuthView`'s doc comment for why). Reused across shows rather than recreated each time, so
/// re-invoking "Sign In..." from the status-bar menu while it's already open just refocuses it.
@MainActor
final class AuthWindowController {
    private var window: NSWindow?

    func show(onSignedIn: @escaping () -> Void = {}) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: AuthView(onSignedIn: { [weak self] in
            self?.close()
            onSignedIn()
        }))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "CmdSlash"
        newWindow.contentView = hosting
        newWindow.center()
        // Not released on close (the default) — this controller keeps reusing the same window
        // instance across repeated "Sign In..." invocations rather than recreating it each time.
        newWindow.isReleasedWhenClosed = false
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.orderOut(nil)
    }
}
