import AppKit

/// The `open_url` tool (Docs/PLANNING.md §21). Verification here is intentionally thin — real
/// confirmation that the expected page loaded needs the browser extension (§23, §36), which
/// doesn't exist yet. For now this only verifies that the URL was well-formed and handed to the
/// OS; it does not confirm the page actually loaded, and it shouldn't be read as if it does.
struct OpenURLTool {
    enum ToolError: Error, LocalizedError {
        case invalidURL(String)
        case calendarFeedURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let raw):
                "\"\(raw)\" isn't a valid URL."
            case .calendarFeedURL(let url):
                // Phrased for the model, fed back as a tool result — live testing showed it
                // reaching for open_url specifically as a workaround once browser_navigate
                // rejected the same .ics link, every time trying to read the feed's content
                // (which this hands off to Calendar.app instead of showing), never a genuine
                // "subscribe to this feed" request.
                "\"\(url)\" is a calendar-feed/subscription link (.ics/webcal) — opening it hands off to Calendar.app rather than showing any readable content, so it can't be used to read event details. Use the page's own on-page navigation instead (browser_click a next/previous-month control, or browser_navigate a different URL for the same calendar view)."
            }
        }
    }

    private static func isCalendarFeedURL(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        return lowercased.hasSuffix(".ics") || lowercased.hasPrefix("webcal:") || lowercased.contains("/feeds/calendar")
    }

    /// `newWindow` is for an explicit "open a new window" request — `NSWorkspace.shared.open`
    /// alone can't do this, it just hands the URL to the default browser, which normally reuses
    /// its existing window (a new tab, or — via OverlayViewModel's own bridge-based tab reuse —
    /// the current tab). Forcing an actual new window needs shelling out to `open -n` against the
    /// resolved default browser app itself, with `--new-window` passed through to it; that flag is
    /// a Chromium convention (Chrome, Edge, Brave, Arc all honor it), not a universal one, so this
    /// is best-effort for non-Chromium default browsers rather than a guarantee.
    @discardableResult
    func execute(urlString: String, newWindow: Bool = false) throws -> URL {
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw ToolError.invalidURL(urlString)
        }
        guard !Self.isCalendarFeedURL(urlString) else {
            throw ToolError.calendarFeedURL(urlString)
        }
        guard newWindow, let browserAppURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSWorkspace.shared.open(url)
            return url
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", browserAppURL.path, "--args", "--new-window", urlString]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(url) // couldn't spawn `open` — still satisfy the request, just not in a new window
        }
        return url
    }
}
