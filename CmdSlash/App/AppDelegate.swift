import AppKit
import Carbon.HIToolbox

/// App lifecycle for the menu-bar-only (`LSUIElement`) process: the status item, the pre-warmed
/// overlay, the global hotkey (Docs/PLANNING.md §10, §16), and — since the managed-key pivot
/// (§59) — the sign-in gate the app now needs before it can do anything useful.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var hotKey: GlobalHotKey?
    private var authWindowController: AuthWindowController?
    private var signInMenuItem: NSMenuItem?
    private var signOutMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayWindowController()
        authWindowController = AuthWindowController()
        setupStatusItem()
        registerHotKey()
        BrowserBridgeServer.shared.start()

        // A soft gate, not a hard block: shows the sign-in window on launch when there's no
        // session, but it's an ordinary closable window, not modal — ⌘/ still works (and fails
        // with OpenAIClient.ClientError.sessionExpired's own clear message) if someone dismisses
        // it and tries anyway, rather than the app refusing to do anything at all.
        if !Self.hasActiveSession() {
            authWindowController?.show()
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

        let signIn = NSMenuItem(title: "Sign In...", action: #selector(showSignIn), keyEquivalent: "")
        signIn.target = self
        menu.addItem(signIn)
        signInMenuItem = signIn

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
    /// can change between opens (sign-in/sign-out from the window, or a refresh failing).
    func menuWillOpen(_ menu: NSMenu) {
        let signedIn = Self.hasActiveSession()
        signInMenuItem?.isHidden = signedIn
        signOutMenuItem?.isHidden = !signedIn
    }

    private static func hasActiveSession() -> Bool {
        (try? KeychainStore.readString(service: OpenAIClient.sessionKeychainService)) != nil
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

    @objc private func showSignIn() {
        authWindowController?.show()
    }

    @objc private func signOut() {
        try? KeychainStore.delete(service: OpenAIClient.sessionKeychainService)
    }
}
