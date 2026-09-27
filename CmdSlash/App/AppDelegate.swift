import AppKit

/// App lifecycle for the menu-bar-only (`LSUIElement`) process: the status item, the pre-warmed
/// overlay, the global hotkey (Docs/PLANNING.md §10, §16), and — since the managed-key pivot
/// (§59) — the companion window (sign-in, and eventually settings/connectors) the app now needs.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var hotKey: GlobalHotKey?
    private var companionWindowController: CompanionWindowController?
    private var signOutMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayWindowController()
        companionWindowController = CompanionWindowController()
        setupStatusItem()
        registerHotKey()
        BrowserBridgeServer.shared.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(hotKeyDidChange),
            name: HotKeySettings.hotKeyChangedNotification, object: nil
        )

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

        let toggleItem = NSMenuItem(title: "Toggle CmdSlash (\(HotKeySettings.description()))", action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        toggleMenuItem = toggleItem

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
    /// (sign-in/sign-out from the companion window, or a refresh failing) and the hotkey binding
    /// (remapped from Settings) can both change between opens. "Open CmdSlash..." stays visible
    /// either way — it's the sign-in surface too now.
    func menuWillOpen(_ menu: NSMenu) {
        signOutMenuItem?.isHidden = !SupabaseSession.hasStoredSession()
        toggleMenuItem?.title = "Toggle CmdSlash (\(HotKeySettings.description()))"
    }

    /// Re-registers against whatever HotKeySettings currently holds — called at launch and again
    /// whenever Settings saves a remapped combination (via hotKeyDidChange below), unregistering
    /// the previous binding first so the old shortcut doesn't linger alongside the new one.
    private func registerHotKey() {
        hotKey?.unregister()
        hotKey = GlobalHotKey(keyCode: HotKeySettings.keyCode, modifiers: HotKeySettings.modifiers) { [weak self] in
            self?.toggleOverlay()
        }
    }

    @objc private func hotKeyDidChange() {
        registerHotKey()
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
