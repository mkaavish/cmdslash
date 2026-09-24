import AppKit

/// Activates Chrome after a browser_navigate/browser_click. The extension bridge's commands
/// (`chrome.tabs.update`, `chrome.scripting.executeScript`) run entirely inside Chrome's own
/// process and never touch the WindowServer, so they never bring Chrome to the front or switch
/// macOS Spaces on their own — including when Chrome is fullscreen in its own dedicated Space,
/// which otherwise leaves the action running invisibly on a Space the user is never shown. This
/// activates Chrome the same way OpenApplicationTool activates any app via
/// `NSWorkspace.openApplication`, which macOS also treats as a Space-switch request when the
/// target window is fullscreen elsewhere.
enum BrowserActivation {
    static func activateChrome() async {
        guard let path = NSWorkspace.shared.fullPath(forApplication: "Google Chrome") else { return }
        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }
}
