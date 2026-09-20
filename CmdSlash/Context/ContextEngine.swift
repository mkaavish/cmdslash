import AppKit
import ApplicationServices
import os

/// Captures context at the cheapest tier that's available, never escalating to screenshots here
/// (Docs/PLANNING.md §18) — this is the structured tier: `NSWorkspace` for the frontmost app,
/// `AXUIElement` for window title and selected text, `NSPasteboard` for the clipboard.
enum ContextEngine {
    static func captureSnapshot() -> ContextSnapshot {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName
        let bundleID = frontmost?.bundleIdentifier

        var windowTitle: String?
        var selectedText: String?

        if let pid = frontmost?.processIdentifier, AccessibilityPermission.isGranted {
            let appElement = AXUIElementCreateApplication(pid)

            if let window = copyAttribute(appElement, kAXFocusedWindowAttribute) {
                windowTitle = copyAttribute(window as! AXUIElement, kAXTitleAttribute) as? String
            }

            if let focusedElement = copyAttribute(appElement, kAXFocusedUIElementAttribute) {
                let text = copyAttribute(focusedElement as! AXUIElement, kAXSelectedTextAttribute) as? String
                selectedText = (text?.isEmpty == false) ? text : nil
            }
        }

        let clipboardText = NSPasteboard.general.string(forType: .string)

        return ContextSnapshot(
            frontmostAppName: appName,
            frontmostBundleID: bundleID,
            windowTitle: windowTitle,
            selectedText: selectedText,
            clipboardText: clipboardText
        )
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return status == .success ? value : nil
    }

    private static let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "ContextEngine")

    /// Temporary verification aid while there's no UI surfacing context yet — lets us confirm real
    /// AX data is being captured via `log show`, without printing selected text/clipboard content.
    static func logForDebugging(_ snapshot: ContextSnapshot) {
        // .notice, not .debug — debug-level os_log messages aren't persisted by default, which
        // makes them useless for `log show` after the fact (only live `log stream` would catch them).
        logger.notice("""
        context: app=\(snapshot.frontmostAppName ?? "nil", privacy: .public) \
        bundleID=\(snapshot.frontmostBundleID ?? "nil", privacy: .public) \
        windowTitle=\(snapshot.windowTitle ?? "nil", privacy: .public) \
        hasSelectedText=\(snapshot.selectedText != nil) \
        hasClipboardText=\(snapshot.clipboardText != nil) \
        axGranted=\(AccessibilityPermission.isGranted)
        """)
    }
}
