import Foundation

/// The `browser_get_page_text` tool (Docs/PLANNING.md §21, §23). Reads the active tab's visible
/// text via the extension's content script — structured DOM access rather than screenshotting the
/// page and asking a vision model to read it, per the computer-control priority order (§22).
struct BrowserGetPageTextTool {
    struct Link {
        let text: String
        let href: String
    }

    struct Result {
        let url: String
        let title: String
        let text: String
        let truncated: Bool
        /// Real navigable URLs, not just visible text — without this, the model can see the word
        /// "Pricing" on a page but has nothing to actually call browser_navigate with if what it
        /// needs is on a different page of the same site.
        let links: [Link]
    }

    private static let maxCharacters = 6000

    func execute() async throws -> Result {
        let response = try await BrowserBridgeServer.shared.sendCommand(action: "get_page_text", params: [:])
        guard let data = response["data"] as? [String: Any], let fullText = data["text"] as? String else {
            throw BrowserBridgeServer.BridgeError(message: "Extension didn't return page text.")
        }
        let url = (data["url"] as? String) ?? "unknown"
        let title = (data["title"] as? String) ?? ""
        let truncated = fullText.count > Self.maxCharacters
        let text = truncated ? String(fullText.prefix(Self.maxCharacters)) : fullText
        let links = ((data["links"] as? [[String: Any]]) ?? []).compactMap { entry -> Link? in
            guard let text = entry["text"] as? String, let href = entry["href"] as? String else { return nil }
            return Link(text: text, href: href)
        }
        return Result(url: url, title: title, text: text, truncated: truncated, links: links)
    }
}
