/// A point-in-time read of "what is the user looking at" (Docs/PLANNING.md §18). Fields are
/// optional throughout — a missing Accessibility grant, an app with poor AX support, or an empty
/// selection are all normal, expected states, not errors.
struct ContextSnapshot {
    let frontmostAppName: String?
    let frontmostBundleID: String?
    let windowTitle: String?
    let selectedText: String?
    let clipboardText: String?

    static let empty = ContextSnapshot(
        frontmostAppName: nil,
        frontmostBundleID: nil,
        windowTitle: nil,
        selectedText: nil,
        clipboardText: nil
    )

    /// A short, labeled summary for inclusion in a model prompt. Everything here is untrusted
    /// data about what's on screen, not a trusted instruction (Docs/PLANNING.md §32) — the caller
    /// is responsible for framing it that way, this just formats it.
    var describedForPrompt: String? {
        var lines: [String] = []
        if let frontmostAppName { lines.append("Frontmost app: \(frontmostAppName)") }
        if let windowTitle { lines.append("Window title: \(windowTitle)") }
        if let selectedText { lines.append("Selected text: \"\(selectedText.prefix(500))\"") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
