import Foundation

/// The `browser_click` tool (Docs/PLANNING.md §21, §23) — clicks the first visible button, link,
/// or other clickable element whose text matches, via the extension's content script. Matches by
/// visible text rather than a CSS selector: that's what the model actually has to work with —
/// browser_get_page_text already surfaces link text, and asking the model to construct a correct
/// CSS selector blind is far less reliable than matching text it's already seen.
struct BrowserClickTool {
    struct Result {
        let matchedText: String
    }

    func execute(text: String) async throws -> Result {
        let response = try await BrowserBridgeServer.shared.sendCommand(action: "click", params: ["text": text])
        guard let data = response["data"] as? [String: Any], let matchedText = data["matchedText"] as? String else {
            throw BrowserBridgeServer.BridgeError(message: "Extension didn't confirm what was clicked.")
        }
        return Result(matchedText: matchedText)
    }
}
