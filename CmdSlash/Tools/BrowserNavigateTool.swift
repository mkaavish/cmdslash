import Foundation

/// The `browser_navigate` tool (Docs/PLANNING.md §21, §23). Structured browser control via the
/// extension's DOM/tab access, not screenshot-and-click — navigates the active tab and reports
/// back the URL it actually landed on (which may differ from the requested one after a redirect),
/// which doubles as the verification (§36) that navigation actually happened.
struct BrowserNavigateTool {
    struct Result {
        let finalURL: String
    }

    func execute(urlString: String) async throws -> Result {
        let response = try await BrowserBridgeServer.shared.sendCommand(action: "navigate", params: ["url": urlString])
        guard let finalURL = response["data"] as? String else {
            throw BrowserBridgeServer.BridgeError(message: "Extension didn't report the resulting URL.")
        }
        return Result(finalURL: finalURL)
    }
}
