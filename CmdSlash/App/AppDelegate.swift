import AppKit
import Carbon.HIToolbox

/// App lifecycle for the menu-bar-only (`LSUIElement`) process: the status item, the pre-warmed
/// overlay, and the global hotkey (Docs/PLANNING.md §10, §16).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayWindowController()
        setupStatusItem()
        registerHotKey()
        BrowserBridgeServer.shared.start()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slash.circle", accessibilityDescription: "CmdSlash")

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Toggle CmdSlash (⌘/)", action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit CmdSlash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
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
}
