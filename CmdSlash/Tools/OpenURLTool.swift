import AppKit

/// The `open_url` tool (Docs/PLANNING.md §21). Verification here is intentionally thin — real
/// confirmation that the expected page loaded needs the browser extension (§23, §36), which
/// doesn't exist yet. For now this only verifies that the URL was well-formed and handed to the
/// OS; it does not confirm the page actually loaded, and it shouldn't be read as if it does.
struct OpenURLTool {
    enum ToolError: Error, LocalizedError {
        case invalidURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let raw):
                "\"\(raw)\" isn't a valid URL."
            }
        }
    }

    @discardableResult
    func execute(urlString: String) throws -> URL {
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw ToolError.invalidURL(urlString)
        }
        NSWorkspace.shared.open(url)
        return url
    }
}
