import AppKit
import ApplicationServices

/// The `set_fullscreen` tool. Chrome and other well-behaved Cocoa apps back their native
/// fullscreen (the green button / ⌃⌘F) with the AXFullScreen accessibility attribute, so setting
/// it directly does the same thing as if the user had triggered it themselves — no CGEvent
/// keystroke simulation needed. Targets the frontmost app's currently focused window, same
/// AXUIElement handle ContextEngine already reads windowTitle from.
struct FullscreenWindowTool {
    enum ToolError: Error, LocalizedError {
        case accessibilityNotGranted
        case noFocusedWindow
        case unsupported

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                "CmdSlash needs Accessibility permission to control windows — granting it just opened System Settings; try again once it's on."
            case .noFocusedWindow:
                "Couldn't find a focused window to fullscreen."
            case .unsupported:
                "That window doesn't support fullscreen."
            }
        }
    }

    func execute(enabled: Bool) throws {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.requestIfNeeded()
            throw ToolError.accessibilityNotGranted
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw ToolError.noFocusedWindow
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else {
            throw ToolError.noFocusedWindow
        }

        let status = AXUIElementSetAttributeValue(
            window as! AXUIElement,
            "AXFullScreen" as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard status == .success else {
            throw ToolError.unsupported
        }
    }
}
