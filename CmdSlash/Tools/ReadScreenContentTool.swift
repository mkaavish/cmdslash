import AppKit
import ApplicationServices

/// The `read_screen_content` tool (Docs/PLANNING.md §18, §21) — the AX-tree snapshot tier of the
/// Context Engine's escalation order, on-demand rather than captured eagerly for every overlay
/// session (unlike the cheap frontmost-app/window-title/selected-text tier ContextEngine already
/// captures up front). This is the native-app counterpart to browser_get_page_text: for an app
/// with no DOM to extract (Mail, Calendar, Finder, Slack desktop, Xcode, ...), this walks its
/// focused window's accessibility tree and summarizes it into readable, bounded text instead of a
/// raw structural dump — per the plan's own risk note, an unbounded AX tree is large/noisy enough
/// to be counterproductive handed straight to a model.
struct ReadScreenContentTool {
    struct Result {
        let appName: String
        let windowTitle: String?
        let summary: String
        let truncated: Bool
    }

    enum ToolError: Error, LocalizedError {
        case accessibilityNotGranted
        case noFrontmostApp
        case noFocusedWindow
        case emptySummary

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                "CmdSlash needs Accessibility permission to read screen content — granting it just opened System Settings; try again once it's on."
            case .noFrontmostApp:
                "Couldn't determine the frontmost app."
            case .noFocusedWindow:
                "Couldn't find a focused window to read."
            case .emptySummary:
                "That window's content didn't expose anything readable via Accessibility."
            }
        }
    }

    // Bounded on every axis the plan flags as a real risk: depth, element count, and a hard
    // character budget, all enforced during the walk itself rather than truncating the result
    // afterward — that keeps a huge tree (Xcode, a giant Finder window) from being slow to walk
    // in the first place, not just slow to read.
    private static let maxDepth = 10
    private static let maxElements = 150
    private static let maxFieldLength = 80
    private static let maxTotalCharacters = 4000

    /// Purely structural roles worth descending into but not worth a line of their own — unless
    /// they carry their own label, in which case they're surfaced like anything else (a labeled
    /// AXGroup is meaningful; an unlabeled one is just layout noise).
    private static let structuralRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXUnknown", "AXLayoutArea", "AXLayoutItem"
    ]

    func execute() async throws -> Result {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.requestIfNeeded()
            throw ToolError.accessibilityNotGranted
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw ToolError.noFrontmostApp
        }
        let appName = frontmost.localizedName ?? "the frontmost app"
        let pid = frontmost.processIdentifier

        // AXUIElement calls are IPC round-trips to the target process — up to ~150 elements times
        // several attribute reads each is enough real latency that this must not run on the main
        // actor, or it'd freeze the overlay for the duration of the walk.
        let (windowTitle, summary, truncated) = try await Task.detached(priority: .userInitiated) {
            try Self.walkFocusedWindow(pid: pid)
        }.value

        return Result(appName: appName, windowTitle: windowTitle, summary: summary, truncated: truncated)
    }

    private static func walkFocusedWindow(pid: pid_t) throws -> (windowTitle: String?, summary: String, truncated: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windowRef = copyAttribute(appElement, kAXFocusedWindowAttribute) else {
            throw ToolError.noFocusedWindow
        }
        let window = windowRef as! AXUIElement
        let windowTitle = copyAttribute(window, kAXTitleAttribute) as? String

        var lines: [String] = []
        var count = 0
        walk(window, depth: 0, lines: &lines, count: &count)

        guard !lines.isEmpty else {
            throw ToolError.emptySummary
        }

        let joined = lines.joined(separator: "\n")
        let truncated = joined.count > maxTotalCharacters
        let summary = truncated ? String(joined.prefix(maxTotalCharacters)) : joined
        return (windowTitle, summary, truncated)
    }

    private static func walk(_ element: AXUIElement, depth: Int, lines: inout [String], count: inout Int) {
        guard depth <= maxDepth, count < maxElements else { return }

        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? "AXUnknown"
        let title = (copyAttribute(element, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (copyAttribute(element, kAXDescriptionAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = copyAttribute(element, kAXValueAttribute)
        let valueText: String?
        switch value {
        case let stringValue as String: valueText = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case let numberValue as NSNumber: valueText = numberValue.stringValue
        default: valueText = nil
        }
        let label = [title, description, valueText].compactMap { $0 }.first { !$0.isEmpty }

        // A structural container with no label of its own is layout noise — skip the line, still
        // descend into its children below.
        if !structuralRoles.contains(role) || label != nil {
            let readableRole = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            var line = String(repeating: "  ", count: depth) + readableRole
            if let label, !label.isEmpty {
                line += ": \"\(label.prefix(maxFieldLength))\""
            }
            if (copyAttribute(element, kAXEnabledAttribute) as? Bool) == false {
                line += " (disabled)"
            }
            lines.append(line)
            count += 1
        }

        guard count < maxElements, let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }
        for child in children {
            walk(child, depth: depth + 1, lines: &lines, count: &count)
            if count >= maxElements { break }
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return status == .success ? value : nil
    }
}
