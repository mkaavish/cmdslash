import Foundation

/// The `browser_navigate` tool (Docs/PLANNING.md §21, §23). Structured browser control via the
/// extension's DOM/tab access, not screenshot-and-click — navigates the active tab and reports
/// back the URL it actually landed on (which may differ from the requested one after a redirect),
/// which doubles as the verification (§36) that navigation actually happened.
struct BrowserNavigateTool {
    struct Result {
        let finalURL: String
    }

    enum ToolError: Error, LocalizedError {
        case calendarFeedURL(String)

        var errorDescription: String? {
            switch self {
            case .calendarFeedURL(let url):
                // Phrased for the model to read and act on (fed back as a tool result), not just
                // the user — structural, not just a prompt instruction, because live testing
                // showed the model reverting to this exact dead end anyway once an on-page
                // navigation attempt (e.g. a constructed month-view URL) didn't pan out.
                "\"\(url)\" is a calendar-feed/subscription link (.ics/webcal), not a renderable webpage — it can't be loaded this way, and opening it would just hand off to another app (e.g. Calendar) instead of showing anything readable. Use the page's own on-page navigation instead: try browser_click on a visible next/previous-month control, or a different URL pattern for the same calendar view."
            }
        }
    }

    func execute(urlString: String, timeout: TimeInterval = 15) async throws -> Result {
        guard !Self.isCalendarFeedURL(urlString) else {
            throw ToolError.calendarFeedURL(urlString)
        }
        let response = try await BrowserBridgeServer.shared.sendCommand(action: "navigate", params: ["url": urlString], timeout: timeout)
        guard let finalURL = response["data"] as? String else {
            throw BrowserBridgeServer.BridgeError(message: "Extension didn't report the resulting URL.")
        }
        return Result(finalURL: finalURL)
    }

    private static func isCalendarFeedURL(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        return lowercased.hasSuffix(".ics") || lowercased.hasPrefix("webcal:") || lowercased.contains("/feeds/calendar")
    }
}
