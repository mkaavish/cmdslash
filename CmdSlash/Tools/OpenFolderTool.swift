import AppKit

/// The `open_folder` tool (Docs/PLANNING.md §21). Added after "open Downloads folder" turned out
/// to have no real tool behind it — the model was improvising through `open_application("Finder")`
/// (which doesn't navigate anywhere) or a `file://` URL via `open_url` (works, but that tool's
/// description says "web browser", so relying on it is an accident, not a contract).
struct OpenFolderTool {
    enum ToolError: Error, LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                "Couldn't find a folder named \"\(name)\"."
            }
        }
    }

    private static let wellKnown: [String: FileManager.SearchPathDirectory] = [
        "downloads": .downloadsDirectory,
        "desktop": .desktopDirectory,
        "documents": .documentDirectory,
        "movies": .moviesDirectory,
        "music": .musicDirectory,
        "pictures": .picturesDirectory,
        "applications": .applicationDirectory
    ]

    @discardableResult
    func execute(name: String) throws -> URL {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL

        if key == "home" {
            url = FileManager.default.homeDirectoryForCurrentUser
        } else if let searchDirectory = Self.wellKnown[key] {
            guard let resolved = FileManager.default.urls(for: searchDirectory, in: .userDomainMask).first else {
                throw ToolError.notFound(name)
            }
            url = resolved
        } else {
            // Not a well-known folder — try it as a direct child of the home directory.
            let candidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw ToolError.notFound(name)
            }
            url = candidate
        }

        NSWorkspace.shared.open(url)
        return url
    }
}
