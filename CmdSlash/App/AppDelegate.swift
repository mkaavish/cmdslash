import AppKit
import Carbon.HIToolbox

/// App lifecycle for the menu-bar-only (`LSUIElement`) process: the status item, the pre-warmed
/// overlay, the global hotkey (Docs/PLANNING.md §10, §16), and — since the managed-key pivot
/// (§59) — the companion window (sign-in, and eventually settings/connectors) the app now needs.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var hotKey: GlobalHotKey?
    private var companionWindowController: CompanionWindowController?
    private var signOutMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayWindowController()
        companionWindowController = CompanionWindowController()
        setupStatusItem()
        registerHotKey()
        BrowserBridgeServer.shared.start()

        // A soft gate, not a hard block: shows the companion window on launch when there's no
        // session, but it's an ordinary closable window, not modal — ⌘/ still works (and fails
        // with SupabaseSession.SessionError's own clear message) if someone dismisses it and
        // tries anyway, rather than the app refusing to do anything at all.
        if !SupabaseSession.hasStoredSession() {
            companionWindowController?.show()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slash.circle", accessibilityDescription: "CmdSlash")

        let menu = NSMenu()
        menu.delegate = self

        let toggleItem = NSMenuItem(title: "Toggle CmdSlash (⌘/)", action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let openCompanion = NSMenuItem(title: "Open CmdSlash...", action: #selector(showCompanion), keyEquivalent: "")
        openCompanion.target = self
        menu.addItem(openCompanion)

        let signOut = NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "")
        signOut.target = self
        menu.addItem(signOut)
        signOutMenuItem = signOut

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit CmdSlash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    /// Recomputed each time the menu is about to open rather than once at setup — session state
    /// can change between opens (sign-in/sign-out from the companion window, or a refresh
    /// failing). "Open CmdSlash..." stays visible either way — it's the sign-in surface too now.
    func menuWillOpen(_ menu: NSMenu) {
        signOutMenuItem?.isHidden = !SupabaseSession.hasStoredSession()
    }

    private func registerHotKey() {
        // Default binding: Cmd+/. Configurable storage (Docs/PLANNING.md §16) lands once
        // there's a real preferences store — this is deliberately the only place the keycode
        // is hardcoded for now.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.toggleOverlay()
        }
    }

    @objc private func toggleOverlay() {
        overlayController?.toggle()
    }

    @objc private func showCompanion() {
        companionWindowController?.show()
    }

    @objc private func signOut() {
        SupabaseSession.signOut()
    }
}
