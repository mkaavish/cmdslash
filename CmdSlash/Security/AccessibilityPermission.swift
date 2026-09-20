import ApplicationServices

/// The Accessibility permission gate for AXUIElement access (Docs/PLANNING.md §45). Requested
/// lazily on first use, not at launch — granting it opens System Settings directly to the
/// Accessibility pane with CmdSlash listed, since there's no in-app "Allow" button for this one.
enum AccessibilityPermission {
    private static var hasPromptedThisSession = false

    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestIfNeeded() {
        guard !isGranted, !hasPromptedThisSession else { return }
        hasPromptedThisSession = true
        let options: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
